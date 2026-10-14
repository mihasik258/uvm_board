# ila_capture.tcl - capture the hub's AXI4-Lite bus with the ILA of a debug build (OCV_DEBUG=1).
#
#   vivado -mode batch -source ila_capture.tcl -tclargs <ocv_vd100.ltx> <out.csv> [ar|aw|now] [timeout_s]
#
# The board runs the debug image from the SD card (nothing is programmed over JTAG); the JTAG
# cable of the board goes to this computer. Arm first, then start the PS program on the board
# (e.g. run.sh --info): trigger `ar` = first read of the hub (arvalid), `aw` = first write
# (awvalid), `now` = capture immediately (checks that the ILA itself streams).
# Writes <out.csv> (open in Vivado or any spreadsheet) and <out>.vcd.
lassign $argv ltx csv trig tmo
if {$trig eq ""} { set trig ar }
if {$tmo eq ""}  { set tmo 120 }

open_hw_manager
connect_hw_server -quiet
open_hw_target
set dev [lindex [get_hw_devices *xcve2302*] 0]
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
refresh_hw_device $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
if {$ila eq ""} { puts "ILA_CAPTURE: no ILA in the running image (is it the debug build?)"; exit 1 }

# Every probe to don't-care first: compare values stick across arms and are ANDed.
foreach p [get_hw_probes -of_objects $ila] {
    set w [get_property WIDTH $p]
    catch { set_property TRIGGER_COMPARE_VALUE eq${w}'h[string repeat X [expr {($w + 3) / 4}]] $p }
}
set_property CONTROL.DATA_DEPTH 4096 $ila
set_property CONTROL.TRIGGER_POSITION 64 $ila
set name [dict get {ar arvalid aw awvalid now {}} $trig]

if {$name eq ""} {
    run_hw_ila -trigger_now $ila
} else {
    set_property TRIGGER_COMPARE_VALUE eq1'b1 [get_hw_probes $name -of_objects $ila]
    run_hw_ila $ila
    puts "ILA_CAPTURE: armed on $name == 1, start the PS program now (timeout ${tmo}s)"
}
set t0 [clock seconds]
while {[get_property STATUS.CORE_STATUS $ila] ne "FULL"} {
    if {[clock seconds] - $t0 > $tmo} {
        puts "ILA_CAPTURE: no trigger in ${tmo}s (status [get_property STATUS.CORE_STATUS $ila])"
        exit 2
    }
    after 200
    refresh_hw_ila $ila
}
set data [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file -force $csv $data
write_hw_ila_data -vcd_file -force [file rootname $csv].vcd $data
puts "ILA_CAPTURE: [get_property DATA_DEPTH $data] samples -> $csv"
