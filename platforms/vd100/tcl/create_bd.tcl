# =============================================================================
# create_bd.tcl - OCV platform block design for the ALINX VD100 (Versal xcve2302).
#
# What the board gives an OCV environment, and nothing else:
#   - the PS (CIPS) with the ALINX configuration, so the stock SD-card PetaLinux boots;
#   - DDR4 for the PS through the NoC;
#   - one PL clock (clk_wizard from the 200 MHz board clock) and its synchronous reset;
#   - one AXI4-Lite master into the PL: M_AXI_LPD -> SmartConnect -> external port `ocv_axil`,
#     mapped at physical OCV_BASE with a window of OCV_WINDOW bytes. The hub of the generated
#     environment hangs on it (rtl/ocv_vd100_top.sv).
# The DUT is not in the BD: the BD does not change from one DUT to another except for the clock
# frequency and the window size.
#
# Inputs (Tcl variables, set before sourcing; defaults in brackets):
#   OCV_CLK_MHZ  [100]         PL clock of the environment (hub, endpoints, DUT)
#   OCV_WINDOW   [0x100000]    size of the hub window, power of two >= 4 KiB
#   OCV_DMA_DW   [0]           the environment's AXI4 master for the DMA rings (ocv_gen.py --dma): its
#                              data width; 0 = none. It enters the NoC as an extra slave port
#                              `ocv_dma` (64-bit address, ID 4 bits) and reaches the DDR - the PS
#                              memory, not coherent with the A72 caches (software invalidates).
# Fixed:
#   OCV_BASE     0x80000000    start of the M_AXI_LPD aperture
# Produces BD `ocv_vd100_bd`.
# =============================================================================

set here [file dirname [file normalize [info script]]]
if {![info exists OCV_CLK_MHZ]} { set OCV_CLK_MHZ 100 }
if {![info exists OCV_WINDOW]}  { set OCV_WINDOW 0x100000 }
if {![info exists OCV_DMA_DW]}  { set OCV_DMA_DW 0 }
set OCV_BASE 0x80000000

set bdname ocv_vd100_bd
create_bd_design $bdname
current_bd_design $bdname

# ---------------------------------------------------------------------------
# External ports.
# ---------------------------------------------------------------------------
set sys [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 sys]
set_property CONFIG.FREQ_HZ {200000000} $sys
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddr4_rtl:1.0 DDR4

set axil [create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 ocv_axil]
set_property -dict [list CONFIG.PROTOCOL {AXI4LITE} CONFIG.ADDR_WIDTH {32} CONFIG.DATA_WIDTH {32} \
                         CONFIG.HAS_PROT {1}] $axil
create_bd_port -dir O -type clk ocv_clk
create_bd_port -dir O -type rst ocv_rst_n
set busifs ocv_axil
if {$OCV_DMA_DW} {
  # the environment's DMA master (write only; the read channel is tied off in the wrapper)
  set dma [create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 ocv_dma]
  set_property -dict [list CONFIG.PROTOCOL {AXI4} CONFIG.ADDR_WIDTH {64} CONFIG.DATA_WIDTH $OCV_DMA_DW \
    CONFIG.ID_WIDTH {4} CONFIG.HAS_REGION {0} CONFIG.HAS_QOS {1} CONFIG.HAS_LOCK {1} CONFIG.HAS_CACHE {1} \
    CONFIG.HAS_PROT {1} CONFIG.HAS_BURST {1} CONFIG.HAS_WSTRB {1} CONFIG.HAS_BRESP {1} CONFIG.HAS_RRESP {1} \
    CONFIG.READ_WRITE_MODE {READ_WRITE} CONFIG.NUM_WRITE_OUTSTANDING {16} CONFIG.NUM_READ_OUTSTANDING {1} \
    CONFIG.MAX_BURST_LENGTH {256}] $dma
  set busifs "ocv_axil:ocv_dma"
}
set_property -dict [list CONFIG.ASSOCIATED_BUSIF $busifs CONFIG.ASSOCIATED_RESET {ocv_rst_n}] \
    [get_bd_ports ocv_clk]

# ---------------------------------------------------------------------------
# PS with the ALINX configuration (boots the SD-card PetaLinux).
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:versal_cips:3.4 versal_cips_0
source $here/ps_config.tcl
set_ps_config versal_cips_0

