# bridge.tcl - the PS -> hub bridge cell, shared by the board design (create_bd.tcl) and the bridge
# simulation (sim/bridge_sim.tcl), so the simulation exercises exactly what is on the board.
proc ocv_bridge_cell {name} {
    set smc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 $name]
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $smc
    return $smc
}
