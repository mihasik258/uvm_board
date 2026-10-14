// tb_ocv_squash.sv - ocv_sink with SQUASH: fused records against a reference computed here.
//
// A DUT stand-in offers random records with random gaps and holds each one until it is taken; its
// clock stops while the lossless buffer is full (dut_ce = ~stall), as the generated wrapper does.
// A "PS" process drains the buffer whenever it fills, then at the end flushes the open window. Every
// fused record {crc32, crc32c, count, last record} is compared with the reference (same CRCs over
// the masked words). Windows 1, 7 and 64; a small buffer so it fills and freezes the DUT many times;
// a mask that leaves some bits out (they change randomly and must not affect the signatures); then
// masks set at run time (EP_REG_SQMASK_SEL/SQMASK), read back, leaving more bits out; then a break
// pattern (EP_REG_BRK_*): every matching record closes its window.
`timescale 1ns/1ps
module tb_ocv_squash #(parameter int W = 96, parameter int D = 3);
    import ocv_pkg::*;
    localparam int REC_W = W + 96;
    localparam logic [W-1:0] MASK = {{(W-8){1'b1}}, 8'h0F};   // bits [7:4] are not compared
    localparam int EP_AW = ((D + $clog2(REC_W / 32) + 2) < 6 ? 6 : (D + $clog2(REC_W / 32) + 2)) + 1;
    localparam int STRIDE = 1 << $clog2(REC_W / 32);

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic             rec_valid, rec_ready, stall;
    logic [W-1:0]     rec_data;
    logic             bus_wr = 0, bus_rd = 0;
    logic [EP_AW-1:0] bus_waddr, bus_raddr, bus_rd_addr_q;
    logic [31:0]      bus_wdata, bus_rdata;
    logic [3:0]       bus_wstrb = 4'hF;

    ocv_sink #(.REC_W(REC_W), .LOG2_DEPTH(D), .LOSSLESS(1'b1), .SQUASH(1'b1), .IN_W(W), .MASK(MASK)) dut (
        .clk, .rst_n, .rec_valid_i(rec_valid), .rec_ready_o(rec_ready), .rec_data_i(rec_data),
        .dut_ce_i(~stall), .clear_i(1'b0), .stall_o(stall),
        .bus_wr, .bus_waddr, .bus_wdata, .bus_wstrb, .bus_rd, .bus_raddr, .bus_rd_addr_q, .bus_rdata);

    always_ff @(posedge clk) if (bus_rd) bus_rd_addr_q <= bus_raddr;

    task automatic wr(input logic [7:0] reg_a, input logic [31:0] v);
        @(negedge clk); bus_wr = 1; bus_waddr = EP_AW'(reg_a); bus_wdata = v;
        @(negedge clk); bus_wr = 0;
    endtask
    task automatic rd(input logic [EP_AW-1:0] a, output logic [31:0] v);
        @(negedge clk); bus_rd = 1; bus_raddr = a;
        @(negedge clk); bus_rd = 0; v = bus_rdata;
    endtask

    function automatic logic [31:0] crc_rec(input logic [31:0] crc, input logic [W-1:0] rec, input logic [31:0] poly);
        for (int w = 0; w < W / 32; w++)
            for (int b = 0; b < 32; b++) crc = (crc >> 1) ^ (poly & {32{crc[0] ^ rec[32*w + b]}});
        return crc;
    endfunction

    // ---- DUT stand-in: N records, random gaps, held until taken ----
    logic [W-1:0] recs[$];
    logic [W-1:0] cur_mask = MASK;                         // what the signatures cover now
    int unsigned  n_recs, sent;
    bit           dut_done;
    always @(posedge clk) begin
        if (!rst_n) begin rec_valid <= 0; sent = 0; end
        else if (!stall) begin                              // the DUT's clock ticks
            if (rec_valid) sent++;                          // the record shown this cycle was taken
            if (sent < n_recs && $urandom_range(0, 3) != 0) begin
                rec_valid <= 1; rec_data <= recs[sent] ^ ({(W/32){$urandom}} & ~cur_mask);   // noise in ignored bits
            end else rec_valid <= 0;
        end
        dut_done = (sent == n_recs);
    end

    // ---- PS: drain on full, flush at the end; collect fused records ----
    logic [REC_W-1:0] got[$];
    task automatic drain();
        logic [31:0] cnt, v;
        rd(EP_AW'(EP_REG_COUNT), cnt);
        for (int i = 0; i < int'(cnt); i++) begin
            logic [REC_W-1:0] r;
            for (int j = 0; j < REC_W / 32; j++) begin
                rd(EP_AW'((1 << (EP_AW - 1)) + ((i * STRIDE + j) * 4)), v);
                r[32*j +: 32] = v;
            end
            got.push_back(r);
        end
        wr(EP_REG_CTRL, 32'(1 << CTRL_ENABLE) | 32'(1 << CTRL_CLEAR));
    endtask

    int errors = 0;
    task automatic run(input int unsigned window, input int unsigned n, input logic [W-1:0] m = MASK,
                       input logic [W-1:0] bm = '0, input logic [W-1:0] bv = '0);
        logic [31:0] st, v;
        int nexp = 0, nbrk = 0;
        cur_mask = m;
        recs.delete(); got.delete();
        for (int i = 0; i < n; i++) begin
            logic [W-1:0] r;
            for (int j = 0; j < W / 32; j++) r[32*j +: 32] = $urandom;
            recs.push_back(r & m);
        end
        n_recs = 0;
        @(negedge clk); rst_n = 1;                           // out of reset, then configure
        wr(EP_REG_SQUASH, window);
        if (m != MASK)                                       // set at run time, then read back
            for (int j = 0; j < W / 32; j++) begin
                wr(EP_REG_SQMASK_SEL, j); wr(EP_REG_SQMASK, m[32*j +: 32]);
                rd(EP_AW'(EP_REG_SQMASK), v);
                if (v != m[32*j +: 32]) begin errors++; $display("FAIL mask word %0d reads %h", j, v); end
            end
        if (bm != '0)                                        // break pattern 2: mask and value, enabled
            for (int j = 0; j < W / 32; j++) begin
                wr(EP_REG_BRK_SEL, 32'h0004_0000 | (2 << 8) | j);         wr(EP_REG_BRK_DATA, bm[32*j +: 32]);
                wr(EP_REG_BRK_SEL, 32'h0004_0000 | (2 << 8) | 32'h800 | j); wr(EP_REG_BRK_DATA, bv[32*j +: 32]);
                rd(EP_AW'(EP_REG_BRK_DATA), v);
                if (v != bv[32*j +: 32]) begin errors++; $display("FAIL break value word %0d reads %h", j, v); end
            end
        wr(EP_REG_CTRL, 32'(1 << CTRL_ENABLE) | 32'(1 << CTRL_CLEAR));
        n_recs = n;
        repeat (2) @(negedge clk);
        while (!dut_done) begin
            rd(EP_AW'(EP_REG_STATUS), st);
            if (st[0]) drain();                              // full: the DUT is frozen meanwhile
        end
        repeat (4) @(negedge clk);
        wr(EP_REG_CTRL, 32'(1 << CTRL_ENABLE) | 32'(1 << CTRL_FLUSH));
        repeat (4) @(negedge clk);
        drain();
        // reference windows
        begin
            int unsigned i = 0, win = (window == 0) ? 1 : window;
            while (i < n) begin
                logic [31:0] cc = '1, cz = '1, k = 0;
                logic [REC_W-1:0] exp;
                while (k < win && i < n) begin
                    cc = crc_rec(cc, recs[i], 32'h82F63B78); cz = crc_rec(cz, recs[i], 32'hEDB88320);
                    k++; i++;
                    if (bm != '0 && (recs[i - 1] & bm) == bv) begin nbrk++; break; end   // a break: the window ends
                end
                exp = {cz, cc, k, recs[i - 1]};
                if (nexp >= got.size()) begin
                    errors++; $display("FAIL window %0d n=%0d: fused record %0d missing", window, n, nexp);
                end else if ((got[nexp] & {96'h0, m}) != (exp & {96'h0, m})
                             || got[nexp][REC_W-1 -: 96] != exp[REC_W-1 -: 96]) begin
                    errors++;
                    if (errors < 5) $display("FAIL window %0d n=%0d: record %0d got %h exp %h", window, n, nexp,
                                             got[nexp][REC_W-1 -: 96], exp[REC_W-1 -: 96]);
                end
                nexp++;
            end
            if (got.size() != nexp) begin
                errors++; $display("FAIL window %0d n=%0d: %0d fused records, expected %0d", window, n, got.size(), nexp);
            end
            $display("INFO window %0d: %0d records -> %0d fused records (%0d breaks)", window, n, got.size(), nbrk);
        end
        rst_n = 0; repeat (2) @(negedge clk);
    endtask

    initial begin
        repeat (3) @(negedge clk);
        run(1, 50);
        run(7, 200);
        run(64, 1000);
        run(64, 64 * 20);       // exact multiple: no partial window
        run(0, 30);             // 0 behaves as 1
        run(64, 1000, MASK & {(W/32){32'h0F0F_F00F}});      // a run-time mask: fewer bits compared
        run(7, 200, MASK & ~(W'(1) << (W - 1)));             // ... one bit out
        run(64, 1000, MASK, W'(4'hF), W'(4'h5));             // break on rec[3:0] == 5 (compared bits)
        $display("TB_OCV_SQUASH: %s (%0d errors)", errors ? "FAIL" : "PASS", errors);
        $finish;
    end
endmodule
