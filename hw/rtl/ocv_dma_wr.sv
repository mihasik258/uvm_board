/// OCV DMA writer - empties a sink's record FIFO into a ring in the PS memory over an AXI4 master.
///
/// The PS reads its records from its own (cached) memory instead of the endpoint's buffer window:
/// on the VD100 a bus read of the window costs ~400 ns per word, a record in DDR a few ns.
///
/// Ring (set by the PS, ocv_pkg EP_REG_RING_*): 2**ring_log2 slots of 2**SLOT_LOG2 bytes at
/// ring_base (aligned to the ring's size); record k since the clear goes to slot
/// k mod 2**ring_log2, zero-padded to the slot. head_o counts records whose write response has
/// arrived (only then is the data in memory); the PS consumes them and moves tail_i. The writer
/// never gets more than 2**ring_log2 records ahead of tail_i: with the ring full the FIFO fills and
/// a lossless sink freezes the DUT, as with a full buffer - nothing is lost.
///
/// Bursts: INCR, full data width, all strobes; at most 256 bytes (or one record if a slot is
/// larger), never across a 256-byte boundary - hence never across 4 KiB - nor the ring's end. One
/// burst is formed at a time (address and data issued together - AXI forbids waiting for AWREADY
/// before WVALID); up to BQ_DEPTH bursts wait for their responses.
///
/// clear_i (DUT reset): pointers and counters restart at zero. A burst already promised on AW is
/// completed with zero data and its response, like those still outstanding, does not count - the
/// next records overwrite those slots in order (same ID) before head_o reaches them.
module ocv_dma_wr #(
    parameter int unsigned REC_W      = 128,  // stored record width, multiple of 32
    parameter int unsigned LOG2_DEPTH = 13,   // FIFO (the sink's buffer) depth
    parameter int unsigned DW         = 128,  // AXI data width: 64, 128, 256 or 512
    parameter int unsigned AXI_AW     = 64,
    parameter int unsigned SLOT_LOG2  = 5,    // log2 bytes per ring slot (>= log2(DW/8), >= record)
    parameter int unsigned BQ_DEPTH   = 8     // bursts waiting for a write response
) (
    input  logic                   clk,
    input  logic                   rst_n,
    input  logic                   clear_i,
    // ring, from the endpoint's registers
    input  logic [63:0]            ring_base_i,
    input  logic [4:0]             ring_log2_i,     // 0: off
    input  logic [31:0]            tail_i,
    output logic [31:0]            head_o,
    output logic                   error_o,         // sticky until clear
    output logic                   busy_o,
    // the sink's FIFO
    input  logic [LOG2_DEPTH:0]    occ_i,           // records held
    output logic                   rd_en_o,
    output logic [LOG2_DEPTH-1:0]  rd_addr_o,
    input  logic [REC_W-1:0]       rd_data_i,       // the cycle after rd_en_o
    output logic                   free_o,          // the oldest record has been read out
    // AXI4 master, write channels (single ID)
    output logic [AXI_AW-1:0]      m_axi_awaddr,
    output logic [7:0]             m_axi_awlen,
    output logic [2:0]             m_axi_awsize,
    output logic [1:0]             m_axi_awburst,
    output logic [3:0]             m_axi_awcache,
    output logic                   m_axi_awvalid,
    input  logic                   m_axi_awready,
    output logic [DW-1:0]          m_axi_wdata,
    output logic [DW/8-1:0]        m_axi_wstrb,
    output logic                   m_axi_wlast,
    output logic                   m_axi_wvalid,
    input  logic                   m_axi_wready,
    input  logic [1:0]             m_axi_bresp,
    input  logic                   m_axi_bvalid,
    output logic                   m_axi_bready
);
    localparam int unsigned DWB_LOG2  = $clog2(DW / 8);
    localparam int unsigned SLOT_BITS = 8 << SLOT_LOG2;
    localparam int unsigned BPR       = 1 << (SLOT_LOG2 - DWB_LOG2);           // beats per record
    // records per burst block: a burst stays inside one 256-byte block (one record if larger)
    localparam int unsigned BLK_LOG2  = SLOT_LOG2 >= 8 ? 0 : 8 - SLOT_LOG2;
    localparam int unsigned BQ_AW     = $clog2(BQ_DEPTH);

    if (DW != 64 && DW != 128 && DW != 256 && DW != 512) begin : g_bad_dw
        $error("ocv_dma_wr: DW must be 64, 128, 256 or 512");
    end
    if (SLOT_LOG2 < DWB_LOG2 || SLOT_BITS < REC_W || SLOT_LOG2 > 10) begin : g_bad_slot
        $error("ocv_dma_wr: a slot must hold a record and a data beat, at most 1 KiB");
    end
    if (BQ_DEPTH < 2 || (BQ_DEPTH & (BQ_DEPTH - 1)) != 0) begin : g_bad_bq
        $error("ocv_dma_wr: BQ_DEPTH must be a power of two >= 2");
    end

    logic        ring_on;
    logic [31:0] ring_n, issued_q, head_q, space, blk_left, n_pick;
    logic [2:0]  epoch_q;
    assign ring_on = ring_log2_i != 5'd0;
    assign ring_n  = 32'd1 << ring_log2_i;
    assign space   = ring_n - (issued_q - tail_i);
    assign blk_left = (32'd1 << BLK_LOG2) - (issued_q & ((32'd1 << BLK_LOG2) - 1));
    logic [31:0] slot_idx, wrap_left;
    logic [63:0] slot_off;
    assign slot_idx  = issued_q & (ring_n - 32'd1);
    assign wrap_left = ring_n - slot_idx;               // a ring smaller than a block: stop at its end
    assign slot_off = {32'b0, slot_idx} << SLOT_LOG2;

    // ---------------- burst formation ----------------
    logic        aw_pend_q;
    logic [31:0] to_read_q, to_send_q;       // records of the current burst
    logic        stale_q;                    // cleared while the burst was being sent: zero data
    logic [LOG2_DEPTH-1:0] rp_q;
    logic [BQ_AW:0] bq_cnt;
    logic        issue;

    always_comb begin
        n_pick = 32'(occ_i);
        if (space < n_pick)    n_pick = space;
        if (blk_left < n_pick) n_pick = blk_left;
        if (wrap_left < n_pick) n_pick = wrap_left;
    end
    assign issue = ring_on & ~clear_i & ~aw_pend_q & (to_send_q == 0) & (occ_i != '0)
                 & (space != 0) & (bq_cnt < (BQ_AW+1)'(BQ_DEPTH));

    // ---------------- record staging: BRAM (1-cycle read) -> 2-entry register FIFO -> beats ----
    logic [SLOT_BITS-1:0] rf_q [2];
    logic                 rf_head_q;          // index of the record being sent
    logic [1:0]           rf_cnt_q;
    logic                 rd_inflight_q;
    logic [$clog2(BPR+1)-1:0] beat_q;
    logic                 w_fire, rec_done, push, pop;

    assign rd_en_o   = (to_read_q != 0) & ({1'b0, rf_cnt_q} + {2'b0, rd_inflight_q} < 3'd2) & ~clear_i;
    assign rd_addr_o = rp_q;
    assign push      = rd_inflight_q & ~clear_i;
    assign free_o    = push;

    assign m_axi_wvalid = (to_send_q != 0) & (stale_q | (rf_cnt_q != 0));
    assign m_axi_wdata  = stale_q ? '0 : rf_q[rf_head_q][DW*beat_q +: DW];
    assign m_axi_wstrb  = '1;
    assign m_axi_wlast  = (to_send_q == 32'd1) & (beat_q == ($clog2(BPR+1))'(BPR - 1));
    assign w_fire       = m_axi_wvalid & m_axi_wready;
    assign rec_done     = w_fire & (beat_q == ($clog2(BPR+1))'(BPR - 1));
    assign pop          = rec_done & ~stale_q;

    // ---------------- write responses ----------------
    logic [31:0] bq_n  [BQ_DEPTH];
    logic [2:0]  bq_ep [BQ_DEPTH];
    logic [BQ_AW-1:0] bq_wp, bq_rp;
    logic        b_fire, bq_push;
    assign m_axi_bready = 1'b1;
    assign b_fire  = m_axi_bvalid;
    assign bq_push = issue;

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            aw_pend_q <= 1'b0; to_read_q <= '0; to_send_q <= '0; stale_q <= 1'b0; rp_q <= '0;
            issued_q <= '0; head_q <= '0; epoch_q <= '0; error_o <= 1'b0;
            rf_head_q <= 1'b0; rf_cnt_q <= '0; rd_inflight_q <= 1'b0; beat_q <= '0;
            bq_wp <= '0; bq_rp <= '0; bq_cnt <= '0;
            m_axi_awaddr <= '0; m_axi_awlen <= '0;
        end else begin
            // address channel: one burst promised at a time
            if (issue) begin
                aw_pend_q    <= 1'b1;
                m_axi_awaddr <= AXI_AW'(ring_base_i + slot_off);
                m_axi_awlen  <= 8'(n_pick * BPR - 1);
                to_read_q    <= n_pick;
                to_send_q    <= n_pick;
                issued_q     <= issued_q + n_pick;
            end else if (aw_pend_q & m_axi_awready) begin
                aw_pend_q <= 1'b0;
            end

            // reads from the FIFO into the staging registers
            if (rd_en_o) begin
                rp_q      <= rp_q + 1'b1;
                to_read_q <= to_read_q - 1;
            end
            rd_inflight_q <= rd_en_o;
            if (push) rf_q[rf_head_q ^ rf_cnt_q[0]] <= SLOT_BITS'(rd_data_i);

            // beats
            if (w_fire) begin
                if (rec_done) begin
                    beat_q    <= '0;
                    to_send_q <= to_send_q - 1;
                    if (to_send_q == 32'd1) stale_q <= 1'b0;
                end else begin
                    beat_q <= beat_q + 1'b1;
                end
            end
            if (pop) rf_head_q <= ~rf_head_q;
            rf_cnt_q <= rf_cnt_q + 2'(push) - 2'(pop);

            // responses: the oldest burst completes
            if (bq_push) begin
                bq_n[bq_wp]  <= n_pick;
                bq_ep[bq_wp] <= epoch_q;
                bq_wp        <= bq_wp + 1'b1;
            end
            if (b_fire) begin
                bq_rp <= bq_rp + 1'b1;
                if (bq_ep[bq_rp] == epoch_q) begin
                    head_q <= head_q + bq_n[bq_rp];
                    if (m_axi_bresp != 2'b00) error_o <= 1'b1;
                end
            end
            bq_cnt <= bq_cnt + (BQ_AW+1)'(bq_push) - (BQ_AW+1)'(b_fire);

            // clear: restart; a burst being sent finishes with zero data, responses not counted
            if (clear_i) begin
                rp_q <= '0; to_read_q <= '0; issued_q <= '0; head_q <= '0; error_o <= 1'b0;
                epoch_q <= epoch_q + 1'b1;
                rf_cnt_q <= '0; rf_head_q <= 1'b0; rd_inflight_q <= 1'b0;
                if (to_send_q != 0 && !(rec_done && to_send_q == 32'd1)) stale_q <= 1'b1;
            end
        end
    end

    assign head_o        = head_q;
    assign busy_o        = aw_pend_q | (to_send_q != 0) | (bq_cnt != 0);
    assign m_axi_awvalid = aw_pend_q;
    assign m_axi_awsize  = 3'(DWB_LOG2);
    assign m_axi_awburst = 2'b01;      // INCR
    assign m_axi_awcache = 4'b0011;    // normal, non-cacheable, bufferable

    if (AXI_AW < 64) begin : g_unused_base
        logic unused;
        assign unused = ^ring_base_i[63:AXI_AW];
    end

endmodule : ocv_dma_wr
