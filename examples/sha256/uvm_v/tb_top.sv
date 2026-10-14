// tb_top.sv - SHA-256 testbench top: clock, reset, the pins (sha_if), the core, run_test.
module tb_top;
    import uvm_pkg::*;
    import sha_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    sha_if vif (clk);

    sha256 dut (
        .clk        (clk),
        .rst_n      (vif.rst_n),
        .in_valid   (vif.in_valid),
        .in_ready   (vif.in_ready),
        .in_block   (vif.in_block),
        .in_init    (vif.in_init),
        .out_valid  (vif.out_valid),
        .out_digest (vif.out_digest)
    );

    initial begin
        vif.rst_n = 1'b0;
        repeat (10) @(posedge clk);
        vif.rst_n <= 1'b1;
    end

    initial begin
        uvm_config_db #(virtual sha_if)::set(null, "*", "vif", vif);
        run_test("sha_test");
    end
endmodule
