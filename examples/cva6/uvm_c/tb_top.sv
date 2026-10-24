// tb_top.sv - CVA6 testbench top: clock, reset, the pins (cva6_if), the core under OCV's wrapper, run_test.
module tb_top;
    import uvm_pkg::*;
    import cva6_c_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    cva6_if vif (clk);

    cva6_dut dut (
        .clk           (clk),
        .rst_n         (vif.rst_n),
        .prog_valid    (vif.prog_valid),
        .prog_ready    (vif.prog_ready),
        .prog_addr     (vif.prog_addr),
        .prog_data     (vif.prog_data),
        .prog_last     (vif.prog_last),
        .issue_valid   (vif.issue_valid),
        .issue_pc      (vif.issue_pc),
        .issue_insn    (vif.issue_insn),
        .issue_c       (vif.issue_c),
        .regw_valid    (vif.regw_valid),
        .regw_rd       (vif.regw_rd),
        .regw_data     (vif.regw_data),
        .store_valid   (vif.store_valid),
        .store_addr    (vif.store_addr),
        .store_be      (vif.store_be),
        .store_data    (vif.store_data),
        .irq_valid     (vif.irq_valid),
        .irq_cause     (vif.irq_cause),
        .irq_seq       (vif.irq_seq),
        .irq_cycle     (vif.irq_cycle),
        .csrr_valid    (vif.csrr_valid),
        .csrr_data     (vif.csrr_data),
        .proto_valid   (vif.proto_valid),
        .proto_value   (vif.proto_value),
        .proto_cycle   (vif.proto_cycle),
        .dev_req_valid (vif.dev_req_valid),
        .dev_req_dev   (vif.dev_req_dev),
        .dev_req_addr  (vif.dev_req_addr),
        .dev_req_we    (vif.dev_req_we),
        .dev_req_be    (vif.dev_req_be),
        .dev_req_wdata (vif.dev_req_wdata),
        .dev_req_cycle (vif.dev_req_cycle),
        .dev_resp_valid(vif.dev_resp_valid),
        .dev_resp_ready(vif.dev_resp_ready),
        .dev_resp_rdata(vif.dev_resp_rdata),
        .in_irq_i_valid(vif.in_irq_i_valid),
        .in_irq_i_ready(vif.in_irq_i_ready),
        .in_irq_i_until(vif.in_irq_i_until),
        .in_irq_i_value(vif.in_irq_i_value),
        .cfg_lat_valid (vif.cfg_lat_valid),
        .cfg_lat_ready (vif.cfg_lat_ready),
        .cfg_lat_seed  (vif.cfg_lat_seed),
        .cfg_lat_gnt   (vif.cfg_lat_gnt),
        .cfg_lat_rsp   (vif.cfg_lat_rsp)
    );

    initial begin
        vif.rst_n = 1'b0;
        vif.prog_valid = 1'b0;
        vif.dev_resp_valid = 1'b0;
        vif.in_irq_i_valid = 1'b0;
        vif.cfg_lat_valid = 1'b0;
        repeat (10) @(posedge clk);
        vif.rst_n <= 1'b1;
    end

    initial begin
        uvm_config_db #(virtual cva6_if)::set(null, "*", "vif", vif);
        run_test("cva6_prog_test");
    end
endmodule
