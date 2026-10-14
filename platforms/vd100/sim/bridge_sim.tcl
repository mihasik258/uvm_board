# bridge_sim.tcl - build and run the bridge simulation (see bridge_tb.sv). Called by run_bridge_sim.sh:
#   BR_OUT       work directory          BR_ENV / BR_AW  environment module and address width
#   BR_RTL_F     RTL sources (OCV core, DUT, generated wrapper), one per line
#   BR_DPI       DPI library (runner, library, model, bridge_dpi.c), built by run_bridge_sim.sh
#   BR_DEFINES   Verilog defines of the DUT, BR_INCDIRS their include directories
#   BR_ARGS      runner options,  BR_JITTER  master stall probability in %
set sim  [file dirname [file normalize [info script]]]
set plat [file dirname $sim]
set out  $::env(BR_OUT)
create_project -force bridge $out/vivado -part xcve2302-sfva784-1LP-e-s

# the platform's bridge, alone: AXI4 slave shaped like M_AXI_LPD -> SmartConnect -> AXI4-Lite master
create_bd_design bridge_bd
source $plat/tcl/bridge.tcl
ocv_bridge_cell axi_smc
set s [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 S_AXI]
set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.DATA_WIDTH {128} CONFIG.ADDR_WIDTH {44} \
    CONFIG.ID_WIDTH {16} CONFIG.ARUSER_WIDTH {16} CONFIG.AWUSER_WIDTH {16} CONFIG.HAS_BURST {1} \
    CONFIG.HAS_LOCK {1} CONFIG.HAS_CACHE {1} CONFIG.HAS_PROT {1} CONFIG.HAS_QOS {1} \
    CONFIG.HAS_REGION {0} CONFIG.MAX_BURST_LENGTH {256} CONFIG.NUM_READ_OUTSTANDING {2} \
    CONFIG.NUM_WRITE_OUTSTANDING {2} CONFIG.FREQ_HZ {100000000}] $s
set m [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI]
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} \
    CONFIG.HAS_PROT {1} CONFIG.FREQ_HZ {100000000}] $m
create_bd_port -dir I -type clk -freq_hz 100000000 clk
create_bd_port -dir I -type rst rst_n
set_property CONFIG.ASSOCIATED_BUSIF {S_AXI:M_AXI} [get_bd_ports clk]
connect_bd_intf_net $s [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] $m
connect_bd_net [get_bd_ports clk] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_ports rst_n] [get_bd_pins axi_smc/aresetn]
assign_bd_address -offset 0x80000000 -range [expr {1 << ($::env(BR_AW) < 12 ? 12 : $::env(BR_AW))}] \
    -target_address_space [get_bd_addr_spaces S_AXI] [get_bd_addr_segs M_AXI/Reg] -force
validate_bd_design
save_bd_design
set bdf [get_files bridge_bd.bd]
generate_target simulation $bdf
make_wrapper -files $bdf -top
add_files -norecurse $out/vivado/bridge.gen/sources_1/bd/bridge_bd/hdl/bridge_bd_wrapper.v

# environment, testbench, the PS program over DPI
set rtl {}
foreach f [split [string trim [read [open $::env(BR_RTL_F)]]] "\n"] { if {$f ne ""} { lappend rtl $f } }
add_files -norecurse $rtl
add_files -fileset sim_1 -norecurse $sim/bridge_tb.sv
foreach f [concat $rtl $sim/bridge_tb.sv] {
    if {[string match *.sv $f]} { set_property file_type SystemVerilog [get_files $f] }
}
set fs [get_filesets sim_1]
set defs [list OCV_ENV=$::env(BR_ENV) OCV_AW=$::env(BR_AW)]
foreach d $::env(BR_DEFINES) { lappend defs $d }
set_property verilog_define $defs $fs
set_property verilog_define $defs [get_filesets sources_1]
set_property include_dirs $::env(BR_INCDIRS) $fs
set_property include_dirs $::env(BR_INCDIRS) [get_filesets sources_1]
# The C side is a shared library built with the system compiler: Vivado's own xsc toolchain
# (binutils 2.37) cannot link against a current glibc. Values starting with '-' must go through
# -name/-value, or set_property takes them as its own options.
set dpi $::env(BR_DPI)
set_property -name XSIM.ELABORATE.XELAB.MORE_OPTIONS -objects $fs \
    -value "-sv_root [file dirname $dpi] -sv_lib [file rootname [file tail $dpi]]"
set_property top bridge_tb $fs
set_property top_lib xil_defaultlib $fs
set_property XSIM.SIMULATE.RUNTIME all $fs
set_property -name XSIM.SIMULATE.XSIM.MORE_OPTIONS -objects $fs \
    -value "-testplusarg ARGS=$::env(BR_ARGS) -testplusarg JITTER=$::env(BR_JITTER)"
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
puts "BRIDGE_SIM: done"
