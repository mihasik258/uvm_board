/// OCV sink endpoint - captures a DUT record stream into a buffer the PS reads back.
///
/// Endpoint slot layout (EP_AW bits, byte addressed): lower half CSRs (ocv_pkg EP_REG_*),
/// upper half the read-only record buffer. Record i, word j (j = 0 holds rec_data[31:0]) is at
/// BUF + ((i << LOG2_STRIDE) + j) * 4, BUF = 1 << (EP_AW-1); slot words past REC_WORDS read 0.
/// Attached to the PS through ocv_hub's register bus.
///
/// SQUASH = 1: the endpoint fuses windows of EP_REG_SQUASH records (DiffTest-style "squash"): it
/// stores one record per window - {CRC32 (poly EDB88320), CRC32C (poly 82F63B78), count, last raw
/// record} (REC_W = IN_W + 96) - instead of every record. Both CRCs run over every record of the
/// window, word by word (word 0 first, LSB first, initial value all ones, no final inversion: what
/// the ARMv8 crc32w/crc32cw instructions compute), on the compared bits only: a mask the PS sets
/// at run time (EP_REG_SQMASK_SEL/EP_REG_SQMASK, KIND_SQMASK; reset value MASK). A record that matches
/// an enabled break pattern ((rec & mask) == value, EP_REG_BRK_*, KIND_SQBRK) closes its window: it is
/// that window's last record, carried whole - DiffTest's way to hand the PS a value it must take from
/// the DUT (a timer read, a device register) while everything else stays fused. The fused
/// record of a window is produced in the cycle its last record arrives, as a raw record would be,
/// so the lossless/backpressure behaviour is unchanged. CTRL_FLUSH emits a partly filled window.
///
/// DMA = 1 (KIND_DMA): the buffer is a FIFO that ocv_dma_wr empties over the AXI4 master into a
/// ring in the PS memory, once the PS has set one (EP_REG_RING_*). Until then - and whenever
/// RING_LOG2 is 0 - the endpoint behaves exactly as without DMA (the PS reads the buffer window).
/// COUNT then counts every record captured since the clear; the PS takes those in the ring
/// (RING_HEAD) and acknowledges them (RING_TAIL).
module ocv_sink #(
    parameter int unsigned REC_W           = 128,  // stored record width in bits, multiple of 32
    parameter bit          SQUASH          = 1'b0, // 1: fuse windows of records (see above)
    parameter int unsigned IN_W            = SQUASH ? REC_W - 96 : REC_W,  // DUT record width
    parameter logic [IN_W-1:0] MASK        = '1,   // SQUASH: reset value of the signatures' mask
    parameter int unsigned LOG2_DEPTH      = 13,   // buffer holds 2**LOG2_DEPTH records
    parameter bit          BACKPRESSURE    = 1'b0, // 1: consume a valid/ready stream (lossless)
    parameter bit          LOSSLESS        = 1'b0, // 1: stall_o freezes the DUT whenever full
    parameter bit          ENABLE_AT_RESET = 1'b1, // capture from reset without software action
    parameter logic [15:0] THROTTLE_SEED   = 16'hACE1,
    parameter bit          DMA             = 1'b0, // 1: the buffer empties itself into a PS ring
    parameter int unsigned DMA_DW          = 128,  // DMA: AXI data width
    parameter int unsigned DMA_AW          = 64,   // DMA: AXI address width
    // Derived - do not override.
    parameter int unsigned REC_WORDS       = REC_W / 32,
    parameter int unsigned LOG2_STRIDE     = $clog2(REC_WORDS),
    // Each half of the slot is at least 64 bytes (128 with DMA's registers) so the CSR offsets
    // never alias.
    parameter int unsigned EP_AW           = ((LOG2_DEPTH + LOG2_STRIDE + 2) < (DMA ? 7 : 6) ? (DMA ? 7 : 6)
                                     : (LOG2_DEPTH + LOG2_STRIDE + 2)) + 1,
    parameter int unsigned DMA_SLOT_LOG2   = (LOG2_STRIDE + 2) > $clog2(DMA_DW / 8) ? (LOG2_STRIDE + 2)
                                                                                  : $clog2(DMA_DW / 8)
) (
    input  logic             clk,
    input  logic             rst_n,
    // DUT side
    input  logic             rec_valid_i,
    output logic             rec_ready_o,     // used when BACKPRESSURE = 1
    input  logic [IN_W-1:0]  rec_data_i,
    input  logic             dut_ce_i,        // DUT clock ticks this cycle (1 if never gated)
    input  logic             clear_i,         // restart capture (DUT reset), synchronous
    output logic             stall_o,         // ask the DUT to pause (stall_en and full)
    // register bus from ocv_hub
    input  logic             bus_wr,
    input  logic [EP_AW-1:0] bus_waddr,
    input  logic [31:0]      bus_wdata,
    input  logic [3:0]       bus_wstrb,
    input  logic             bus_rd,
    input  logic [EP_AW-1:0] bus_raddr,
    input  logic [EP_AW-1:0] bus_rd_addr_q,
    output logic [31:0]      bus_rdata,
    // AXI4 master, write channels (DMA = 1; idle otherwise)
    output logic [DMA_AW-1:0]   m_axi_awaddr,
    output logic [7:0]          m_axi_awlen,
    output logic [2:0]          m_axi_awsize,
    output logic [1:0]          m_axi_awburst,
    output logic [3:0]          m_axi_awcache,
    output logic                m_axi_awvalid,
    input  logic                m_axi_awready,
    output logic [DMA_DW-1:0]   m_axi_wdata,
    output logic [DMA_DW/8-1:0] m_axi_wstrb,
    output logic                m_axi_wlast,
    output logic                m_axi_wvalid,
    input  logic                m_axi_wready,
    input  logic [1:0]          m_axi_bresp,
    input  logic                m_axi_bvalid,
    output logic                m_axi_bready
);
    import ocv_pkg::*;

    localparam int unsigned STRIDE = 1 << LOG2_STRIDE;

    if (REC_W < 32 || REC_W % 32 != 0) begin : g_bad_rec_w
        $error("ocv_sink: REC_W must be a non-zero multiple of 32");
    end
    if (SQUASH && (IN_W % 32 != 0 || REC_W != IN_W + 96)) begin : g_bad_squash
        $error("ocv_sink: SQUASH needs IN_W a multiple of 32 and REC_W = IN_W + 96");
    end
    if (REC_WORDS > 255 || LOG2_DEPTH < 1 || LOG2_DEPTH > 24) begin : g_bad_geometry
        $error("ocv_sink: need 1 <= LOG2_DEPTH <= 24 and REC_W <= 255*32");
    end

    // ---------------- control registers ----------------
    logic       enable_q, stall_en_q, wr_ctrl, wr_thr, wr_sq, wr_msel, wr_mask, wr_bsel, wr_bdat, clear_now, pause;
    logic [7:0] throttle_q;
    logic [31:0] window_q;

    assign wr_ctrl   = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_CTRL)) & bus_wstrb[0];
    assign wr_thr    = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_THROTTLE)) & bus_wstrb[0];
    assign wr_sq     = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_SQUASH)) & (&bus_wstrb);
    assign wr_msel   = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_SQMASK_SEL)) & (&bus_wstrb);
    assign wr_mask   = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_SQMASK)) & (&bus_wstrb);
    assign wr_bsel   = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_BRK_SEL)) & (&bus_wstrb);
    assign wr_bdat   = bus_wr & ~bus_waddr[EP_AW-1]
                     & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_BRK_DATA)) & (&bus_wstrb);
    assign clear_now = clear_i | (wr_ctrl & bus_wdata[CTRL_CLEAR]);

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            enable_q   <= ENABLE_AT_RESET;
            stall_en_q <= 1'b0;
            throttle_q <= '0;
            window_q   <= 32'd1;
        end else begin
            if (wr_sq) window_q <= bus_wdata;
            if (wr_ctrl) begin
                enable_q   <= bus_wdata[CTRL_ENABLE];
                stall_en_q <= bus_wdata[CTRL_STALL_EN];
            end
            if (wr_thr) throttle_q <= bus_wdata[7:0];
        end
    end

    ocv_throttle #(.SEED(THROTTLE_SEED)) i_throttle (
        .clk, .rst_n, .clear_i (clear_now), .duty_i (throttle_q), .pause_o (pause)
    );

    // ---------------- squash (optional) ----------------
    logic             full;
    logic             cap_valid, cap_ce;
    logic [31:0]      taken, mask_rd, bsel_rd, bdat_rd;
    logic [7:0]       msel_rd;
    logic [REC_W-1:0] cap_data;

    if (SQUASH) begin : g_squash
        localparam int unsigned IN_WORDS = IN_W / 32;
        localparam logic [31:0] POLY_C = 32'h82F6_3B78;   // CRC32C (Castagnoli), reflected
        localparam logic [31:0] POLY_Z = 32'hEDB8_8320;   // CRC32 (IEEE), reflected

        function automatic logic [31:0] crc_rec(input logic [31:0] crc, input logic [IN_W-1:0] rec,
                                                input logic [31:0] poly);
            for (int w = 0; w < IN_WORDS; w++)
                for (int b = 0; b < 32; b++)
                    crc = (crc >> 1) ^ (poly & {32{crc[0] ^ rec[32*w + b]}});
            return crc;
        endfunction

        logic [31:0]     cnt_q, crcc_q, crcz_q, cnt_n, crcc_n, crcz_n, crcc_b, crcz_b, win, taken_q;
        logic [IN_W-1:0] last_q, rec_m, mask_q;
        logic [7:0]      msel_q;
        logic            take, close, flush_q, flush_emit;

        // the compared-bits mask: set by the PS before the DUT runs (a DUT reset keeps it)
        always_ff @(posedge clk) begin
            if (~rst_n) begin
                mask_q <= MASK;
                msel_q <= '0;
            end else begin
                if (wr_msel) msel_q <= bus_wdata[7:0];
                for (int w = 0; w < IN_WORDS; w++)
                    if (wr_mask && msel_q == 8'(w)) mask_q[32*w +: 32] <= bus_wdata;
            end
        end
        always_comb begin
            mask_rd = '0;
            for (int w = 0; w < IN_WORDS; w++)
                if (msel_q == 8'(w)) mask_rd = mask_q[32*w +: 32];
        end

        // break patterns: (rec & mask) == value closes the window
        localparam int unsigned BRK_N = 4;
        logic [IN_W-1:0] bmask_q [BRK_N], bval_q [BRK_N];
        logic [BRK_N-1:0] ben_q, bhit;
        logic [7:0]  bword_q;
        logic [2:0]  bpat_q;
        logic        bisval_q, brk;
        always_ff @(posedge clk) begin
            if (~rst_n) begin
                ben_q <= '0; bword_q <= '0; bpat_q <= '0; bisval_q <= 1'b0;
                for (int k = 0; k < BRK_N; k++) begin bmask_q[k] <= '0; bval_q[k] <= '0; end
            end else begin
                if (wr_bsel) begin
                    bword_q  <= bus_wdata[7:0];
                    bpat_q   <= bus_wdata[10:8];
                    bisval_q <= bus_wdata[11];
                    ben_q    <= bus_wdata[16 +: BRK_N];
                end
                for (int k = 0; k < BRK_N; k++)
                    for (int w = 0; w < IN_WORDS; w++)
                        if (wr_bdat && bpat_q == 3'(k) && bword_q == 8'(w)) begin
                            if (bisval_q) bval_q[k][32*w +: 32]  <= bus_wdata;
                            else          bmask_q[k][32*w +: 32] <= bus_wdata;
                        end
            end
        end
        always_comb begin
            for (int k = 0; k < BRK_N; k++) bhit[k] = ben_q[k] & ((rec_data_i & bmask_q[k]) == bval_q[k]);
            brk = |bhit;
            bsel_rd = {8'b0, 8'(ben_q), 4'b0, bisval_q, bpat_q, bword_q};
            bdat_rd = '0;
            for (int k = 0; k < BRK_N; k++)
                for (int w = 0; w < IN_WORDS; w++)
                    if (bpat_q == 3'(k) && bword_q == 8'(w))
                        bdat_rd = bisval_q ? bval_q[k][32*w +: 32] : bmask_q[k][32*w +: 32];
        end

        assign win    = (window_q == 32'd0) ? 32'd1 : window_q;
        // the same acceptance as ocv_capture's: a DUT record that is taken this cycle
        assign take   = rec_valid_i & dut_ce_i & enable_q & ~full & (~BACKPRESSURE | ~pause);
        assign rec_m  = rec_data_i & mask_q;
        assign msel_rd = msel_q;
        assign crcc_b = (cnt_q == 32'd0) ? 32'hFFFF_FFFF : crcc_q;
        assign crcz_b = (cnt_q == 32'd0) ? 32'hFFFF_FFFF : crcz_q;
        assign crcc_n = crc_rec(crcc_b, rec_m, POLY_C);
        assign crcz_n = crc_rec(crcz_b, rec_m, POLY_Z);
        assign cnt_n  = cnt_q + 32'd1;
        assign close  = take & ((cnt_n >= win) | brk);
        // a partly filled window, on request, when no DUT record is taken this cycle
        assign flush_emit = flush_q & (cnt_q != 32'd0) & ~take & ~full & enable_q;

        assign cap_valid = close | flush_emit;
        assign cap_ce    = close ? dut_ce_i : 1'b1;
        assign cap_data  = close ? {crcz_n, crcc_n, cnt_n, rec_data_i}
                                 : {crcz_q, crcc_q, cnt_q, last_q};

        always_ff @(posedge clk) begin                 // progress, kept across buffer restarts
            if (~rst_n | clear_i) taken_q <= '0;
            else if (take)         taken_q <= taken_q + 32'd1;
        end
        assign taken = taken_q;

        always_ff @(posedge clk) begin
            if (~rst_n | clear_now) begin
                cnt_q   <= '0;
                crcc_q  <= '0;
                crcz_q  <= '0;
                last_q  <= '0;
                flush_q <= 1'b0;
            end else begin
                if (wr_ctrl & bus_wdata[CTRL_FLUSH]) flush_q <= 1'b1;
                else if (flush_emit | (cnt_q == 32'd0 & ~take)) flush_q <= 1'b0;
                if (take) begin
                    cnt_q  <= close ? 32'd0 : cnt_n;
                    crcc_q <= crcc_n;
                    crcz_q <= crcz_n;
                    last_q <= rec_data_i;
                end else if (flush_emit) begin
                    cnt_q <= 32'd0;
                end
            end
        end
    end else begin : g_plain
        assign taken     = '0;
        assign mask_rd   = '0;
        assign msel_rd   = '0;
        assign bsel_rd   = '0;
        assign bdat_rd   = '0;
        assign cap_valid = rec_valid_i;
        assign cap_ce    = dut_ce_i;
        assign cap_data  = rec_data_i;
    end

    // ---------------- capture + buffer ----------------
    logic                  wr_en;
    logic [LOG2_DEPTH-1:0] wr_addr;
    logic [REC_W-1:0]      wr_data;
    logic [LOG2_DEPTH:0]   count;
    logic                  overflow;
    logic [31:0]           dropped;
    logic [REC_W-1:0]      ram_rdata;
    logic [31:0]           captured;
    logic                  dma_free, dma_re;
    logic [LOG2_DEPTH-1:0] dma_raddr;

    ocv_capture #(
        .REC_W        (REC_W),
        .LOG2_DEPTH   (LOG2_DEPTH),
        .BACKPRESSURE (BACKPRESSURE),
        .LOSSLESS     (LOSSLESS),
        .FIFO         (DMA)
    ) i_capture (
        .clk         (clk),
        .rst_n       (rst_n),
        .rec_valid_i (cap_valid),
        .rec_ready_o (rec_ready_o),
        .dut_ce_i    (cap_ce),
        .rec_data_i  (cap_data),
        .enable_i    (enable_q),
        .stall_en_i  (stall_en_q),
        .throttle_i  (pause),
        .clear_i     (clear_now),
        .free_i      (dma_free),
        .wr_en_o     (wr_en),
        .wr_addr_o   (wr_addr),
        .wr_data_o   (wr_data),
        .count_o     (count),
        .full_o      (full),
        .overflow_o  (overflow),
        .dropped_o   (dropped),
        .stall_o     (stall_o),
        .captured_o  (captured)
    );

    ocv_ram #(
        .W  (REC_W),
        .AW (LOG2_DEPTH)
    ) i_ram (
        .clk   (clk),
        .we    ({(REC_W/8){wr_en}}),
        .waddr (wr_addr),
        .wdata (wr_data),
        .re    (dma_on ? dma_re : bus_rd & bus_raddr[EP_AW-1]),
        .raddr (dma_on ? dma_raddr : LOG2_DEPTH'(bus_raddr >> (2 + LOG2_STRIDE))),
        .rdata (ram_rdata)
    );

    // ---------------- DMA (optional): the buffer empties itself into a ring in PS memory ----------
    logic        dma_on;
    logic [31:0] ring_lo_q, ring_hi_q, ring_tail_q, ring_head, ring_log2_rd;
    logic [4:0]  ring_log2_q;
    logic        dma_err, dma_busy;
    if (DMA) begin : g_dma
        logic wr_rlo, wr_rhi, wr_rlog, wr_rtail;
        assign wr_rlo   = bus_wr & ~bus_waddr[EP_AW-1] & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_RING_LO))   & (&bus_wstrb);
        assign wr_rhi   = bus_wr & ~bus_waddr[EP_AW-1] & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_RING_HI))   & (&bus_wstrb);
        assign wr_rlog  = bus_wr & ~bus_waddr[EP_AW-1] & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_RING_LOG2)) & bus_wstrb[0];
        assign wr_rtail = bus_wr & ~bus_waddr[EP_AW-1] & (bus_waddr[EP_AW-2:0] == (EP_AW-1)'(EP_REG_RING_TAIL)) & (&bus_wstrb);
        always_ff @(posedge clk) begin
            if (~rst_n) begin
                ring_lo_q <= '0; ring_hi_q <= '0; ring_log2_q <= '0; ring_tail_q <= '0;
            end else begin
                if (wr_rlo)  ring_lo_q   <= bus_wdata;
                if (wr_rhi)  ring_hi_q   <= bus_wdata;
                if (wr_rlog) ring_log2_q <= bus_wdata[4:0];
                if (clear_now)     ring_tail_q <= '0;       // a fresh capture: the PS restarts at 0
                else if (wr_rtail) ring_tail_q <= bus_wdata;
            end
        end
        assign dma_on       = ring_log2_q != 5'd0;
        assign ring_log2_rd = {8'b0, 8'($clog2(DMA_DW / 8)), 8'(DMA_SLOT_LOG2), 3'b0, ring_log2_q};
        ocv_dma_wr #(
            .REC_W (REC_W), .LOG2_DEPTH (LOG2_DEPTH), .DW (DMA_DW), .AXI_AW (DMA_AW),
            .SLOT_LOG2 (DMA_SLOT_LOG2)
        ) i_dma (
            .clk, .rst_n, .clear_i (clear_now),
            .ring_base_i ({ring_hi_q, ring_lo_q}), .ring_log2_i (ring_log2_q), .tail_i (ring_tail_q),
            .head_o (ring_head), .error_o (dma_err), .busy_o (dma_busy),
            .occ_i (count), .rd_en_o (dma_re), .rd_addr_o (dma_raddr), .rd_data_i (ram_rdata),
            .free_o (dma_free),
            .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst, .m_axi_awcache,
            .m_axi_awvalid, .m_axi_awready, .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast,
            .m_axi_wvalid, .m_axi_wready, .m_axi_bresp, .m_axi_bvalid, .m_axi_bready
        );
    end else begin : g_no_dma
        assign dma_on = 1'b0; assign dma_re = 1'b0; assign dma_raddr = '0; assign dma_free = 1'b0;
        assign ring_lo_q = '0; assign ring_hi_q = '0; assign ring_log2_q = '0; assign ring_tail_q = '0;
        assign ring_head = '0; assign ring_log2_rd = '0; assign dma_err = 1'b0; assign dma_busy = 1'b0;
        assign m_axi_awaddr = '0; assign m_axi_awlen = '0; assign m_axi_awsize = '0;
        assign m_axi_awburst = '0; assign m_axi_awcache = '0; assign m_axi_awvalid = 1'b0;
        assign m_axi_wdata = '0; assign m_axi_wstrb = '0; assign m_axi_wlast = 1'b0;
        assign m_axi_wvalid = 1'b0; assign m_axi_bready = 1'b1;
        logic unused_axi;
        assign unused_axi = ^{m_axi_awready, m_axi_wready, m_axi_bresp, m_axi_bvalid, count, ring_log2_q};
    end

    // ---------------- read data (cycle after bus_rd) ----------------
    logic [7:0]       rword;
    assign rword = 8'((32'(bus_rd_addr_q) >> 2) & (STRIDE - 1));

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
                (EP_AW-1)'(EP_REG_KIND):     bus_rdata = {16'b0, DMA, SQUASH, SQUASH, SQUASH, 2'b0, LOSSLESS, BACKPRESSURE, EP_KIND_SINK};   // KIND_DMA, KIND_SQBRK, KIND_SQMASK, KIND_SQUASH, KIND_LOSSLESS, KIND_BACKPRESSURE
                (EP_AW-1)'(EP_REG_CTRL):     bus_rdata = 32'({stall_en_q, 1'b0, enable_q});
                (EP_AW-1)'(EP_REG_STATUS):   bus_rdata = 32'({stall_o, enable_q, overflow, full});
                (EP_AW-1)'(EP_REG_COUNT):    bus_rdata = captured;
                (EP_AW-1)'(EP_REG_DROPPED):  bus_rdata = dropped;
                (EP_AW-1)'(EP_REG_THROTTLE): bus_rdata = 32'(throttle_q);
                (EP_AW-1)'(EP_REG_SQUASH):   bus_rdata = SQUASH ? window_q : 32'd0;
                (EP_AW-1)'(EP_REG_TAKEN):    bus_rdata = taken;
                (EP_AW-1)'(EP_REG_SQMASK_SEL): bus_rdata = 32'(msel_rd);
                (EP_AW-1)'(EP_REG_SQMASK):   bus_rdata = mask_rd;
                (EP_AW-1)'(EP_REG_BRK_SEL):  bus_rdata = bsel_rd;
                (EP_AW-1)'(EP_REG_BRK_DATA): bus_rdata = bdat_rd;
                (EP_AW-1)'(EP_REG_RING_LO):   bus_rdata = ring_lo_q;
                (EP_AW-1)'(EP_REG_RING_HI):   bus_rdata = ring_hi_q;
                (EP_AW-1)'(EP_REG_RING_LOG2): bus_rdata = ring_log2_rd;
                (EP_AW-1)'(EP_REG_RING_HEAD): bus_rdata = ring_head;
                (EP_AW-1)'(EP_REG_RING_TAIL): bus_rdata = ring_tail_q;
                (EP_AW-1)'(EP_REG_DMA_STAT):  bus_rdata = 32'({dma_busy, dma_err});
                default:                     bus_rdata = '0;
            endcase
        end
    end

    logic unused;
    assign unused = ^{bus_wstrb[3:1]};

endmodule : ocv_sink
