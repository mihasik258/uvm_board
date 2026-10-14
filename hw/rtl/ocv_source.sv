/// OCV source endpoint - plays stimulus records, written by the PS into a buffer, onto a
/// valid/ready input of the DUT.
///
/// Slot layout matches ocv_sink (lower half CSRs, upper half buffer), but the buffer window is
/// read/write: the PS fills records 0..LENGTH-1 word by word, sets LENGTH and enables. Records
/// are then sent in order at up to one per cycle, honouring rec_ready_i. Once rec_valid_o is
/// raised it stays up with stable data until the transfer completes (AXI-Stream rule), even if
/// enable is dropped meanwhile; enable only gates starting new records.
///
/// Raising LENGTH while enabled continues playback from where it stopped, so the PS can append
/// records and extend LENGTH to keep a stream going without a rewind. To reload from scratch,
/// disable first.
///
/// clear (CSR, applied at the same edge as the CTRL write) or clear_i (DUT reset) rewinds to
/// record 0 and drops records already fetched - use it only while the DUT is idle or in reset.
///
/// THROTTLE (n/256) makes the source randomly hold back the start of a record, to stress the
/// DUT with bubbles; a record already presented stays presented until it is taken.
///
/// The buffer has one read port, shared by playback and PS read-back; a PS read wins its cycle
/// and playback resumes on the next one.
///
/// STREAM (reactive feeds, e.g. responses the PS computes from what the DUT asked): the buffer is a
/// ring and LENGTH, COUNT are 32-bit running totals. Record k lives in slot k mod depth; the PS may
/// write it once k < COUNT + depth, then raise LENGTH to k + 1. Without STREAM, LENGTH is capped at
/// the depth (a linear buffer).
///
/// FREEZE_STARVED: while the DUT is ready and the source presents nothing (the PS has not written
/// the record yet, or it is being fetched), starve_o asks the platform to stop the DUT clock, so the
/// time the PS takes to produce the next record is not visible to the DUT. Only for inputs whose ready means "waiting for data":
/// a DUT that keeps ready high while busy elsewhere would be frozen for good.
module ocv_source #(
    parameter int unsigned REC_W       = 128,  // record width in bits, multiple of 32
    parameter int unsigned LOG2_DEPTH  = 10,   // buffer holds 2**LOG2_DEPTH records
    parameter logic [15:0] THROTTLE_SEED = 16'hB00B,
    parameter bit          STREAM        = 1'b0,   // ring buffer fed during the run
    parameter bit          FREEZE_STARVED = 1'b0,  // freeze the DUT while it waits for a record
    // Derived - do not override.
    parameter int unsigned REC_WORDS   = REC_W / 32,
    parameter int unsigned LOG2_STRIDE = $clog2(REC_WORDS),
    // Each half of the slot is at least 64 bytes so the CSR offsets never alias.
    parameter int unsigned EP_AW       = ((LOG2_DEPTH + LOG2_STRIDE + 2) < 6 ? 6
                                     : (LOG2_DEPTH + LOG2_STRIDE + 2)) + 1
) (
    input  logic             clk,
    input  logic             rst_n,
    // DUT side
    output logic             rec_valid_o,
    input  logic             rec_ready_i,
    output logic [REC_W-1:0] rec_data_o,
    input  logic             dut_ce_i,        // DUT clock ticks this cycle (1 if never gated)
    input  logic             clear_i,         // rewind (DUT reset), synchronous
    output logic             starve_o,        // DUT waits for a record that is not there (FREEZE_STARVED)
    // register bus from ocv_hub
    input  logic             bus_wr,
    input  logic [EP_AW-1:0] bus_waddr,
    input  logic [31:0]      bus_wdata,
    input  logic [3:0]       bus_wstrb,
    input  logic             bus_rd,
    input  logic [EP_AW-1:0] bus_raddr,
    input  logic [EP_AW-1:0] bus_rd_addr_q,
    output logic [31:0]      bus_rdata
);
    import ocv_pkg::*;

    localparam int unsigned STRIDE = 1 << LOG2_STRIDE;
    localparam logic [LOG2_DEPTH:0] DEPTH = (LOG2_DEPTH+1)'(1) << LOG2_DEPTH;
    localparam int unsigned CW = STREAM ? 32 : LOG2_DEPTH + 1;   // record counters

    if (REC_W < 32 || REC_W % 32 != 0) begin : g_bad_rec_w
        $error("ocv_source: REC_W must be a non-zero multiple of 32");
    end
    if (REC_WORDS > 255 || LOG2_DEPTH < 1 || LOG2_DEPTH > 24) begin : g_bad_geometry
        $error("ocv_source: need 1 <= LOG2_DEPTH <= 24 and REC_W <= 255*32");
    end

    // ---------------- control registers ----------------
    logic                enable_q;
    logic [CW-1:0]       length_q;
    logic [7:0]          throttle_q;
    logic                wr_csr, wr_ctrl, wr_len, wr_thr, clear_now, pause;

    assign wr_csr    = bus_wr & ~bus_waddr[EP_AW-1];
    assign wr_ctrl   = wr_csr & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_CTRL))   & bus_wstrb[0];
    assign wr_len    = wr_csr & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_LENGTH)) & (&bus_wstrb);
    assign wr_thr    = wr_csr & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_THROTTLE)) & bus_wstrb[0];
    assign clear_now = clear_i | (wr_ctrl & bus_wdata[CTRL_CLEAR]);

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            enable_q   <= 1'b0;
            length_q   <= '0;
            throttle_q <= '0;
        end else begin
            if (wr_thr)  throttle_q <= bus_wdata[7:0];
            if (wr_ctrl) enable_q <= bus_wdata[CTRL_ENABLE];
            if (wr_len)  length_q <= (!STREAM && bus_wdata > 32'(DEPTH)) ? CW'(DEPTH) : CW'(bus_wdata);
        end
    end

    // ---------------- buffer: PS writes words, playback reads records ----------------
    logic                  ps_wr, ps_rd, issue;
    logic [7:0]            wword;
    logic [REC_W/8-1:0]    ram_we;
    logic [REC_W-1:0]      ram_rdata;
    logic [CW-1:0]         issued_q, sent_q;

    assign ps_wr = bus_wr & bus_waddr[EP_AW-1];
    assign ps_rd = bus_rd & bus_raddr[EP_AW-1];
    assign wword = 8'((32'(bus_waddr) >> 2) & (STRIDE - 1));

    always_comb begin
        ram_we = '0;
        for (int w = 0; w < REC_WORDS; w++)
            if (ps_wr && wword == 8'(w)) ram_we[4*w +: 4] = bus_wstrb;
    end

    ocv_ram #(
        .W  (REC_W),
        .AW (LOG2_DEPTH)
    ) i_ram (
        .clk   (clk),
        .we    (ram_we),
        .waddr (LOG2_DEPTH'(bus_waddr >> (2 + LOG2_STRIDE))),
        .wdata ({REC_WORDS{bus_wdata}}),
        .re    (ps_rd | issue),
        .raddr (ps_rd ? LOG2_DEPTH'(bus_raddr >> (2 + LOG2_STRIDE)) : issued_q[LOG2_DEPTH-1:0]),
        .rdata (ram_rdata)
    );

    // ---------------- playback: read-ahead into a 2-entry elastic buffer ----------------
    // A record fetched in cycle t arrives in cycle t+1 (inflight_q). A fetch is started only if
    // the buffer is guaranteed to have room for it, counting this cycle's pop. The record shown
    // to the DUT is always the head register, so rec_data_o comes straight from flops and the
    // DUT's input timing does not depend on the platform.
    logic [REC_W-1:0] head_q, tail_q;
    logic             head_v_q, tail_v_q, inflight_q, held_q;
    logic [1:0]       occ;
    logic             pop, push;

    ocv_throttle #(.SEED(THROTTLE_SEED)) i_throttle (
        .clk, .rst_n, .clear_i (clear_now), .duty_i (throttle_q), .pause_o (pause)
    );

    assign occ   = 2'(head_v_q) + 2'(tail_v_q);
    // A record is presented unless the throttle pauses it; once presented (held_q) it stays.
    assign rec_valid_o = head_v_q & (held_q | ~pause);
    assign rec_data_o  = head_q;
    assign pop   = rec_valid_o & rec_ready_i & dut_ce_i;   // a frozen DUT takes nothing
    assign push  = inflight_q;
    assign issue = enable_q & ~ps_rd & (issued_q < length_q)
                 & ((occ + 2'(inflight_q) - 2'(pop)) < 2'd2);
    // The DUT is asking and nothing is presented: whether the PS has not written the record yet
    // or it is still being fetched, the DUT is held, so it sees the same wait whatever the PS took.
    // (A throttle pause leaves head_v_q set: those bubbles are meant to reach the DUT.)
    assign starve_o = FREEZE_STARVED & enable_q & rec_ready_i & ~head_v_q;

    always_ff @(posedge clk) begin
        if (~rst_n | clear_now) begin
            issued_q   <= '0;
            sent_q     <= '0;
            inflight_q <= 1'b0;
            head_v_q   <= 1'b0;
            tail_v_q   <= 1'b0;
            held_q     <= 1'b0;
        end else begin
            held_q     <= rec_valid_o & ~pop;
            inflight_q <= issue;
            if (issue) issued_q <= issued_q + 1'b1;
            if (pop)   sent_q   <= sent_q + 1'b1;
            unique case ({pop, push})
                2'b01: if (!head_v_q) begin head_q <= ram_rdata; head_v_q <= 1'b1; end
                       else           begin tail_q <= ram_rdata; tail_v_q <= 1'b1; end
                2'b10: if (tail_v_q)  begin head_q <= tail_q; tail_v_q <= 1'b0; end
                       else                 head_v_q <= 1'b0;
                2'b11: head_q <= ram_rdata;   // tail is empty whenever a record arrives
                default: ;
            endcase
        end
    end

`ifndef SYNTHESIS
    // Invariant behind the fetch rule: a record never arrives while both entries are full.
    always_ff @(posedge clk)
        if (rst_n && !clear_now && push && tail_v_q) $error("ocv_source: record arrived into a full buffer");
`endif

    // ---------------- read data (cycle after bus_rd) ----------------
    logic [7:0]       rword;
    logic             done, active;
    assign rword = 8'((32'(bus_rd_addr_q) >> 2) & (STRIDE - 1));
    assign done   = (sent_q == length_q);
    assign active = head_v_q | inflight_q | (enable_q & (issued_q < length_q));

    always_comb begin
        bus_rdata = '0;
        if (bus_rd_addr_q[EP_AW-1]) begin
            if (rword < 8'(REC_WORDS)) bus_rdata = ram_rdata[32*rword +: 32];
        end else begin
            unique case (bus_rd_addr_q[EP_AW-2:0])
                (EP_AW-1)'(EP_REG_ID):       bus_rdata = EP_ID;
                (EP_AW-1)'(EP_REG_VERSION):  bus_rdata = EP_VERSION;
                (EP_AW-1)'(EP_REG_GEOMETRY): bus_rdata = {8'(EP_AW-1), 8'(LOG2_STRIDE),
                                                          8'(LOG2_DEPTH), 8'(REC_WORDS)};
                (EP_AW-1)'(EP_REG_KIND):     bus_rdata = 32'(EP_KIND_SOURCE)
                                                         | (32'(STREAM) << KIND_STREAM)
                                                         | (32'(FREEZE_STARVED) << KIND_FREEZE_STARVED);
                (EP_AW-1)'(EP_REG_CTRL):     bus_rdata = 32'(enable_q);
                (EP_AW-1)'(EP_REG_STATUS):   bus_rdata = 32'({active, 1'b0, enable_q, 1'b0, done});
                (EP_AW-1)'(EP_REG_COUNT):    bus_rdata = 32'(sent_q);
                (EP_AW-1)'(EP_REG_LENGTH):   bus_rdata = 32'(length_q);
                (EP_AW-1)'(EP_REG_THROTTLE): bus_rdata = 32'(throttle_q);
                default:                     bus_rdata = '0;
            endcase
        end
    end

endmodule : ocv_source
