// tb_top.sv - SCR1 testbench top: clock, reset, the pins (scr1_if), the core, run_test.
module tb_top;
    import uvm_pkg::*;
    import scr1_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    scr1_if vif (clk);

    scr1_ocv_dut dut (
        .clk           (clk),
        .rst_n         (vif.rst_n),
        .prog_valid    (vif.prog_valid),
        .prog_ready    (vif.prog_ready),
        .prog_addr     (vif.prog_addr),
        .prog_data     (vif.prog_data),
        .prog_last     (vif.prog_last),
        .rvfi_valid    (vif.rvfi_valid),
        .rvfi_pc       (vif.rvfi_pc),
        .rvfi_pc_next  (vif.rvfi_pc_next),
        .rvfi_rd_addr  (vif.rvfi_rd_addr),
        .rvfi_rd_wdata (vif.rvfi_rd_wdata),
        .rvfi_trap     (vif.rvfi_trap),
        .rvfi_csr_rd   (vif.rvfi_csr_rd),
        .rvfi_csr_addr (vif.rvfi_csr_addr),
        .rvfi_mem_we   (vif.rvfi_mem_we),
        .rvfi_mem_wmask(vif.rvfi_mem_wmask),
        .rvfi_mem_addr (vif.rvfi_mem_addr),
        .rvfi_mem_wdata(vif.rvfi_mem_wdata),
        .rvfi_csrw_we  (vif.rvfi_csrw_we),
        .rvfi_csrw_cmd (vif.rvfi_csrw_cmd),
        .rvfi_csrw_addr(vif.rvfi_csrw_addr),
        .rvfi_csrw_data(vif.rvfi_csrw_data)
    );

    initial begin
        vif.rst_n = 1'b0;
        repeat (10) @(posedge clk);
        vif.rst_n <= 1'b1;
    end

    initial begin
        uvm_config_db #(virtual scr1_if)::set(null, "*", "vif", vif);
        run_test("prog_test");
    end
endmodule
