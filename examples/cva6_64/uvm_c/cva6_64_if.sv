// cva6_64_if.sv - the pins of the 64-bit CVA6 under OCV's core wrapper (gen/cpu_wrap.py, examples/cva6_64/cva6_64.bind):
// one valid/ready transfer per record on each channel; values of the core's 64 bits.
interface cva6_64_if (input logic clk);
    logic rst_n;
    // program (source)
    logic prog_valid, prog_ready;
    logic [29:0] prog_addr;
    logic [31:0] prog_data;
    logic prog_last;
    // issue (monitor)
    logic issue_valid;
    logic [63:0] issue_pc;
    logic [31:0] issue_insn;
    logic issue_c;
    // regw (monitor)
    logic regw_valid;
    logic [4:0] regw_rd;
    logic [63:0] regw_data;
    // store (monitor)
    logic store_valid;
    logic [63:0] store_addr;
    logic [7:0] store_be;
    logic [63:0] store_data;
    // irq (monitor)
    logic irq_valid;
    logic [31:0] irq_cause;
    logic [63:0] irq_seq;
    logic [63:0] irq_cycle;
    // csrr (monitor)
    logic csrr_valid;
    logic [63:0] csrr_data;
    // proto (monitor)
    logic proto_valid;
    logic [31:0] proto_value;
    logic [63:0] proto_cycle;
    // dev_req (monitor)
    logic dev_req_valid;
    logic [7:0] dev_req_dev;
    logic [31:0] dev_req_addr;
    logic dev_req_we;
    logic [3:0] dev_req_be;
    logic [31:0] dev_req_wdata;
    logic [63:0] dev_req_cycle;
    // dev_resp (source)
    logic dev_resp_valid, dev_resp_ready;
    logic [31:0] dev_resp_rdata;
    // in_irq_i (source)
    logic in_irq_i_valid, in_irq_i_ready;
    logic [63:0] in_irq_i_until;
    logic [31:0] in_irq_i_value;
    // cfg_lat (source)
    logic cfg_lat_valid, cfg_lat_ready;
    logic [31:0] cfg_lat_seed;
    logic [7:0] cfg_lat_gnt;
    logic [7:0] cfg_lat_rsp;
endinterface
