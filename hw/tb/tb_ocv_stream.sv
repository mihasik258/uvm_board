/// Self-checking testbench for a reactive source: ocv_source with STREAM (ring buffer fed during
/// the run) and, optionally, FREEZE_STARVED (DUT clock stops while it waits for data).
///
/// A request/response test DUT on the gated clock asks for record k (req_o, one cycle), then raises
/// ready and waits; the "PS" process answers each request after a random delay (0..60 cycles),
/// writing f(k) into slot k mod depth and raising LENGTH to k + 1 - so the ring wraps many times.
///
/// Checks: every response arrives, in order, with the right value; nothing is taken while the DUT
/// is frozen; with FREEZE_STARVED the DUT sees the same wait in its own clock cycles whatever the
/// PS delay (the reaction time is hidden), without it the wait grows with the PS delay; KIND flags
/// and the 32-bit COUNT/LENGTH read back. Ends with "TB_OCV_STREAM: PASS" or $fatal.
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off DECLFILENAME */
module tb_ocv_stream #(
    parameter int unsigned W      = 64,   // record width
    parameter int unsigned D      = 3,    // log2 depth (8 records: the ring wraps often)
    parameter bit          FREEZE = 1'b1,
    parameter int unsigned N      = 200   // requests
);
    import ocv_pkg::*;

    localparam int unsigned WORDS  = W / 32;
    localparam int unsigned LSTR   = $clog2(WORDS);
    localparam int unsigned EP_AW  = ((D + LSTR + 2) < 6 ? 6 : (D + LSTR + 2)) + 1;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;
    int errors = 0;

    function automatic logic [W-1:0] answer(input int k);
        logic [W-1:0] v;
        for (int w = 0; w < WORDS; w++) v[32*w +: 32] = 32'(k) * 32'h9E3779B1 ^ 32'(w) ^ 32'hA5000000;
        return v;
    endfunction

    // ---------------- source under test ----------------
    logic             bus_wr = 1'b0, bus_rd = 1'b0;
    logic [EP_AW-1:0] bus_waddr = '0, bus_raddr = '0, bus_rd_addr_q = '0;
    logic [31:0]      bus_wdata = '0, bus_rdata;
    logic             rec_valid, rec_ready, starve, dut_ce, dut_clk;
    logic [W-1:0]     rec_data;

    ocv_source #(.REC_W(W), .LOG2_DEPTH(D), .STREAM(1'b1), .FREEZE_STARVED(FREEZE)) dut_src (
        .clk, .rst_n,
        .rec_valid_o (rec_valid), .rec_ready_i (rec_ready), .rec_data_o (rec_data),
        .dut_ce_i (dut_ce), .clear_i (1'b0), .starve_o (starve),
        .bus_wr, .bus_waddr, .bus_wdata, .bus_wstrb (4'hF),
        .bus_rd, .bus_raddr, .bus_rd_addr_q, .bus_rdata
    );
    assign dut_ce = ~starve;
    ocv_clock_gate i_cg (.clk, .en (dut_ce), .gclk (dut_clk));

    // ---------------- request/response test DUT (gated clock) ----------------
    // IDLE -> REQ (one cycle, asks for record k) -> WAIT (ready, until the response is taken)
    typedef enum logic [1:0] {IDLE, REQ, WAIT} st_e;
    st_e     st_q = IDLE;
    int      k_q = 0, wait_q = 0, gap_q = 0;
    int      dut_waits[$];          // DUT cycles spent in WAIT, per request
    bit      go = 1'b0;             // the DUT starts once the source is enabled (no freeze before)
    logic    req_o;
    assign req_o     = (st_q == REQ);
    assign rec_ready = (st_q == WAIT);
    always_ff @(posedge dut_clk) begin
        if (!rst_n) begin
            st_q <= IDLE; k_q <= 0; wait_q <= 0; gap_q <= 0;
        end else begin
            unique case (st_q)
                IDLE: if (go && k_q < N) begin
                          if (gap_q == 0) st_q <= REQ; else gap_q <= gap_q - 1;
                      end
                REQ:  begin st_q <= WAIT; wait_q <= 0; end
                WAIT: if (rec_valid) begin
                          if (rec_data !== answer(k_q)) begin
                              $display("FAIL response %0d: %h, expected %h", k_q, rec_data, answer(k_q));
                              errors++;
                          end
                          dut_waits.push_back(wait_q + 1);
                          k_q <= k_q + 1; st_q <= IDLE; gap_q <= k_q % 3;
                      end else wait_q <= wait_q + 1;
                default: st_q <= IDLE;
            endcase
        end
    end
    // a record is taken only when the DUT clock ticks
    int pops = 0;
    always @(posedge clk) if (rst_n && rec_valid && rec_ready && dut_ce) pops++;
    always @(posedge clk) if (rst_n && starve && !rec_ready) begin
        $display("FAIL starve without the DUT waiting"); errors++;
    end

    // ---------------- "PS": answers each request after a random delay ----------------
    task automatic bus_write(input logic [EP_AW-1:0] a, input logic [31:0] d);
        @(posedge clk); bus_wr <= 1'b1; bus_waddr <= a; bus_wdata <= d;
        @(posedge clk); bus_wr <= 1'b0;
    endtask
    task automatic bus_read(input logic [EP_AW-1:0] a, output logic [31:0] d);
        @(posedge clk); bus_rd <= 1'b1; bus_raddr <= a;
        @(posedge clk); bus_rd <= 1'b0; bus_rd_addr_q <= a;
        @(negedge clk); d = bus_rdata;
    endtask
    function automatic logic [EP_AW-1:0] buf_addr(input int k, input int w);
        return EP_AW'((1 << (EP_AW - 1)) | ((k % (1 << D)) << (2 + LSTR)) | (w << 2));
    endfunction

    int ps_delay[$];                // clk cycles the PS took for each answer
    int seen = 0;                   // requests seen by the PS (edges of req_o on the DUT clock)
    always @(posedge dut_clk) if (rst_n && req_o) seen++;

    initial begin
        logic [31:0] v;
        logic [W-1:0] ans;
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        bus_read(EP_AW'(EP_REG_KIND), v);
        if (v !== (32'(EP_KIND_SOURCE) | (32'd1 << KIND_STREAM) | (32'(FREEZE) << KIND_FREEZE_STARVED))) begin
            $display("FAIL KIND %h", v); errors++;
        end
        bus_write(EP_AW'(EP_REG_CTRL), 32'(1 << CTRL_ENABLE));
        go = 1'b1;
        for (int k = 0; k < int'(N); k++) begin
            int d = ($urandom % 4 == 0) ? 0 : int'($urandom % 61);
            while (seen <= k) @(posedge clk);          // wait for request k
            repeat (d) @(posedge clk);                 // the PS "thinks"
            ps_delay.push_back(d);
            ans = answer(k);                           // (no bit-select on a function call)
            for (int w = 0; w < int'(WORDS); w++) bus_write(buf_addr(k, w), ans[32*w +: 32]);
            bus_write(EP_AW'(EP_REG_LENGTH), 32'(k + 1));
        end
        while (k_q < int'(N)) @(posedge clk);
        repeat (5) @(posedge clk);
        bus_read(EP_AW'(EP_REG_COUNT), v);
        if (v != 32'(N)) begin $display("FAIL COUNT %0d, expected %0d", v, N); errors++; end
        bus_read(EP_AW'(EP_REG_LENGTH), v);
        if (v != 32'(N)) begin $display("FAIL LENGTH %0d, expected %0d (no cap in STREAM)", v, N); errors++; end
        if (pops != int'(N)) begin $display("FAIL %0d records taken, expected %0d", pops, N); errors++; end

        // the reaction time as the DUT sees it
        begin
            int mn = 1 << 30, mx = 0, slow = 0;
            foreach (dut_waits[i]) begin
                if (dut_waits[i] < mn) mn = dut_waits[i];
                if (dut_waits[i] > mx) mx = dut_waits[i];
                if (ps_delay[i] > 20) slow++;
            end
            foreach (dut_waits[i]) if (i < 40 && $test$plusargs("dbg")) $display("DBG k=%0d wait=%0d ps=%0d", i, dut_waits[i], ps_delay[i]);
            $display("INFO FREEZE=%0d: DUT waited %0d..%0d of its cycles per response (%0d PS answers took > 20 cycles)",
                     FREEZE, mn, mx, slow);
            if (FREEZE && mx != mn) begin
                $display("FAIL with FREEZE_STARVED the DUT must not see the PS delay (%0d..%0d)", mn, mx); errors++;
            end
            if (!FREEZE && mx < 20) begin
                $display("FAIL without FREEZE_STARVED the DUT should see the PS delay (max %0d)", mx); errors++;
            end
        end
        if (errors == 0) $display("TB_OCV_STREAM: PASS (W=%0d D=%0d FREEZE=%0d N=%0d)", W, D, FREEZE, N);
        else $fatal(1, "TB_OCV_STREAM: FAIL, %0d errors", errors);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "TB_OCV_STREAM: TIMEOUT (k=%0d, seen=%0d)", k_q, seen);
    end
endmodule : tb_ocv_stream
