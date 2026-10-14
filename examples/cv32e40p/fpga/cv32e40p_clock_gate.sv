// cv32e40p_clock_gate for the FPGA: the core's clock gate (sleep, WFI) as OCV's DUT clock gate - a global
// clock buffer with enable (BUFGCE) on the board, the latch-and-gate model otherwise. The same ports and
// behaviour as cv32e40p's bhv/cv32e40p_sim_clock_gate.sv: the enable is taken while the clock is low.
module cv32e40p_clock_gate (
    input  logic clk_i,
    input  logic en_i,
    input  logic scan_cg_en_i,
    output logic clk_o
);
    ocv_clock_gate i_gate (.clk(clk_i), .en(en_i | scan_cg_en_i), .gclk(clk_o));
endmodule : cv32e40p_clock_gate
