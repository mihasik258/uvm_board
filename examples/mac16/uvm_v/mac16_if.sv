// mac16_if.sv - the pins of mac16: operands in (valid/ready), results out (valid/ready), products
// out (valid only, an observation port).
interface mac16_if (input logic clk);
    logic               rst_n;
    logic               s_valid, s_ready;
    logic signed [15:0] s_a, s_b;
    logic               s_clr;
    logic               m_valid, m_ready;
    logic signed [39:0] m_acc;
    logic        [15:0] m_ts;
    logic               dbg_valid;
    logic signed [31:0] dbg_prod;
endinterface
