/// mac16 - demo IP for the OCV platform: streaming signed multiply-accumulate.
///
/// Each input (a, b, clr) produces one output: acc = (clr ? 0 : acc) + a*b, a 40-bit signed
/// accumulator that wraps. Two-stage elastic pipeline with valid/ready on both sides.
///   m_ts   free-running cycle counter sampled when the result is produced - depends on
///          back-pressure, so it is not deterministic and is compared with rule "ignore".
///   dbg_*  observation port: one strobe per product entering the accumulator.
module mac16 (
    input  logic               clk,
    input  logic               rst_n,
    // operand stream
    input  logic               s_valid,
    output logic               s_ready,
    input  logic signed [15:0] s_a,
    input  logic signed [15:0] s_b,
    input  logic               s_clr,
    // result stream
    output logic               m_valid,
    input  logic               m_ready,
    output logic signed [39:0] m_acc,
    output logic        [15:0] m_ts,
    // observation
    output logic               dbg_valid,
    output logic signed [31:0] dbg_prod
);
    logic               v1, v2, r1, r2;
    logic signed [31:0] prod1;
    logic               clr1;
    logic signed [39:0] acc_q;
    logic        [15:0] cycle_q;

    assign r2      = ~v2 | m_ready;
    assign r1      = ~v1 | r2;
    assign s_ready = r1;
    assign m_valid = v2;

    assign dbg_valid = v1 & r2;
    assign dbg_prod  = prod1;

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            v1 <= 1'b0; v2 <= 1'b0; acc_q <= '0; cycle_q <= '0;
            prod1 <= '0; clr1 <= 1'b0; m_acc <= '0; m_ts <= '0;
        end else begin
            cycle_q <= cycle_q + 1'b1;
            if (r1) begin
                v1 <= s_valid;
                if (s_valid) begin
                    prod1 <= s_a * s_b;
                    clr1  <= s_clr;
                end
            end
            if (r2) begin
                v2 <= v1;
                if (v1) begin
                    acc_q <= (clr1 ? 40'sd0 : acc_q) + 40'(prod1);
                    m_acc <= (clr1 ? 40'sd0 : acc_q) + 40'(prod1);
                    m_ts  <= cycle_q;
                end
            end
        end
    end
endmodule : mac16
