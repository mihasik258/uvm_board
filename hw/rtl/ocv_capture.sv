/// OCV capture unit - turns a DUT record stream into buffer writes.
///
/// DUT-agnostic: a record is just REC_W bits qualified by rec_valid_i; what the bits mean
/// is defined by the DUT adapter and the matching software model, not here.
///
/// Two ways to attach:
///   BACKPRESSURE = 0  monitor. rec_valid_i is an already-completed transfer (e.g. a retire
///                     strobe, or valid & ready of a bus we only watch). A record that arrives
///                     while the buffer is full is dropped and counted (overflow is sticky).
///                     With stall_en the unit asks the DUT to pause (stall_o) while full; the
///                     DUT side must honour it before its next record to stay lossless.
///   BACKPRESSURE = 1  terminator. The unit is the consumer of a valid/ready stream and drives
///                     rec_ready_o; the producer holds its record while the buffer is full,
///                     capture is disabled or throttle_i asks for a pause, so nothing is lost.
///
/// dut_ce_i is high in cycles where the DUT's clock ticks; a record counts only then (the DUT
/// may be frozen by ocv_clock_gate). LOSSLESS makes stall_o follow `full` regardless of
/// stall_en - the wrapper freezes the DUT with it, so nothing is ever dropped.
///
/// Records are written in arrival order from address 0 until the buffer is full. clear_i
/// restarts the capture (count/overflow/dropped to zero) at the next clock edge.
///
/// FIFO = 1 (a sink that empties itself over DMA): the buffer is a circular FIFO. free_i releases
/// the oldest record (one per cycle at most); count_o is then the occupancy, wr_addr_o the write
/// pointer, and captured_o counts every record taken since the clear.
module ocv_capture #(
    parameter int unsigned REC_W        = 128,
    parameter int unsigned LOG2_DEPTH   = 13,
    parameter bit          BACKPRESSURE = 1'b0,
    parameter bit          LOSSLESS     = 1'b0,
    parameter bit          FIFO         = 1'b0
) (
    input  logic                  clk,
    input  logic                  rst_n,
    // record stream from the DUT adapter
    input  logic                  rec_valid_i,
    output logic                  rec_ready_o,
    input  logic                  dut_ce_i,       // DUT clock ticks this cycle
    input  logic [REC_W-1:0]      rec_data_i,
    // control
    input  logic                  enable_i,
    input  logic                  stall_en_i,
    input  logic                  throttle_i,     // BACKPRESSURE only: withhold ready this cycle
    input  logic                  clear_i,
    input  logic                  free_i,         // FIFO: the oldest record has been read out
    // buffer write port
    output logic                  wr_en_o,
    output logic [LOG2_DEPTH-1:0] wr_addr_o,
    output logic [REC_W-1:0]      wr_data_o,
    // status
    output logic [LOG2_DEPTH:0]   count_o,
    output logic                  full_o,
    output logic                  overflow_o,
    output logic [31:0]           dropped_o,
    output logic                  stall_o,
    output logic [31:0]           captured_o      // FIFO: records taken since the clear
);
    localparam logic [LOG2_DEPTH:0] DEPTH = (LOG2_DEPTH+1)'(1) << LOG2_DEPTH;

    logic [LOG2_DEPTH:0] count_q;
    logic [LOG2_DEPTH-1:0] wp_q;
    logic [31:0]         captured_q;
    logic                overflow_q;
    logic [31:0]         dropped_q;
    logic                drop;

    assign full_o      = (count_q == DEPTH);
    assign rec_ready_o = BACKPRESSURE ? (enable_i & ~full_o & ~throttle_i) : 1'b1;
    assign wr_en_o     = rec_valid_i & dut_ce_i & enable_i & ~full_o & (~BACKPRESSURE | ~throttle_i);
    assign wr_addr_o   = FIFO ? wp_q : count_q[LOG2_DEPTH-1:0];
    assign wr_data_o   = rec_data_i;
    assign drop        = ~BACKPRESSURE & rec_valid_i & dut_ce_i & enable_i & full_o;
    assign stall_o     = (stall_en_i | LOSSLESS) & full_o;

    always_ff @(posedge clk) begin
        if (~rst_n | clear_i) begin
            count_q    <= '0;
            wp_q       <= '0;
            captured_q <= '0;
            overflow_q <= 1'b0;
            dropped_q  <= '0;
        end else begin
            if (FIFO) begin
                count_q <= count_q + (LOG2_DEPTH+1)'(wr_en_o) - (LOG2_DEPTH+1)'(free_i);
                if (wr_en_o) begin
                    wp_q       <= wp_q + 1'b1;
                    captured_q <= captured_q + 1'b1;
                end
            end else if (wr_en_o) count_q <= count_q + 1'b1;
            if (drop) begin
                overflow_q <= 1'b1;
                if (dropped_q != '1) dropped_q <= dropped_q + 1'b1;
            end
        end
    end

    assign count_o    = count_q;
    assign captured_o = FIFO ? captured_q : 32'(count_q);
    assign overflow_o = overflow_q;
    assign dropped_o  = dropped_q;

endmodule : ocv_capture
