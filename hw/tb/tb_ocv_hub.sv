/// Self-checking testbench for the OCV core: ocv_hub + three endpoints, driven only through
/// the hub's AXI4-Lite slave (as the PS would), with varied AW/W ordering and ready back-pressure.
///
///   ep0: sink, monitor mode      <- records pushed by the testbench
///   ep1: source ---> tb_xform_dut (2-entry elastic pipeline, random stalls) ---> ep2: sink,
///                                                                        backpressure mode
///
/// Checks: hub directory, DUT reset control and cycle counter; endpoint identity/kind/geometry;
/// monitor capture (layout, fill, overflow, drop count, stall, clear, enable, clear by DUT
/// reset); stimulus load with byte strobes and read-back; playback through the DUT into the
/// terminator in order and loss-free under back-pressure; PS reads during playback; rewind and
/// replay; streaming throughput. Ends with "TB_OCV_HUB: PASS" or $fatal.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off DECLFILENAME */
module tb_ocv_hub #(
    parameter int unsigned W0 = 96,   // monitor sink record width
    parameter int unsigned D0 = 4,    // monitor sink log2 depth
    parameter int unsigned W1 = 64,   // stimulus / response record width
    parameter int unsigned D1 = 4     // source and terminator log2 depth
);
    import ocv_pkg::*;

    function automatic int unsigned ep_aw(input int unsigned rec_w, input int unsigned log2_depth);
        int unsigned b = log2_depth + $clog2(rec_w / 32) + 2;
        return ((b < 6) ? 6 : b) + 1;
    endfunction
    localparam int unsigned AW0 = ep_aw(W0, D0);
    localparam int unsigned AW1 = ep_aw(W1, D1);
    localparam int unsigned SLOT_AW = (AW0 > AW1) ? AW0 : AW1;
    localparam int unsigned N_EP    = 3;
    localparam int unsigned ADDR_W  = SLOT_AW + $clog2(N_EP + 1);
    localparam logic [31:0] DUT_ID  = 32'hC0FF_EE01;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    int errors = 0;

    // ---------------- DUT side ----------------
    logic          dut_rst;
    logic          mon_valid = 1'b0;
    logic [W0-1:0] mon_data  = '0;
    logic          mon_stall, mon_ready_unused;
    logic          src_valid, src_ready, rsp_valid, rsp_ready;
    logic [W1-1:0] src_data, rsp_data;
    logic          term_stall;
    bit            dut_random_stall = 1'b0;
    // DUT clock enable: the test DUT runs on a gated clock; endpoints count transfers only when
    // it ticks. random_ce freezes it on random cycles.
    bit            random_ce = 1'b0;
    logic          dut_ce = 1'b1, mon_ce = 1'b1, dut_clk;
    always @(negedge clk) dut_ce = !random_ce || ($urandom % 3 != 0);
    ocv_clock_gate i_dut_cg (.clk, .en (dut_ce), .gclk (dut_clk));

    // ---------------- AXI master signals ----------------
    logic [ADDR_W-1:0] awaddr = '0, araddr = '0;
    logic        awvalid = 0, awready, wvalid = 0, wready, bvalid, bready = 0;
    logic        arvalid = 0, arready, rvalid, rready = 0;
    logic [31:0] wdata = '0, rdata;
    logic [3:0]  wstrb = '0;
    logic [1:0]  bresp, rresp;

    // ---------------- hub + endpoints ----------------
    logic [N_EP-1:0]        ep_wr, ep_rd;
    logic [SLOT_AW-1:0]     ep_waddr, ep_raddr, ep_rd_addr_q;
    logic [31:0]            ep_wdata;
    logic [3:0]             ep_wstrb;
    logic [N_EP-1:0][31:0]  ep_rdata;

    ocv_hub #(.N_EP(N_EP), .SLOT_AW(SLOT_AW), .DUT_ID(DUT_ID)) hub (
        .clk, .rst_n,
        .s_axi_awaddr (awaddr), .s_axi_awprot (3'b0), .s_axi_awvalid (awvalid), .s_axi_awready (awready),
        .s_axi_wdata  (wdata),  .s_axi_wstrb  (wstrb), .s_axi_wvalid  (wvalid),  .s_axi_wready  (wready),
        .s_axi_bresp  (bresp),  .s_axi_bvalid (bvalid), .s_axi_bready (bready),
        .s_axi_araddr (araddr), .s_axi_arprot (3'b0), .s_axi_arvalid (arvalid), .s_axi_arready (arready),
        .s_axi_rdata  (rdata),  .s_axi_rresp  (rresp), .s_axi_rvalid  (rvalid),  .s_axi_rready  (rready),
        .ep_wr, .ep_waddr, .ep_wdata, .ep_wstrb, .ep_rd, .ep_raddr, .ep_rd_addr_q, .ep_rdata,
        .dut_rst_o (dut_rst)
    );

    ocv_sink #(.REC_W(W0), .LOG2_DEPTH(D0)) ep0 (
        .clk, .rst_n,
        .rec_valid_i (mon_valid), .rec_ready_o (mon_ready_unused), .rec_data_i (mon_data),
        .dut_ce_i (mon_ce), .clear_i (dut_rst), .stall_o (mon_stall),
        .bus_wr (ep_wr[0]), .bus_waddr (AW0'(ep_waddr)), .bus_wdata (ep_wdata), .bus_wstrb (ep_wstrb),
        .bus_rd (ep_rd[0]), .bus_raddr (AW0'(ep_raddr)), .bus_rd_addr_q (AW0'(ep_rd_addr_q)),
        .bus_rdata (ep_rdata[0])
    );

    ocv_source #(.REC_W(W1), .LOG2_DEPTH(D1)) ep1 (
        .clk, .rst_n,
        .rec_valid_o (src_valid), .rec_ready_i (src_ready), .rec_data_o (src_data),
        .dut_ce_i (dut_ce), .clear_i (dut_rst),
        .bus_wr (ep_wr[1]), .bus_waddr (AW1'(ep_waddr)), .bus_wdata (ep_wdata), .bus_wstrb (ep_wstrb),
        .bus_rd (ep_rd[1]), .bus_raddr (AW1'(ep_raddr)), .bus_rd_addr_q (AW1'(ep_rd_addr_q)),
        .bus_rdata (ep_rdata[1])
    );

    tb_xform_dut #(.W(W1)) dut (
        .clk (dut_clk), .rst (~rst_n | dut_rst), .random_stall (dut_random_stall),
        .in_valid (src_valid), .in_ready (src_ready), .in_data (src_data),
        .out_valid (rsp_valid), .out_ready (rsp_ready), .out_data (rsp_data)
    );

    ocv_sink #(.REC_W(W1), .LOG2_DEPTH(D1), .BACKPRESSURE(1'b1)) ep2 (
        .clk, .rst_n,
        .rec_valid_i (rsp_valid), .rec_ready_o (rsp_ready), .rec_data_i (rsp_data),
        .dut_ce_i (dut_ce), .clear_i (dut_rst), .stall_o (term_stall),
        .bus_wr (ep_wr[2]), .bus_waddr (AW1'(ep_waddr)), .bus_wdata (ep_wdata), .bus_wstrb (ep_wstrb),
        .bus_rd (ep_rd[2]), .bus_raddr (AW1'(ep_raddr)), .bus_rd_addr_q (AW1'(ep_rd_addr_q)),
        .bus_rdata (ep_rdata[2])
    );

    // AXI-Stream rule on the source output: once valid, hold valid and data until ready.
    logic          prev_hold = 1'b0;
    logic [W1-1:0] prev_data;
    always @(posedge clk) begin
        if (prev_hold && !dut_rst && !(src_valid && src_data == prev_data)) begin
            $display("FAIL source dropped or changed a pending record"); errors++;
        end
        prev_hold <= src_valid & ~(src_ready & dut_ce) & ~dut_rst;
        prev_data <= src_data;
    end

    // ---------------- checking helpers ----------------
    task automatic check(input string what, input logic [31:0] got, input logic [31:0] exp);
        if (got !== exp) begin
            $display("FAIL %s: got %08h exp %08h", what, got, exp);
            errors++;
        end
    endtask

    function automatic logic [ADDR_W-1:0] a(input int slot, input logic [31:0] off);
        return ADDR_W'((slot << SLOT_AW) | off);
    endfunction

    // ---------------- AXI4-Lite master ----------------
    // order: 0 = AW and W together, 1 = AW first, 2 = W first. bdly = cycles before BREADY.
    task automatic axi_write(input logic [ADDR_W-1:0] addr, input logic [31:0] d,
                             input int order = 0, input int bdly = 0, input logic [3:0] strb = 4'hF);
        @(negedge clk);
        if (order != 2) begin awaddr = addr; awvalid = 1; end
        if (order != 1) begin wdata = d; wstrb = strb; wvalid = 1; end
        if (order != 0) begin
            repeat (2) begin
                @(negedge clk);
                if (awready || wready) begin $display("FAIL write accepted half-way"); errors++; end
            end
            if (order == 1) begin wdata = d; wstrb = strb; wvalid = 1; end
            else            begin awaddr = addr; awvalid = 1; end
        end
        do @(posedge clk); while (!(awready && wready));
        @(negedge clk); awvalid = 0; wvalid = 0;
        repeat (bdly) @(negedge clk);
        bready = 1;
        do @(posedge clk); while (!bvalid);
        check("bresp", 32'(bresp), 0);
        @(negedge clk); bready = 0;
    endtask

    task automatic axi_read(input logic [ADDR_W-1:0] addr, output logic [31:0] d, input int rdly = 0);
        @(negedge clk); araddr = addr; arvalid = 1;
        do @(posedge clk); while (!arready);
        @(negedge clk); arvalid = 0;
        repeat (rdly) @(negedge clk);
        rready = 1;
        do @(posedge clk); while (!rvalid);
        d = rdata;
        check("rresp", 32'(rresp), 0);
        @(negedge clk); rready = 0;
    endtask

    task automatic rd(input int slot, input logic [31:0] off, output logic [31:0] d, input int rdly = 0);
        axi_read(a(slot, off), d, rdly);
    endtask
    task automatic wr(input int slot, input logic [31:0] off, input logic [31:0] d,
                      input int order = 0, input logic [3:0] strb = 4'hF);
        axi_write(a(slot, off), d, order, 0, strb);
    endtask

    // Software view of an endpoint, derived from its GEOMETRY register only.
    typedef struct { int words; int depth; int stride_log2; int buf_off; } geom_t;
    task automatic geometry(input int slot, output geom_t g);
        logic [31:0] v;
        rd(slot, EP_REG_GEOMETRY, v);
        g.words = v[7:0]; g.depth = 1 << v[15:8]; g.stride_log2 = v[23:16]; g.buf_off = 1 << v[31:24];
    endtask
    function automatic logic [31:0] word_off(input geom_t g, input int i, input int j);
        return 32'(g.buf_off + (((i << g.stride_log2) + j) * 4));
    endfunction

    // ---------------- record patterns ----------------
    function automatic logic [31:0] mon_pat(input logic [15:0] i, input logic [7:0] j);
        return {i, j, 8'h5A};
    endfunction
    function automatic logic [31:0] stim(input int i, input int j);
        return 32'(i * 32'h0101_0101 + j * 32'h1000_0000 + 32'h0000_7000);
    endfunction
    function automatic logic [31:0] xform(input logic [31:0] x, input int j);
        return (j == 0) ? ~x : x + 32'd1;
    endfunction

    task automatic mon_push(input int i, input int gap = 0);
        @(negedge clk);
        for (int j = 0; j < W0 / 32; j++) mon_data[32*j +: 32] = mon_pat(16'(i), 8'(j));
        mon_valid = 1;
        @(negedge clk); mon_valid = 0;
        repeat (gap) @(negedge clk);
    endtask

    task automatic sink_status(input string tag, input int slot, input int cnt, input bit f,
                               input bit ovf, input bit en, input bit stl, input int drp);
        logic [31:0] v;
        rd(slot, EP_REG_COUNT, v);   check({tag, " COUNT"}, v, 32'(cnt));
        rd(slot, EP_REG_STATUS, v);  check({tag, " STATUS"}, v, {28'b0, stl, en, ovf, f});
        rd(slot, EP_REG_DROPPED, v); check({tag, " DROPPED"}, v, 32'(drp));
    endtask

    task automatic wait_source_done(input int max_polls = 2000);
        logic [31:0] v;
        for (int k = 0; k < max_polls; k++) begin
            rd(2, EP_REG_STATUS, v);
            if (v[0]) return;
        end
        $display("FAIL source never reported done"); errors++;
    endtask

    // Load stimulus records [0, n) into the source (slot 2), alternating AW/W orderings.
    task automatic load_stimulus(input geom_t g, input int n);
        for (int i = 0; i < n; i++)
            for (int j = 0; j < g.words; j++)
                wr(2, word_off(g, i, j), stim(i, j), (i + j) % 3);
    endtask

    // Terminator (slot 3) must hold exactly n transformed records, in order.
    task automatic check_responses(input string tag, input geom_t g, input int n);
        logic [31:0] v;
        rd(3, EP_REG_COUNT, v);   check({tag, " response COUNT"}, v, 32'(n));
        rd(3, EP_REG_DROPPED, v); check({tag, " response DROPPED"}, v, 0);
        for (int i = 0; i < n; i++)
            for (int j = 0; j < g.words; j++) begin
                rd(3, word_off(g, i, j), v, (i + j) % 2);
                check($sformatf("%s rsp %0d.%0d", tag, i, j), v, xform(stim(i, j), j));
            end
    endtask

    initial begin
        logic [31:0] v, lo, hi, exp0;
        geom_t g0, gs, gt;
        int n;
        longint t0, t1;

        repeat (4) @(negedge clk);
        rst_n = 1;

        // 1. hub directory
        $display("SECTION hub directory @%0t", $time);
        rd(0, HUB_REG_ID, v);       check("HUB_ID", v, HUB_ID);
        rd(0, HUB_REG_VERSION, v);  check("HUB_VERSION", v, HUB_VERSION);
        rd(0, HUB_REG_LAYOUT, v);   check("LAYOUT", v, {16'b0, 8'(SLOT_AW), 8'(N_EP)});
        rd(0, HUB_REG_DUT_ID, v);   check("DUT_ID", v, DUT_ID);
        rd(0, HUB_REG_DUT_CTRL, v); check("DUT_CTRL reset value", v, 0);
        rd(0, 32'h40, v);           check("unmapped hub CSR", v, 0);

        // 2. endpoint identity, kind, geometry
        $display("SECTION endpoint identity @%0t", $time);
        for (int s = 1; s <= 3; s++) begin
            rd(s, EP_REG_ID, v);      check($sformatf("slot %0d EP_ID", s), v, EP_ID);
            rd(s, EP_REG_VERSION, v); check($sformatf("slot %0d EP_VERSION", s), v, EP_VERSION);
        end
        rd(1, EP_REG_KIND, v); check("slot 1 KIND", v, 32'(EP_KIND_SINK));
        rd(2, EP_REG_KIND, v); check("slot 2 KIND", v, 32'(EP_KIND_SOURCE));
        rd(3, EP_REG_KIND, v); check("slot 3 KIND", v, 32'h100 | 32'(EP_KIND_SINK));
        geometry(1, g0); geometry(2, gs); geometry(3, gt);
        check("g0 words", 32'(g0.words), W0 / 32); check("g0 depth", 32'(g0.depth), 1 << D0);
        check("g0 buf", 32'(g0.buf_off), 1 << (AW0 - 1));
        check("gs words", 32'(gs.words), W1 / 32); check("gs depth", 32'(gs.depth), 1 << D1);
        check("gt buf", 32'(gt.buf_off), 1 << (AW1 - 1));

        // ============ monitor sink (slot 1) ============
        $display("SECTION monitor sink @%0t", $time);
        sink_status("mon reset", 1, 0, 0, 0, 1, 0, 0);
        n = g0.depth - 3;
        for (int i = 0; i < n; i++) mon_push(i, i % 3);
        sink_status("mon partial", 1, n, 0, 0, 1, 0, 0);
        for (int i = 0; i < n; i++)
            for (int j = 0; j < (1 << g0.stride_log2); j++) begin
                rd(1, word_off(g0, i, j), v, (i + j) % 3);
                check($sformatf("mon rec %0d.%0d", i, j), v, (j < g0.words) ? mon_pat(16'(i), 8'(j)) : 32'h0);
            end
        for (int i = n; i < n + 5; i++) mon_push(i);
        sink_status("mon full", 1, g0.depth, 1, 1, 1, 0, 2);
        rd(1, word_off(g0, g0.depth - 1, 0), v);
        check("mon last record", v, mon_pat(16'(g0.depth - 1), 8'd0));
        axi_write(a(1, EP_REG_CTRL), 32'h5, 1, 2);        // enable | stall_en, AW first
        rd(1, EP_REG_CTRL, v); check("mon CTRL", v, 32'h5);
        sink_status("mon stall", 1, g0.depth, 1, 1, 1, 1, 2);
        check("mon stall_o", 32'(mon_stall), 1);
        axi_write(a(1, EP_REG_CTRL), 32'h7, 2, 1);        // + clear, W first
        rd(1, EP_REG_CTRL, v); check("mon CTRL after clear", v, 32'h5);
        sink_status("mon cleared", 1, 0, 0, 0, 1, 0, 0);
        wr(1, EP_REG_CTRL, 32'h0);
        for (int i = 0; i < 4; i++) mon_push(100 + i);
        sink_status("mon disabled", 1, 0, 0, 0, 0, 0, 0);
        wr(1, EP_REG_CTRL, 32'h1);
        mon_push(200); mon_push(201);
        sink_status("mon pre DUT reset", 1, 2, 0, 0, 1, 0, 0);
        wr(0, HUB_REG_DUT_CTRL, 32'h1); wr(0, HUB_REG_DUT_CTRL, 32'h0);   // DUT reset pulse
        sink_status("mon post DUT reset", 1, 0, 0, 0, 1, 0, 0);
        mon_push(300);
        rd(1, word_off(g0, 0, 0), v); check("mon slot 0 after DUT reset", v, mon_pat(16'd300, 8'd0));
        mon_ce = 1'b0; mon_push(301); mon_push(302); mon_ce = 1'b1;     // DUT frozen: nothing counts
        sink_status("mon frozen DUT", 1, 1, 0, 0, 1, 0, 0);
        wr(1, word_off(g0, 0, 0), 32'hDEADBEEF);
        rd(1, word_off(g0, 0, 0), v); check("sink buffer is read-only", v, mon_pat(16'd300, 8'd0));
        wr(1, EP_REG_COUNT, 32'h1234);
        rd(1, EP_REG_COUNT, v); check("sink COUNT is read-only", v, 1);

        // ============ source -> DUT -> terminator ============
        $display("SECTION stimulus load @%0t", $time);
        n = (gs.depth > 4) ? gs.depth - 4 : gs.depth;   // leave room to test LENGTH < depth
        load_stimulus(gs, n);
        for (int i = 0; i < n; i++)
            for (int j = 0; j < gs.words; j++) begin
                rd(2, word_off(gs, i, j), v);
                check($sformatf("stim readback %0d.%0d", i, j), v, stim(i, j));
            end
        // byte strobes: rewrite only the low half of word 0 of record 0, then restore it
        wr(2, word_off(gs, 0, 0), 32'hFFFF_ABCD, 0, 4'b0011);
        exp0 = stim(0, 0);
        rd(2, word_off(gs, 0, 0), v); check("strobed write", v, {exp0[31:16], 16'hABCD});
        wr(2, word_off(gs, 0, 0), stim(0, 0));
        rd(2, EP_REG_STATUS, v); check("source idle STATUS", v, 32'h1);    // done: sent==length==0

        // run 1: random DUT stalls, terminator enabled from reset
        $display("SECTION run1 @%0t", $time);
        dut_random_stall = 1'b1;
        wr(2, EP_REG_LENGTH, 32'(n));
        rd(2, EP_REG_LENGTH, v); check("LENGTH", v, 32'(n));
        wr(2, EP_REG_CTRL, 32'h1);
        wait_source_done();
        rd(2, EP_REG_COUNT, v); check("source sent", v, 32'(n));
        repeat (10) @(negedge clk);                                        // drain the DUT
        check_responses("run1", gt, n);

        // run 2: terminator disabled first -> source must back up, nothing lost
        $display("SECTION run2 @%0t", $time);
        wr(3, EP_REG_CTRL, 32'h2);                                         // clear + disable
        wr(2, EP_REG_CTRL, 32'h3);                                         // rewind + enable
        repeat (40) @(negedge clk);
        rd(2, EP_REG_COUNT, v);
        if (v > 3) begin $display("FAIL source sent %0d records into a stalled DUT", v); errors++; end
        rd(3, EP_REG_COUNT, v); check("terminator held", v, 0);
        wr(3, EP_REG_CTRL, 32'h1);                                         // enable terminator
        wait_source_done();
        repeat (10) @(negedge clk);
        check_responses("run2", gt, n);

        // run 3: PS reads the source buffer while it plays
        $display("SECTION run3 @%0t", $time);
        wr(3, EP_REG_CTRL, 32'h3);
        wr(2, EP_REG_CTRL, 32'h3);
        for (int k = 0; k < 6 && k < n; k++) begin
            rd(2, word_off(gs, k, 0), v); check($sformatf("stim read during play %0d", k), v, stim(k, 0));
        end
        wait_source_done();
        repeat (10) @(negedge clk);
        check_responses("run3", gt, n);

        // run 4: throughput - no DUT stalls, full buffer; count cycles from enable to done
        $display("SECTION run4 @%0t", $time);
        dut_random_stall = 1'b0;
        wr(2, EP_REG_CTRL, 32'h0);                                         // stop before reloading
        load_stimulus(gs, gs.depth);
        wr(2, EP_REG_LENGTH, 32'(gs.depth));
        wr(3, EP_REG_CTRL, 32'h3);
        wr(2, EP_REG_CTRL, 32'h2);                                         // rewind, stay disabled
        @(negedge clk); t0 = $time;
        wr(2, EP_REG_CTRL, 32'h1);
        for (int k = 0; k < 1000 && ep1.sent_q != (D1 + 1)'(gs.depth); k++) @(negedge clk);
        t1 = $time;
        repeat (10) @(negedge clk);
        check_responses("run4", gt, gs.depth);
        if ((t1 - t0) / 10 > gs.depth + 12) begin
            $display("FAIL throughput: %0d records took %0d cycles", gs.depth, (t1 - t0) / 10); errors++;
        end else
            $display("INFO throughput: %0d records in %0d cycles", gs.depth, (t1 - t0) / 10);

        // run 5: throttled source and terminator (random bubbles and ready gaps), random DUT stalls
        $display("SECTION run5 throttle @%0t", $time);
        dut_random_stall = 1'b1;
        wr(2, EP_REG_THROTTLE, 32'd128);
        wr(3, EP_REG_THROTTLE, 32'd96);
        rd(2, EP_REG_THROTTLE, v); check("source THROTTLE", v, 128);
        rd(3, EP_REG_THROTTLE, v); check("sink THROTTLE", v, 96);
        wr(3, EP_REG_CTRL, 32'h3);
        wr(2, EP_REG_CTRL, 32'h3);
        wait_source_done();
        repeat (20) @(negedge clk);
        check_responses("run5", gt, gs.depth);
        wr(2, EP_REG_THROTTLE, 32'd0);
        wr(3, EP_REG_THROTTLE, 32'd0);

        // run 6: the DUT clock is gated on random cycles, with throttles and DUT stalls on top
        $display("SECTION run6 gated DUT clock @%0t", $time);
        random_ce = 1'b1;
        wr(2, EP_REG_THROTTLE, 32'd64);
        wr(3, EP_REG_THROTTLE, 32'd64);
        wr(3, EP_REG_CTRL, 32'h3);
        wr(2, EP_REG_CTRL, 32'h3);
        wait_source_done();
        repeat (40) @(negedge clk);
        check_responses("run6", gt, gs.depth);
        random_ce = 1'b0;
        wr(2, EP_REG_THROTTLE, 32'd0);
        wr(3, EP_REG_THROTTLE, 32'd0);

        // ============ DUT reset and cycle counter ============
        $display("SECTION dut reset @%0t", $time);
        wr(0, HUB_REG_DUT_CTRL, 32'h1);
        rd(0, HUB_REG_DUT_CTRL, v); check("DUT_CTRL set", v, 1);
        rd(0, HUB_REG_CYCLES_LO, lo); rd(0, HUB_REG_CYCLES_HI, hi);
        check("CYCLES in reset", lo | hi, 0);
        rd(2, EP_REG_COUNT, v); check("source rewound by DUT reset", v, 0);
        rd(3, EP_REG_COUNT, v); check("terminator cleared by DUT reset", v, 0);
        wr(0, HUB_REG_DUT_CTRL, 32'h0);
        repeat (50) @(negedge clk);
        rd(0, HUB_REG_CYCLES_LO, lo); rd(0, HUB_REG_CYCLES_HI, hi);
        if (hi != 0 || lo < 50 || lo > 80) begin
            $display("FAIL CYCLES after 50 cycles: hi=%0d lo=%0d", hi, lo); errors++;
        end

        if (errors == 0) $display("TB_OCV_HUB: PASS (W0=%0d D0=%0d W1=%0d D1=%0d)", W0, D0, W1, D1);
        else $fatal(1, "TB_OCV_HUB: FAIL, %0d errors (W0=%0d D0=%0d W1=%0d D1=%0d)", errors, W0, D0, W1, D1);
        $finish;
    end

    initial begin
        #20ms $fatal(1, "TB_OCV_HUB: TIMEOUT");
    end
endmodule

/// Test DUT: a 2-entry elastic pipeline that transforms each record (word 0 inverted, other
/// words +1), with optional random input stalls to create back-pressure on the source.
module tb_xform_dut #(parameter int unsigned W = 64) (
    input  logic         clk,
    input  logic         rst,
    input  bit           random_stall,
    input  logic         in_valid,
    output logic         in_ready,
    input  logic [W-1:0] in_data,
    output logic         out_valid,
    input  logic         out_ready,
    output logic [W-1:0] out_data
);
    logic [W-1:0] q [2];
    logic         rp, wp;
    logic [1:0]   cnt;
    logic         stall;
    logic [W-1:0] x;

    always_comb begin
        for (int j = 0; j < W / 32; j++)
            x[32*j +: 32] = (j == 0) ? ~in_data[31:0] : in_data[32*j +: 32] + 32'd1;
    end

    always @(negedge clk) stall = random_stall && ($urandom % 3 == 0);
    assign in_ready  = (cnt < 2) && !stall;
    assign out_valid = (cnt != 0);
    assign out_data  = q[rp];

    always_ff @(posedge clk) begin
        if (rst) begin
            rp <= 0; wp <= 0; cnt <= 0;
        end else begin
            if (in_valid && in_ready) begin q[wp] <= x; wp <= ~wp; end
            if (out_valid && out_ready) rp <= ~rp;
            cnt <= cnt + 2'(in_valid && in_ready) - 2'(out_valid && out_ready);
        end
    end
endmodule