# ---------------------------------------------------------------------------
# NoC + DDR4 memory controller for the PS (ports and MC settings from the ALINX reference).
# ---------------------------------------------------------------------------
set noc [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_noc:1.0 axi_noc_0]
set_property -dict [list \
  CONFIG.CONTROLLERTYPE {DDR4_SDRAM} \
  CONFIG.MC_CASLATENCY {22} \
  CONFIG.MC_CHAN_REGION1 {NONE} \
  CONFIG.MC_COMPONENT_WIDTH {x16} \
  CONFIG.MC_INPUTCLK0_PERIOD {5000} \
  CONFIG.MC_MEMORY_SPEEDGRADE {DDR4-3200AA(22-22-22)} \
  CONFIG.MC_SYSTEM_CLOCK {No_Buffer} \
  CONFIG.MC_USER_DEFINED_ADDRESS_MAP {16RA-2BA-1BG-10CA} \
  CONFIG.NUM_CLKS [expr {$OCV_DMA_DW ? 7 : 6}] \
  CONFIG.NUM_MC {1} \
  CONFIG.NUM_MCP {4} \
  CONFIG.NUM_MI {0} \
  CONFIG.NUM_SI [expr {$OCV_DMA_DW ? 7 : 6}] \
] $noc
# Port -> memory-controller mapping and categories as in the reference. CONNECTIONS is parsed as
# text and every value must be braced ({4096}): with bare numbers the NoC silently creates no DDR
# address segments.
foreach {si mc bw cat} {S00_AXI MC_3 4096 ps_cci  S01_AXI MC_2 4096 ps_cci  S02_AXI MC_0 4096 ps_cci
                        S03_AXI MC_1 4096 ps_cci  S04_AXI MC_3 500  ps_rpu  S05_AXI MC_2 500  ps_pmc} {
  set_property -dict [list CONFIG.REGION {0} \
    CONFIG.CONNECTIONS "$mc {read_bw {$bw} write_bw {$bw} read_avg_burst {4} write_avg_burst {4}}" \
    CONFIG.NOC_PARAMS {} CONFIG.CATEGORY $cat] [get_bd_intf_pins axi_noc_0/$si]
}
foreach {i b} {0 S00_AXI 1 S01_AXI 2 S02_AXI 3 S03_AXI 4 S04_AXI 5 S05_AXI} {
  set_property CONFIG.ASSOCIATED_BUSIF $b [get_bd_pins axi_noc_0/aclk$i]
}
foreach {cips si} {FPD_CCI_NOC_0 S00_AXI FPD_CCI_NOC_1 S01_AXI FPD_CCI_NOC_2 S02_AXI
                   FPD_CCI_NOC_3 S03_AXI LPD_AXI_NOC_0 S04_AXI PMC_NOC_AXI_0 S05_AXI} {
  connect_bd_intf_net [get_bd_intf_pins versal_cips_0/$cips] [get_bd_intf_pins axi_noc_0/$si]
}
foreach {clk i} {fpd_cci_noc_axi0_clk 0 fpd_cci_noc_axi1_clk 1 fpd_cci_noc_axi2_clk 2
                 fpd_cci_noc_axi3_clk 3 lpd_axi_noc_clk 4 pmc_axi_noc_axi0_clk 5} {
  connect_bd_net [get_bd_pins versal_cips_0/$clk] [get_bd_pins axi_noc_0/aclk$i]
}
connect_bd_intf_net [get_bd_intf_ports DDR4] [get_bd_intf_pins axi_noc_0/CH0_DDR4_0]
if {$OCV_DMA_DW} {
  # PL DMA -> NoC -> DDR (memory-controller port 0, write mostly)
  set_property -dict [list CONFIG.REGION {0} \
    CONFIG.CONNECTIONS "MC_0 {read_bw {100} write_bw {3200} read_avg_burst {4} write_avg_burst {16}}" \
    CONFIG.NOC_PARAMS {} CONFIG.CATEGORY {pl}] [get_bd_intf_pins axi_noc_0/S06_AXI]
  set_property CONFIG.ASSOCIATED_BUSIF {S06_AXI} [get_bd_pins axi_noc_0/aclk6]
  connect_bd_intf_net [get_bd_intf_ports ocv_dma] [get_bd_intf_pins axi_noc_0/S06_AXI]
}

