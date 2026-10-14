// scr1_if.sv - the pins of the SCR1 test harness (scr1_ocv_dut): program load port, RVFI-lite retire port.
interface scr1_if (input logic clk);
    logic        rst_n;
    // program load: one 32-bit word per transfer, valid/ready; 'last' starts the core
    logic        prog_valid, prog_ready;
    logic [13:0] prog_addr;
    logic [31:0] prog_data;
    logic        prog_last;
    // retire: one transfer per committed instruction
    logic        rvfi_valid;
    logic [31:0] rvfi_pc, rvfi_pc_next;
    logic [4:0]  rvfi_rd_addr;
    logic [31:0] rvfi_rd_wdata;
    logic        rvfi_trap;
    logic        rvfi_csr_rd;           // the instruction read a CSR ...
    logic [11:0] rvfi_csr_addr;         // ... this one
    logic        rvfi_mem_we;           // the instruction stored ...
    logic [3:0]  rvfi_mem_wmask;        // ... these bytes from rvfi_mem_addr
    logic [31:0] rvfi_mem_addr, rvfi_mem_wdata;
    logic        rvfi_csrw_we;          // the instruction wrote a CSR: 0 write, 1 set, 2 clear
    logic [1:0]  rvfi_csrw_cmd;
    logic [11:0] rvfi_csrw_addr;
    logic [31:0] rvfi_csrw_data;
endinterface
