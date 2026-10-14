/// OCV throttle - pseudo-random pause request for flow-control stress: pause_o is high in a
/// cycle with probability duty_i/256. A 16-bit maximal-length Galois LFSR, restarted from SEED
/// on clear so a run is reproducible.
module ocv_throttle #(
    parameter logic [15:0] SEED = 16'hACE1
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       clear_i,
    input  logic [7:0] duty_i,
    output logic       pause_o
);
    logic [15:0] lfsr_q;

    always_ff @(posedge clk) begin
        if (~rst_n | clear_i) lfsr_q <= SEED;
        else                  lfsr_q <= {1'b0, lfsr_q[15:1]} ^ (lfsr_q[0] ? 16'hB400 : 16'h0000);
    end

    assign pause_o = (lfsr_q[7:0] < duty_i);

endmodule : ocv_throttle