# ---------------------------------------------------------------------------
# PL clock and reset.
# ---------------------------------------------------------------------------
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_0
set clkw [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wizard:1.0 clk_wizard_0]
set_property -dict [list \
  CONFIG.CLKOUT_DRIVES {BUFG,BUFG,BUFG,BUFG,BUFG,BUFG,BUFG} \
  CONFIG.CLKOUT_USED {true,false,false,false,false,false,false} \
  CONFIG.CLKOUT_REQUESTED_OUT_FREQUENCY [format "%.3f,100.000,100.000,100.000,100.000,100.000,100.000" $OCV_CLK_MHZ] \
  CONFIG.USE_LOCKED {true} \
] $clkw
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

connect_bd_intf_net [get_bd_intf_ports sys] [get_bd_intf_pins util_ds_buf_0/CLK_IN_D]
connect_bd_net [get_bd_pins util_ds_buf_0/IBUF_OUT] [get_bd_pins clk_wizard_0/clk_in1] \
               [get_bd_pins axi_noc_0/sys_clk0]
set clk [get_bd_pins clk_wizard_0/clk_out1]
connect_bd_net [get_bd_pins versal_cips_0/pl0_resetn] [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins clk_wizard_0/locked]      [get_bd_pins proc_sys_reset_0/dcm_locked]

# ---------------------------------------------------------------------------
# PS -> hub: M_AXI_LPD (AXI4, 128 bit) -> SmartConnect (protocol + width conversion) -> ocv_axil.
# ---------------------------------------------------------------------------
source $here/bridge.tcl
ocv_bridge_cell axi_smc
connect_bd_intf_net [get_bd_intf_pins versal_cips_0/M_AXI_LPD] [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI] [get_bd_intf_ports ocv_axil]

connect_bd_net $clk [get_bd_pins proc_sys_reset_0/slowest_sync_clk] [get_bd_pins axi_smc/aclk] \
                    [get_bd_pins versal_cips_0/m_axi_lpd_aclk] [get_bd_ports ocv_clk]
if {$OCV_DMA_DW} { connect_bd_net $clk [get_bd_pins axi_noc_0/aclk6] }
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_smc/aresetn] \
               [get_bd_ports ocv_rst_n]

# ---------------------------------------------------------------------------
# Address map: PS DDR as in the ALINX reference; the hub window at OCV_BASE.
# ---------------------------------------------------------------------------
foreach {sp seg} {FPD_CCI_NOC_0 S00_AXI/C3_DDR_LOW0 FPD_CCI_NOC_1 S01_AXI/C2_DDR_LOW0 \
                  FPD_CCI_NOC_2 S02_AXI/C0_DDR_LOW0 FPD_CCI_NOC_3 S03_AXI/C1_DDR_LOW0 \
                  LPD_AXI_NOC_0 S04_AXI/C3_DDR_LOW0 PMC_NOC_AXI_0 S05_AXI/C2_DDR_LOW0} {
  assign_bd_address -offset 0x00000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces versal_cips_0/$sp] [get_bd_addr_segs axi_noc_0/$seg] -force
}
assign_bd_address -offset $OCV_BASE -range $OCV_WINDOW \
  -target_address_space [get_bd_addr_spaces versal_cips_0/M_AXI_LPD] [get_bd_addr_segs ocv_axil/Reg] -force
if {$OCV_DMA_DW} {
  # the DMA master sees the PS's DDR at the same addresses as the PS (physical = bus address)
  assign_bd_address -offset 0x00000000 -range 0x80000000 \
    -target_address_space [get_bd_addr_spaces ocv_dma] [get_bd_addr_segs axi_noc_0/S06_AXI/C0_DDR_LOW0] -force
}

regenerate_bd_layout
validate_bd_design
save_bd_design
puts "OCV_BD: ${OCV_CLK_MHZ} MHz, hub window [format 0x%X $OCV_BASE] + [format 0x%X $OCV_WINDOW], DMA ${OCV_DMA_DW} bit"
