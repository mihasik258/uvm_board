# =============================================================================
# build.tcl - Vivado batch build of one OCV environment on the VD100 platform.
# Called by platforms/vd100/build.sh, which passes everything through the environment:
#   OCV_OUT        build directory (project, reports, PDI)
#   OCV_ENV        generated wrapper module (<name>_ocv)
#   OCV_AW         its AXI4-Lite address width
#   OCV_DMA_DW     data width of its AXI4 master for the DMA rings (0: none)
#   OCV_CLK_MHZ    PL clock
#   OCV_RTL_F      file with the RTL sources, one per line (OCV core, DUT, generated wrapper)
#   OCV_DEFINES    Verilog defines, space separated (NAME or NAME=VALUE)
#   OCV_INCDIRS    include directories, space separated
#   OCV_STOP       bd | synth | impl (default impl: PDI + reports)
#   OCV_JOBS       parallel jobs (default 8)
#   OCV_DEBUG      1 = debug build: ILA on the hub's AXI4-Lite bus, probes file ocv_vd100.ltx
# =============================================================================
set here [file dirname [file normalize [info script]]]
set plat [file dirname $here]
proc env_or {name dflt} { expr {[info exists ::env($name)] ? $::env($name) : $dflt} }

set out      [file normalize $::env(OCV_OUT)]
set top_env  $::env(OCV_ENV)
set aw       $::env(OCV_AW)
set OCV_CLK_MHZ [env_or OCV_CLK_MHZ 100]
set stop     [env_or OCV_STOP impl]
set jobs     [env_or OCV_JOBS 8]
set debug    [env_or OCV_DEBUG 0]
set OCV_WINDOW [format 0x%X [expr {1 << ($aw < 12 ? 12 : $aw)}]]
set OCV_DMA_DW [env_or OCV_DMA_DW 0]

create_project -force ocv_vd100 $out/vivado -part xcve2302-sfva784-1LP-e-s

# --- 1) board block design ----------------------------------------------------------
source $here/create_bd.tcl
set bdf [get_files ocv_vd100_bd.bd]
if {$stop eq "bd"} { puts "OCV_BUILD: BD_OK"; return }
generate_target all $bdf
make_wrapper -files $bdf -top
add_files -norecurse $out/vivado/ocv_vd100.gen/sources_1/bd/ocv_vd100_bd/hdl/ocv_vd100_bd_wrapper.v

# --- 2) platform top + environment (OCV core, DUT, generated wrapper) ---------------
set files [list $plat/rtl/ocv_vd100_top.sv]
foreach f [split [string trim [read [open $::env(OCV_RTL_F)]]] "\n"] {
    if {[string trim $f] ne ""} { lappend files [string trim $f] }
}
add_files -norecurse $files
foreach f $files { if {[string match *.sv $f]} { set_property file_type SystemVerilog [get_files $f] } }
add_files -fileset constrs_1 -norecurse $plat/constrs/vd100.xdc

set defs [list OCV_ENV=$top_env OCV_AW=$aw OCV_USE_BUFGCE OCV_BUFGCE_SIM_DEVICE=VERSAL_AI_EDGE]
foreach d [env_or OCV_DEFINES ""] { lappend defs $d }
if {$debug} { lappend defs OCV_DEBUG }
set fs [get_filesets sources_1]
set_property verilog_define $defs $fs
set_property include_dirs [env_or OCV_INCDIRS ""] $fs
set_property top ocv_vd100_top $fs
update_compile_order -fileset sources_1

# --- 3) synthesis ---------------------------------------------------------------------
file mkdir $out/reports
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    puts "OCV_BUILD: SYNTH_FAILED ([get_property STATUS [get_runs synth_1]])"; exit 1
}
if {$stop eq "synth"} {
    open_run synth_1
    report_utilization -hierarchical -hierarchical_depth 3 -file $out/reports/util_synth.rpt
    puts "OCV_BUILD: SYNTH_OK"; return
}

# --- 3b) debug build: ILA on the nets marked in rtl/ocv_vd100_top.sv -----------------------
# Versal has no ILA as a BD cell: the core is added to the synthesized netlist and Vivado inserts
# the debug hub (reached over the board JTAG) itself. The debug constraints go to their own file,
# never into the board XDC.
if {$debug} {
    open_run synth_1 -name synth_1
    set ila [create_debug_core u_ila_0 ila]
    set_property C_DATA_DEPTH 4096 $ila
    set_property C_ADV_TRIGGER false $ila
    set_property C_INPUT_PIPE_STAGES 0 $ila
    set_property ALL_PROBE_SAME_MU true $ila
    set_property ALL_PROBE_SAME_MU_CNT 2 $ila
    connect_debug_port u_ila_0/clk [get_nets clk]
    set groups [dict create]
    foreach n [get_nets -hierarchical -filter {MARK_DEBUG == 1}] {
        dict lappend groups [regsub {\[[0-9]+\]$} $n ""] $n
    }
    set k 0
    foreach base [lsort [dict keys $groups]] {
        if {$k > 0} { create_debug_port u_ila_0 probe }
        set nets [lsort -dictionary [dict get $groups $base]]
        set_property port_width [llength $nets] [get_debug_ports u_ila_0/probe$k]
        set_property PROBE_TYPE DATA_AND_TRIGGER [get_debug_ports u_ila_0/probe$k]
        connect_debug_port u_ila_0/probe$k $nets
        incr k
    }
    set dxdc $out/debug.xdc
    close [open $dxdc w]
    add_files -fileset constrs_1 -norecurse $dxdc
    set_property target_constrs_file $dxdc [get_filesets constrs_1]
    set_property USED_IN_SYNTHESIS false [get_files $dxdc]
    save_constraints -force
    close_design
    puts "OCV_BUILD: ILA with $k probes"
}

# --- 4) implementation -> PDI -----------------------------------------------------------
launch_runs impl_1 -to_step write_device_image -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    puts "OCV_BUILD: IMPL_FAILED ([get_property STATUS [get_runs impl_1]])"; exit 1
}
open_run impl_1
report_utilization -hierarchical -hierarchical_depth 4 -file $out/reports/util.rpt
report_timing_summary -max_paths 20 -file $out/reports/timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set pdi [lindex [glob -nocomplain $out/vivado/ocv_vd100.runs/impl_1/*.pdi] 0]
file copy -force $pdi $out/ocv_vd100.pdi
if {$debug} { write_debug_probes -force $out/ocv_vd100.ltx }

# one-line summary for scripts: timing, environment (hub + endpoints + DUT) and DUT alone
source $plat/../../hw/scripts/ocv_util.tcl
set h [report_utilization -hierarchical -return_string]
lassign [hier_row $h i_env] elut eff ebram edsp
lassign [hier_row $h i_dut] dlut dff dbram ddsp
set line "clk_mhz=$OCV_CLK_MHZ wns=$wns whs=$whs env_lut=$elut env_ff=$eff env_bram=$ebram env_dsp=$edsp dut_lut=$dlut dut_ff=$dff dut_bram=$dbram dut_dsp=$ddsp"
set fh [open $out/reports/summary.txt w]; puts $fh $line; close $fh
puts "OCV_BUILD: IMPL_OK $line"
