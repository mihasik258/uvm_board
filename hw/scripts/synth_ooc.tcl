# synth_ooc.tcl - out-of-context synthesis of a generated OCV wrapper (DUT + hub + endpoints) on
# several device families: shows the platform RTL has no family dependency and splits the cost
# between the DUT and the verification environment.
#
#   vivado -mode batch -source synth_ooc.tcl -tclargs <out_dir> <top> <period_ns> <filelist> <part>...
#
# <filelist>: one SystemVerilog source per line (package first). Per part it writes
# <part>.util.rpt, <part>.hier.rpt, <part>.timing.rpt and appends to <out_dir>/summary.csv:
#   part,family,lut,ff,bram_tiles,dsp,dut_lut,dut_ff,dut_bram,dut_dsp,wns_ns

lassign $argv out top period filelist
set parts [lrange $argv 4 end]
file mkdir $out
set srcs [split [string trim [read [open $filelist]]] "\n"]

source [file join [file dirname [file normalize [info script]]] ocv_util.tcl]

set csv [open $out/summary.csv a]
foreach part $parts {
    read_verilog -sv $srcs
    synth_design -mode out_of_context -top $top -part $part
    create_clock -name clk -period $period [get_ports clk]
    set u [report_utilization -return_string]
    set h [report_utilization -hierarchical -return_string]
    report_utilization -file $out/$part.util.rpt
    report_utilization -hierarchical -file $out/$part.hier.rpt
    report_timing_summary -file $out/$part.timing.rpt
    set wns  [get_property SLACK [get_timing_paths -max_paths 1 -setup]]
    set lut  [util_of $u {(?:CLB|Slice) LUTs\*?}]
    set ff   [util_of $u {(?:(?:CLB|Slice) )?Registers}]
    set bram [util_of $u {Block RAM Tile}]
    lassign [hier_row $h i_dut] dlut dff dbram ddsp
    set dsp  [util_of $u {DSP(?:s| Slices)}]
    set fam  [get_property FAMILY [get_parts $part]]
    puts $csv "$part,$fam,$lut,$ff,$bram,$dsp,$dlut,$dff,$dbram,$ddsp,$wns"
    flush $csv
    puts "OCV_SYNTH $part family=$fam total LUT=$lut FF=$ff BRAM=$bram DSP=$dsp | DUT LUT=$dlut FF=$dff BRAM=$dbram DSP=$ddsp | WNS=$wns"
    close_design
}
close $csv
