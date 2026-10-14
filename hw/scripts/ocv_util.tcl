# ocv_util.tcl - report parsing shared by the synthesis scripts (hw/scripts/synth_ooc.tcl and the
# platform builds).

proc util_of {rpt pattern} {
    foreach line [split $rpt "\n"] {
        if {[regexp "^\\|\\s*${pattern}\\s*\\|\\s*(\\S+)\\s*\\|" $line -> used]} { return $used }
    }
    return 0
}

# Row of instance `inst` in report_utilization -hierarchical: returns {LUT FF BRAM DSP}.
# (Vivado ships Tcl 8.5: no lmap.)
proc hier_row {rpt inst} {
    set cols {}
    foreach line [split $rpt "\n"] {
        set f {}
        foreach c [split $line "|"] { lappend f [string trim $c] }
        if {[lsearch -exact $f "Total LUTs"] >= 0} { set cols $f; continue }
        if {[llength $cols] && [lindex $f 1] eq $inst} {
            set get {}
            foreach name {"Total LUTs" "FFs" "RAMB36" "RAMB18" "DSP Blocks"} {
                set i [lsearch -glob $cols "${name}*"]
                lappend get [expr {$i >= 0 ? [lindex $f $i] : 0}]
            }
            lassign $get lut ff b36 b18 dsp
            return [list $lut $ff [expr {$b36 + $b18 / 2.0}] $dsp]
        }
    }
    return {0 0 0 0}
}
