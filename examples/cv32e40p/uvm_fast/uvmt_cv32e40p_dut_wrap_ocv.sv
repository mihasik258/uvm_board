// uvmt_cv32e40p_dut_wrap_ocv.sv - the stand-in for core-v-verif's uvmt_cv32e40p_dut_wrap (same name, same
// parameters and ports) when the core runs in the FPGA (hw/cpu, examples/cv32e40p/cv32e40p.bind) and the
// testbench, as it is, on the processor - put in its place by uvm_fast/run.sh, the testbench's files are not
// changed.
//
// Once the test lets the core fetch (core_cntrl_if.fetch_en), the core runs the test's program (+firmware) in
// the FPGA, every instruction checked against the reference model (OCV runner, uvm/cpu/ocv_uvm_cpu.c). The
// testbench's clock stands still meanwhile (uvma_clknrst_if: ocv_hold, set by uvm_fast/run.sh's copy of it):
// only the core's accesses to the virtual peripherals reach the testbench - for each, its time goes on to the
// core's clock count, the clock runs, and the access is made on the data OBI interface as the core would make
// it: the testbench's own OBI agent and its virtual peripheral sequences (printer, status, ...) answer, and a
// read's data goes back to the core. When the program has ended the clock runs on as usual; a mismatch
// between the core and the model is a UVM error.
module uvmt_cv32e40p_dut_wrap #(
    parameter PULP_XPULP        = 0,
              PULP_CLUSTER      = 0,
              FPU               = 0,
              PULP_ZFINX        = 0,
              NUM_MHPMCOUNTERS  = 1,
              INSTR_ADDR_WIDTH  = 32,
              INSTR_RDATA_WIDTH = 32,
              RAM_ADDR_WIDTH    = 22
) (
    uvma_clknrst_if              clknrst_if,
    uvma_interrupt_if            interrupt_if,
    uvma_interrupt_if            vp_interrupt_if,
    uvmt_cv32e40p_core_cntrl_if  core_cntrl_if,
    uvmt_cv32e40p_core_status_if core_status_if,
    uvma_obi_memory_if           obi_memory_instr_if,
    uvma_obi_memory_if           obi_memory_data_if
);
    import uvm_pkg::*;
    `include "uvm_macros.svh"

    import "DPI-C" context function int  ocv_uvm_cpu_start(input string args);
    import "DPI-C" context function int  ocv_uvm_cpu_next(output int dev, output int addr, output int we, output int be,
                                                          output int wdata, output longint cycle);
    import "DPI-C" context function void ocv_uvm_cpu_answer(input int rdata);
    import "DPI-C" context function int  ocv_uvm_cpu_result();

    // what the original wrapper connects besides the core
    assign debug_if.clk            = clknrst_if.clk;
    assign debug_if.reset_n        = clknrst_if.reset_n;
    assign interrupt_if.clk        = clknrst_if.clk;
    assign interrupt_if.reset_n    = clknrst_if.reset_n;
    assign vp_interrupt_if.clk     = clknrst_if.clk;
    assign vp_interrupt_if.reset_n = clknrst_if.reset_n;
    assign interrupt_if.irq_id     = '0;
    assign interrupt_if.irq_ack    = 1'b0;
    assign core_status_if.core_busy = 1'b0;

    // the instruction port: the FPGA's memory serves it - nothing on this interface
    assign obi_memory_instr_if.req   = 1'b0;
    assign obi_memory_instr_if.addr  = '0;
    assign obi_memory_instr_if.we    = 1'b0;
    assign obi_memory_instr_if.be    = '1;
    assign obi_memory_instr_if.wdata = '0;

    // the data port: the core's device accesses, made here one by one
    logic        d_req, d_we;
    logic [31:0] d_addr, d_wdata;
    logic [3:0]  d_be;
    assign obi_memory_data_if.req   = d_req;
    assign obi_memory_data_if.addr  = d_addr;
    assign obi_memory_data_if.we    = d_we;
    assign obi_memory_data_if.be    = d_be;
    assign obi_memory_data_if.wdata = d_wdata;
    initial begin d_req = 1'b0; d_we = 1'b0; d_addr = '0; d_be = '0; d_wdata = '0; end

    initial begin : run
        string fw, opts, extra;
        int dev, addr, we, be, wdata, rdata;
        longint cycle, last;
        if (!$value$plusargs("firmware=%s", fw)) begin
            `uvm_info("OCV", "no +firmware: the core does not run", UVM_NONE)
            disable run;
        end
        if (!$value$plusargs("ocv=%s", extra)) extra = "";
        opts = $sformatf("--batch 1048576 --squash 4096 --model-opt program=%s %s", fw, extra);
        wait (core_cntrl_if.fetch_en === 1'b1);              // the test lets the core go
        @(posedge clknrst_if.clk);
        if (!ocv_uvm_cpu_start(opts)) `uvm_fatal("OCV", "cannot start the core in the FPGA")
        `uvm_info("OCV", $sformatf("the core runs in the FPGA: %s", opts), UVM_NONE)
        last = 0;
        clknrst_if.ocv_hold = 1'b1;                          // the testbench's clock stands still
        while (ocv_uvm_cpu_next(dev, addr, we, be, wdata, cycle)) begin
            if (cycle > last) #((cycle - last) * clknrst_if.clk_period * 2);   // its time follows the core's
            last = cycle;
            clknrst_if.ocv_hold = 1'b0;
            // the access as the core makes it: request until granted, then the response
            @(posedge clknrst_if.clk);
            d_req <= 1'b1; d_addr <= addr; d_we <= we[0]; d_be <= be[3:0]; d_wdata <= wdata;
            do @(posedge clknrst_if.clk); while (obi_memory_data_if.gnt !== 1'b1);
            d_req <= 1'b0;
            while (obi_memory_data_if.rvalid !== 1'b1) @(posedge clknrst_if.clk);
            rdata = obi_memory_data_if.rdata;
            if (!we[0]) ocv_uvm_cpu_answer(rdata);
            clknrst_if.ocv_hold = 1'b1;
        end
        clknrst_if.ocv_hold = 1'b0;                          // the program has ended: the clock runs on
        if (ocv_uvm_cpu_result() != 0)
            `uvm_error("OCV", $sformatf("the core and the reference model differ (runner status %0d)", ocv_uvm_cpu_result()))
        else
            `uvm_info("OCV", "every instruction of the core matched the reference model", UVM_NONE)
    end
endmodule : uvmt_cv32e40p_dut_wrap
