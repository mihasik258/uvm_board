// tb_top.sv - SCR1 UVM testbench top: the generated harness (the DUT in simulation, nothing on
// the board) and run_test.
module tb_top;
    import uvm_pkg::*;
    import scr1_tb_pkg::*;
    scr1_ocv_uvm_harness harness ();
    initial run_test("scr1_prog_test");
endmodule
