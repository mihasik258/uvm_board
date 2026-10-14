// tb_top.sv - mac16 testbench top: clock, reset, the pins (mac16_if), the DUT, run_test.
module tb_top;
    import uvm_pkg::*;
    import mac16_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    mac16_if vif (clk);
    assign vif.m_ready = 1'b1;               // the testbench always takes results

    mac16 dut (
        .clk       (clk),
        .rst_n     (vif.rst_n),
        .s_valid   (vif.s_valid),
        .s_ready   (vif.s_ready),
        .s_a       (vif.s_a),
        .s_b       (vif.s_b),
        .s_clr     (vif.s_clr),
        .m_valid   (vif.m_valid),
        .m_ready   (vif.m_ready),
        .m_acc     (vif.m_acc),
        .m_ts      (vif.m_ts),
        .dbg_valid (vif.dbg_valid),
        .dbg_prod  (vif.dbg_prod)
    );

    initial begin
        vif.rst_n = 1'b0;
        repeat (10) @(posedge clk);
        vif.rst_n <= 1'b1;
    end

    initial begin
        uvm_config_db #(virtual mac16_if)::set(null, "*", "vif", vif);
        run_test("rand_test");
    end
endmodule
