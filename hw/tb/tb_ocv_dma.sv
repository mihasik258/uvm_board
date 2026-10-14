/// Self-checking testbench for a DMA sink: ocv_sink with DMA (ocv_dma_wr) empties its FIFO into a
/// ring in "PS memory" - here an AXI4 slave model with random AWREADY/WREADY gaps and late, out-of-
/// step write responses (several bursts outstanding).
///
/// A DUT stand-in on the gated clock offers records rec(k) with random gaps and holds each until it
/// is taken; the sink is lossless, so its clock stops while the FIFO is full. The "PS" programs a
/// small ring (it fills: the writer must wait for the tail) and consumes records from memory as
/// RING_HEAD announces them, at a random pace, checking each record and its zero padding.
///
/// Checks: every AXI burst is INCR, full width, inside the ring and one 256-byte block (so never
/// across 4 KiB); WLAST on the last beat only; all N records arrive in order and intact; the DUT was
/// frozen (FIFO full) and the ring was full at some point; COUNT = HEAD = N, no write error. Then a
/// clear in the middle of a burst (DUT reset) and a second run from record 0 into the same ring:
/// the stale burst completes, its response does not count, the new records are intact. Last, with
/// RING_LOG2 = 0 the endpoint is the plain buffer read over the bus. Ends with "TB_OCV_DMA: PASS".
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */
module tb_ocv_dma #(
    parameter int unsigned W   = 160,   // record width (multiple of 32)
    parameter int unsigned D   = 3,     // log2 FIFO depth
    parameter int unsigned DW  = 128,   // AXI data width
    parameter int unsigned RL  = 4,     // log2 ring records
    parameter int unsigned N   = 600    // records per run
);
    import ocv_pkg::*;

    localparam int unsigned WORDS = W / 32;
    localparam int unsigned LSTR  = $clog2(WORDS);
    localparam int unsigned EP_AW = ((D + LSTR + 2) < 7 ? 7 : (D + LSTR + 2)) + 1;
    localparam int unsigned DWB   = DW / 8;
    localparam int unsigned SLOT_LOG2 = (LSTR + 2) > $clog2(DWB) ? (LSTR + 2) : $clog2(DWB);
    localparam int unsigned SLOT  = 1 << SLOT_LOG2;
    localparam longint unsigned RING_BYTES = longint'(SLOT) << RL;
    localparam longint unsigned BASE = 64'h0000_0008_0000_0000 + (64'h40000 / RING_BYTES + 1) * RING_BYTES;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    int errors = 0;

    function automatic logic [W-1:0] rec(input int run, input int k);
        logic [W-1:0] v;
        for (int w = 0; w < WORDS; w++) v[32*w +: 32] = 32'(k) * 32'h9E3779B1 ^ (32'(w) << 24) ^ (32'(run) << 20);
        return v;
    endfunction

    // ---------------- sink under test ----------------
    logic             bus_wr = 1'b0, bus_rd = 1'b0, clear = 1'b0;
    logic [EP_AW-1:0] bus_waddr = '0, bus_raddr = '0, bus_rd_addr_q = '0;
    logic [31:0]      bus_wdata = '0, bus_rdata;
    logic             rec_valid = 1'b0, rec_ready, stall;
    logic [W-1:0]     rec_data = '0;

    logic [63:0]      awaddr;
    logic [7:0]       awlen;
    logic [2:0]       awsize;
    logic [1:0]       awburst, bresp;
    logic [3:0]       awcache;
    logic             awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    logic [DW-1:0]    wdata;
    logic [DW/8-1:0]  wstrb;

    ocv_sink #(.REC_W(W), .LOG2_DEPTH(D), .LOSSLESS(1'b1), .DMA(1'b1), .DMA_DW(DW)) dut (
        .clk, .rst_n, .rec_valid_i (rec_valid), .rec_ready_o (rec_ready), .rec_data_i (rec_data),
        .dut_ce_i (~stall), .clear_i (clear), .stall_o (stall),
        .bus_wr, .bus_waddr, .bus_wdata, .bus_wstrb (4'hF), .bus_rd, .bus_raddr, .bus_rd_addr_q, .bus_rdata,
        .m_axi_awaddr (awaddr), .m_axi_awlen (awlen), .m_axi_awsize (awsize), .m_axi_awburst (awburst),
        .m_axi_awcache (awcache), .m_axi_awvalid (awvalid), .m_axi_awready (awready),
        .m_axi_wdata (wdata), .m_axi_wstrb (wstrb), .m_axi_wlast (wlast), .m_axi_wvalid (wvalid),
        .m_axi_wready (wready), .m_axi_bresp (bresp), .m_axi_bvalid (bvalid), .m_axi_bready (bready)
    );
    always_ff @(posedge clk) if (bus_rd) bus_rd_addr_q <= bus_raddr;

    task automatic wr(input logic [7:0] a, input logic [31:0] v);
        @(negedge clk); bus_wr = 1'b1; bus_waddr = EP_AW'(a); bus_wdata = v;
        @(negedge clk); bus_wr = 1'b0;
    endtask
    task automatic rd(input logic [EP_AW-1:0] a, output logic [31:0] v);
        @(negedge clk); bus_rd = 1'b1; bus_raddr = a;
        @(negedge clk); bus_rd = 1'b0; v = bus_rdata;
    endtask

    // ---------------- AXI4 slave: memory with random handshakes and late responses ----------------
    logic [7:0] mem [longint unsigned];
    typedef struct { longint unsigned addr; int beats; } aw_t;
    aw_t        aw_q[$];
    logic [DW-1:0] wd_q[$];
    bit         wl_q[$];
    int         b_due[$];               // cycle at which each pending response is offered
    int         cyc = 0, bursts = 0, max_out = 0, out_now = 0;
    int unsigned rdy_pct = 70;          // AWREADY/WREADY probability, %
    always @(posedge clk) cyc++;

    assign awready = rst_n && ($urandom_range(0, 99) < rdy_pct);
    assign wready  = rst_n && ($urandom_range(0, 99) < rdy_pct);
    assign bresp   = 2'b00;
    always @(negedge clk) bvalid = (b_due.size() != 0) && (b_due[0] <= cyc);

    always @(posedge clk) if (rst_n) begin
        if (awvalid && awready) begin
            longint unsigned a = awaddr;
            longint unsigned nb = (longint'(awlen) + 1) * DWB;
            int beats = int'(awlen) + 1;
            aw_t e;
            if (awburst != 2'b01 || awsize != 3'($clog2(DWB))) begin
                $display("FAIL burst type/size %0d/%0d", awburst, awsize); errors++;
            end
            if (a % longint'(DWB) != 0 || a < BASE || a + nb > BASE + RING_BYTES) begin
                $display("FAIL burst at %h, %0d beats: outside the ring %h+%0h", a, beats, BASE, RING_BYTES); errors++;
            end
            if ((a / 256) != ((a + nb - 1) / 256) && nb <= 256) begin
                $display("FAIL burst at %h, %0d beats crosses a 256-byte block", a, beats); errors++;
            end
            if ((a / 4096) != ((a + nb - 1) / 4096)) begin
                $display("FAIL burst at %h crosses 4 KiB", a); errors++;
            end
            e.addr = a; e.beats = beats;
            aw_q.push_back(e);
            bursts++;
        end
        if (wvalid && wready) begin wd_q.push_back(wdata); wl_q.push_back(wlast); end
        // complete bursts whose data is all here
        while (aw_q.size() != 0 && wd_q.size() >= aw_q[0].beats) begin
            for (int b = 0; b < aw_q[0].beats; b++) begin
                logic [DW-1:0] d = wd_q.pop_front();
                bit l = wl_q.pop_front();
                if (l != (b == aw_q[0].beats - 1)) begin $display("FAIL WLAST at beat %0d", b); errors++; end
                for (int i = 0; i < DWB; i++) mem[aw_q[0].addr + longint'(b * DWB + i)] = d[8*i +: 8];
            end
            void'(aw_q.pop_front());
            b_due.push_back(cyc + int'($urandom_range(1, 25)));   // responses come late
            out_now++;
            if (out_now > max_out) max_out = out_now;
        end
        if (bvalid && bready) begin void'(b_due.pop_front()); out_now--; end
    end

    // ---------------- DUT stand-in: records with random gaps, held until taken ----------------
    int  run = 0, sent = 0, n_recs = 0;
    bit  frozen_seen = 1'b0;
    always @(posedge clk) begin
        if (!rst_n || clear) begin
            rec_valid <= 1'b0; sent = 0;
        end else if (!stall) begin
            if (rec_valid) sent++;
            if (sent < n_recs && $urandom_range(0, 3) != 0) begin
                rec_valid <= 1'b1; rec_data <= rec(run, sent);
            end else rec_valid <= 1'b0;
        end else frozen_seen = 1'b1;
    end

    // ---------------- "PS": consume the ring ----------------
    function automatic logic [W-1:0] ring_rec(input int k, output bit pad_ok);
        logic [W-1:0] v;
        longint unsigned a = BASE + longint'(k % (1 << RL)) * SLOT;
        pad_ok = 1'b1;
        for (int i = 0; i < SLOT; i++) begin
            logic [7:0] b = mem.exists(a + i) ? mem[a + i] : 8'hXX;
            if (i < W / 8) v[8*i +: 8] = b;
            else if (b !== 8'h00) pad_ok = 1'b0;
        end
        return v;
    endfunction

    task automatic consume(input int n, input int slow_pct, inout bit ring_full_seen);
        int tail = 0;
        logic [31:0] head, st;
        while (tail < n) begin
            rd(EP_REG_RING_HEAD, head);
            if (int'(head - 32'(tail)) == (1 << RL)) ring_full_seen = 1'b1;
            while (32'(tail) != head) begin
                bit pad_ok;
                logic [W-1:0] got = ring_rec(tail, pad_ok);
                if (got !== rec(run, tail) || !pad_ok) begin
                    if (errors < 10) $display("FAIL run %0d record %0d: %h, expected %h%s", run, tail, got,
                                              rec(run, tail), pad_ok ? "" : " (padding not zero)");
                    errors++;
                end
                tail++;
            end
            if ($urandom_range(0, 99) < slow_pct) repeat ($urandom_range(5, 60)) @(posedge clk);
            wr(EP_REG_RING_TAIL, 32'(tail));
        end
        rd(EP_REG_DMA_STAT, st);
        if (st[DMA_ST_ERROR]) begin $display("FAIL DMA error status"); errors++; end
    endtask

    initial begin
        logic [31:0] v, cnt, head, kind;
        bit ring_full_seen = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        rd(EP_REG_KIND, kind);
        if (!kind[KIND_DMA] || !kind[KIND_LOSSLESS]) begin $display("FAIL KIND %h", kind); errors++; end
        rd(EP_REG_RING_LOG2, v);
        if (v[15:8] != 8'(SLOT_LOG2) || v[23:16] != 8'($clog2(DWB)) || v[4:0] != 0) begin
            $display("FAIL RING_LOG2 reads %h (slot 2^%0d, data 2^%0d)", v, SLOT_LOG2, $clog2(DWB)); errors++;
        end

        // ---- run 0: N records through a small ring, slow consumer ----
        wr(EP_REG_RING_LO, BASE[31:0]);
        wr(EP_REG_RING_HI, BASE[63:32]);
        wr(EP_REG_RING_LOG2, RL);
        n_recs = N;
        do rd(EP_REG_RING_HEAD, head);         // the ring and then the FIFO fill before the PS starts
        while (head != (1 << RL));
        wait (stall);
        consume(N, 40, ring_full_seen);
        rd(EP_REG_COUNT, cnt);
        rd(EP_REG_RING_HEAD, head);
        if (cnt != N || head != N) begin $display("FAIL COUNT %0d HEAD %0d, want %0d", cnt, head, N); errors++; end
        if (!frozen_seen)    begin $display("FAIL the DUT was never frozen (FIFO never full)"); errors++; end
        if (!ring_full_seen) begin $display("FAIL the ring was never full"); errors++; end
        $display("INFO run 0: %0d records, %0d bursts, up to %0d responses outstanding", N, bursts, max_out);

        // ---- run 1: clear (DUT reset) while bursts are in flight, then records from 0 again ----
        run = 1;
        rdy_pct = 30;                          // slow memory: bursts linger
        n_recs = 1 << 30;                      // the DUT keeps producing
        repeat (40) @(posedge clk);
        wait (dut.g_dma.i_dma.to_send_q != 0);
        @(negedge clk); clear = 1'b1; @(negedge clk); clear = 1'b0;
        n_recs = N / 2;
        rdy_pct = 70;
        consume(N / 2, 10, ring_full_seen);
        rd(EP_REG_COUNT, cnt);
        rd(EP_REG_RING_HEAD, head);
        if (cnt != N / 2 || head != N / 2) begin
            $display("FAIL after clear: COUNT %0d HEAD %0d, want %0d", cnt, head, N / 2); errors++;
        end
        repeat (60) @(posedge clk);
        rd(EP_REG_DMA_STAT, v);
        if (v[DMA_ST_BUSY]) begin $display("FAIL still busy at the end"); errors++; end

        // ---- ring off: the plain buffer, read over the bus ----
        run = 2;
        wr(EP_REG_RING_LOG2, 0);
        @(negedge clk); clear = 1'b1; @(negedge clk); clear = 1'b0;
        n_recs = (1 << D) - 1;
        repeat (20 * (1 << D)) @(posedge clk);
        rd(EP_REG_COUNT, cnt);
        if (cnt != (1 << D) - 1) begin $display("FAIL ring off: COUNT %0d", cnt); errors++; end
        for (int k = 0; k < int'(cnt); k++)
            for (int w = 0; w < WORDS; w++) begin
                logic [W-1:0] want = rec(2, k);
                rd(EP_AW'((1 << (EP_AW - 1)) + ((k << LSTR) + w) * 4), v);
                if (v !== want[32*w +: 32]) begin
                    $display("FAIL ring off: record %0d word %0d: %h", k, w, v); errors++;
                end
            end

        if (errors == 0) $display("TB_OCV_DMA: PASS (W=%0d D=%0d DW=%0d ring 2^%0d x %0d B)", W, D, DW, RL, SLOT);
        else $fatal(1, "TB_OCV_DMA: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50ms $fatal(1, "TB_OCV_DMA: FAIL (timeout)");
    end
endmodule
