// tb_top.sv - the testbench top: the generated harness (the DUT in simulation, nothing on the
// board) and run_test.
module tb_top;
    import uvm_pkg::*;
    import mac16_tb_pkg::*;
    mac16_ocv_uvm_harness harness ();
    initial run_test("mac16_rand_test");
endmodule
