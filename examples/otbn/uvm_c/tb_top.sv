// tb_top.sv - OTBN+KMAC testbench top: clock, reset, the pins (otbn_if), the DUT, run_test.
module tb_top;
    import uvm_pkg::*;
    import otbn_c_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    otbn_if vif (clk);

    otbn_kmac_ocv dut (
        .clk_i            (clk),
        .rst_ni           (vif.rst_n),
        .req_valid_i      (vif.req_valid),
        .req_ready_o      (vif.req_ready),
        .req_we_i         (vif.req_we),
        .req_wait_i       (vif.req_wait),
        .req_addr_i       (vif.req_addr),
        .req_wdata_i      (vif.req_wdata),
        .req_be_i         (vif.req_be),
        .rsp_valid_o      (vif.rsp_valid),
        .rsp_rdata_o      (vif.rsp_rdata),
        .rsp_err_o        (vif.rsp_err),
        .intr_otbn_done_o (),
        .intr_kmac_err_o  (),
        .alert_o          ()
    );

    initial begin
        vif.rst_n = 1'b0;
        vif.req_valid = 1'b0;
        repeat (10) @(posedge clk);
        vif.rst_n <= 1'b1;
    end

`ifndef OCV_BOARD
    // +DEBUG: OTBN's and KMAC's states every 100 us (simulation only: the DUT's insides)
    initial if ($test$plusargs("DEBUG"))
        forever begin
            #100us;
            $display("%t DEBUG otbn status=%0h err_bits=%0h insn_cnt=%0d | kmac app st=%0h sha3 st=%0h", $time,
                     dut.u_otbn.status_q, dut.u_otbn.err_bits_q, dut.u_otbn.insn_cnt,
                     dut.u_kmac.u_app_intf.st, dut.u_kmac.u_sha3.st);
            $fflush();
        end
`endif

    initial begin
        uvm_config_db #(virtual otbn_if)::set(null, "*", "vif", vif);
        run_test("otbn_mldsa_test");
    end
endmodule
