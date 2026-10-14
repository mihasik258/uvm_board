/// AXI4 slave -> one port of a word-wide RAM (one-cycle registered read).
///
/// For gen/cpu_wrap.py. Data 32 or 64 bits wide (DW); one transaction at a time; FIXED, INCR and WRAP
/// bursts, narrow transfers (AxSIZE below the bus width: the data on the lanes of the address); writes
/// honour WSTRB. A beat is served one 32-bit word at a time: the RAM port carries the word's byte address;
/// words no RAM region holds (ram_hit low) are accepted: writes are dropped, reads return 0 (e.g. a
/// console port). Response is always OKAY. A read beat touches only the words its size covers, a write
/// beat only the words with strobes - so a device sees just the accesses the core made.
/// WRITE_EN = 0 makes a read-only port (instruction fetch): AW/W are never accepted.
/// Latency: accepting an address or a write beat waits 0..lat_gnt clocks, a read beat or a write response
/// 0..lat_rsp (a generator seeded by lat_seed; 0 and 0: as without). Protocol check: a raised AR/AW/W valid
/// stays until accepted and its payload does not change (AXI4 A3.2.1) - else `proto_err` for one clock.
/// Device windows (gen/cpu_wrap.py `device`): `dev` says the current word's address (dreq_addr) is in
/// one; a write there is posted to the processor as a request record, a read is sent as a request and waits
/// for the processor's answer (`dresp_ready`: the hub holds the core's clock meanwhile).
module ocv_axi_mem #(
    parameter bit          WRITE_EN = 1'b1,
    parameter int unsigned IDW      = 4,      // AXI ID width
    parameter int unsigned DW       = 32,     // AXI data width: 32 or 64
    parameter logic [31:0] SALT     = 32'h0   // makes the waits of two ports differ
) (
    input  logic          clk,
    input  logic          rst_n,
    // AXI4 slave
    input  logic [IDW-1:0] awid,
    input  logic [31:0]   awaddr,
    input  logic [7:0]    awlen,
    input  logic [2:0]    awsize,
    input  logic [1:0]    awburst,
    input  logic          awvalid,
    output logic          awready,
    input  logic [DW-1:0] wdata,
    input  logic [DW/8-1:0] wstrb,
    input  logic          wlast,
    input  logic          wvalid,
    output logic          wready,
    output logic [IDW-1:0] bid,
    output logic [1:0]    bresp,
    output logic          bvalid,
    input  logic          bready,
    input  logic [IDW-1:0] arid,
    input  logic [31:0]   araddr,
    input  logic [7:0]    arlen,
    input  logic [2:0]    arsize,
    input  logic [1:0]    arburst,
    input  logic          arvalid,
    output logic          arready,
    output logic [IDW-1:0] rid,
    output logic [DW-1:0] rdata,
    output logic [1:0]    rresp,
    output logic          rlast,
    output logic          rvalid,
    input  logic          rready,
    // RAM port
    output logic          ram_en,
    output logic [3:0]    ram_we,
    output logic [31:0]   ram_addr,      // byte address (of the current word)
    output logic [31:0]   ram_wdata,
    input  logic [31:0]   ram_rdata,
    input  logic          ram_hit,       // a RAM region holds ram_addr
    // device windows
    input  logic          dev,           // the current word's address (dreq_addr) is in a device window
    output logic          dreq_valid,
    output logic [31:0]   dreq_addr,
    output logic          dreq_we,
    output logic [3:0]    dreq_be,
    output logic [31:0]   dreq_wdata,
    output logic          dresp_ready,
    input  logic          dresp_valid,
    input  logic [31:0]   dresp_rdata,
    // latency (held while the core runs) and the protocol check
    input  logic [31:0]   lat_seed,
    input  logic [7:0]    lat_gnt,
    input  logic [7:0]    lat_rsp,
    output logic          proto_err
);
    localparam int unsigned NW = DW / 32;          // words per beat
    localparam int unsigned KW = NW > 1 ? $clog2(NW) : 1;
    localparam int unsigned LB = $clog2(DW / 8);   // byte address bits of a full beat

    typedef enum logic [2:0] {IDLE, RD_FETCH, RD_GET, RD_DEV, RD_DATA, WR_DATA, WR_WORD, WR_RESP} state_e;
    state_e      state_q;
    logic [31:0] addr_q;                           // the beat's address
    logic [7:0]  len_q, beat_q;
    logic [2:0]  size_q;
    logic [1:0]  burst_q;
    logic [IDW-1:0] id_q;
    logic [KW-1:0]  k_q, klast_q;                  // the word of the beat, the beat's last word
    logic [31:0] rbuf_q [NW];
    logic [DW-1:0]   wbuf_q;
    logic [DW/8-1:0] sbuf_q;
    logic        wlast_q;

    // the words a beat covers: all for a full-width one, else the word holding the address
    function automatic logic [KW-1:0] word_of(input logic [31:0] a);
        return NW > 1 ? KW'(a[LB-1:2]) : '0;
    endfunction
    function automatic logic [KW-1:0] first_word(input logic [31:0] a, input logic [2:0] s);
        return (32'(s) >= LB) ? '0 : word_of(a);
    endfunction
    function automatic logic [KW-1:0] last_word(input logic [31:0] a, input logic [2:0] s);
        return (32'(s) >= LB) ? KW'(NW - 1) : word_of(a);
    endfunction
    // the bytes a narrow read covers in its word
    function automatic logic [3:0] read_be(input logic [31:0] a, input logic [2:0] s);
        return s == 3'd0 ? 4'b0001 << a[1:0] : s == 3'd1 ? (a[1] ? 4'b1100 : 4'b0011) : 4'b1111;
    endfunction

    // the next beat's address (A3.4.1): FIXED stays, INCR goes on from the aligned address, WRAP
    // wraps at the burst's size
    logic [31:0] inc, aligned, wrap_mask, next_addr;
    assign inc       = 32'd1 << size_q;
    assign aligned   = addr_q & ~(inc - 32'd1);
    assign wrap_mask = ((32'(len_q) + 32'd1) << size_q) - 32'd1;
    always_comb
        unique case (burst_q)
            2'b00:   next_addr = addr_q;
            2'b10:   next_addr = (addr_q & ~wrap_mask) | ((aligned + inc) & wrap_mask);
            default: next_addr = aligned + inc;
        endcase

    // the current word
    logic [31:0] waddr;
    logic [3:0]  wstrb_k;
    logic [31:0] wdata_k;
    if (NW > 1) begin : g_wide
        assign waddr = {addr_q[31:LB], k_q, 2'b00};
    end else begin : g_narrow
        assign waddr = {addr_q[31:2], 2'b00};
    end
    assign wstrb_k = sbuf_q[4 * k_q +: 4];
    assign wdata_k = wbuf_q[32 * k_q +: 32];

    // the waits: xorshift32, one step per clock; w_q counts the current one down
    logic [31:0] rnd_q, r1, r2, rnd_n;
    assign r1    = rnd_q ^ (rnd_q << 13);
    assign r2    = r1 ^ (r1 >> 17);
    assign rnd_n = r2 ^ (r2 << 5);
    function automatic logic [7:0] draw(input logic [31:0] r, input logic [7:0] max);
        return max == 0 ? 8'd0 : 8'(r[15:0] % (16'(max) + 16'd1));
    endfunction
    logic [7:0] w_q;
    logic       armed_q, accept_ok;
    assign accept_ok = lat_gnt == 0 || (armed_q && w_q == 0);

    assign arready = (state_q == IDLE) & accept_ok & ~(WRITE_EN & awvalid);   // writes first when both wait
    assign awready = WRITE_EN & (state_q == IDLE) & accept_ok;
    assign wready  = (state_q == WR_DATA) && w_q == 0;
    assign rvalid  = (state_q == RD_DATA) && w_q == 0;
    always_comb for (int i = 0; i < NW; i++) rdata[32 * i +: 32] = rbuf_q[i];
    assign rid     = id_q;
    assign rresp   = 2'b00;
    assign rlast   = (beat_q == len_q);
    assign bvalid  = (state_q == WR_RESP) && w_q == 0;
    assign bid     = id_q;
    assign bresp   = 2'b00;

    // device: a read word in RD_FETCH, a write word with strobes in WR_WORD
    assign dreq_addr   = waddr;
    assign dreq_we     = state_q == WR_WORD;
    assign dreq_be     = state_q == WR_WORD ? wstrb_k : read_be(addr_q, size_q);
    assign dreq_wdata  = wdata_k;
    assign dreq_valid  = dev && ((state_q == RD_FETCH) || (state_q == WR_WORD && wstrb_k != 4'b0));
    assign dresp_ready = state_q == RD_DEV;

    // RAM port: the same, outside the device windows (writes only where a region is)
    assign ram_addr  = waddr;
    assign ram_wdata = wdata_k;
    assign ram_en    = !dev && ((state_q == RD_FETCH) || (state_q == WR_WORD && wstrb_k != 4'b0 && ram_hit));
    assign ram_we    = (!dev && state_q == WR_WORD && ram_hit) ? wstrb_k : 4'b0;

    logic in_range_q;
    always_ff @(posedge clk) begin
        if (~rst_n) begin
            state_q <= IDLE;
            addr_q <= '0; len_q <= '0; beat_q <= '0; size_q <= '0; burst_q <= '0; id_q <= '0;
            k_q <= '0; klast_q <= '0; wbuf_q <= '0; sbuf_q <= '0; wlast_q <= 1'b0; in_range_q <= 1'b0;
            for (int i = 0; i < NW; i++) rbuf_q[i] <= '0;
            w_q <= '0; armed_q <= 1'b0;
            rnd_q <= (lat_seed ^ SALT) == 0 ? 32'h1 : lat_seed ^ SALT;
        end else begin
            rnd_q <= rnd_n;
            if (w_q != 0) w_q <= w_q - 8'd1;
            unique case (state_q)
                IDLE: begin
                    beat_q <= '0;
                    if (awready && awvalid) begin
                        addr_q <= awaddr; len_q <= awlen; size_q <= awsize; burst_q <= awburst; id_q <= awid;
                        state_q <= WR_DATA; armed_q <= 1'b0; w_q <= draw(rnd_q, lat_gnt);
                    end else if (arready && arvalid) begin
                        addr_q <= araddr; len_q <= arlen; size_q <= arsize; burst_q <= arburst; id_q <= arid;
                        k_q <= first_word(araddr, arsize); klast_q <= last_word(araddr, arsize);
                        for (int i = 0; i < NW; i++) rbuf_q[i] <= '0;
                        state_q <= RD_FETCH; armed_q <= 1'b0;
                    end else if ((arvalid || (WRITE_EN && awvalid)) && !armed_q) begin
                        armed_q <= 1'b1; w_q <= draw(rnd_q, lat_gnt);
                    end
                end
                RD_FETCH: begin
                    in_range_q <= ram_hit;
                    state_q    <= dev ? RD_DEV : RD_GET;
                end
                RD_GET, RD_DEV: if (state_q == RD_GET || dresp_valid) begin
                    rbuf_q[k_q] <= state_q == RD_DEV ? dresp_rdata : (in_range_q ? ram_rdata : 32'h0);
                    if (k_q != klast_q) begin k_q <= k_q + 1'b1; state_q <= RD_FETCH; end
                    else begin state_q <= RD_DATA; w_q <= draw(rnd_q, lat_rsp); end
                end
                RD_DATA: if (rready && rvalid) begin
                    if (rlast) state_q <= IDLE;
                    else begin
                        beat_q  <= beat_q + 1'b1;
                        addr_q  <= next_addr;
                        k_q     <= first_word(next_addr, size_q);
                        klast_q <= last_word(next_addr, size_q);
                        for (int i = 0; i < NW; i++) rbuf_q[i] <= '0;
                        state_q <= RD_FETCH;
                    end
                end
                WR_DATA: if (wvalid && wready) begin
                    wbuf_q <= wdata; sbuf_q <= wstrb; wlast_q <= wlast;
                    k_q <= '0;
                    state_q <= WR_WORD;
                end
                WR_WORD:
                    if (k_q != KW'(NW - 1)) k_q <= k_q + 1'b1;
                    else if (wlast_q) begin state_q <= WR_RESP; w_q <= draw(rnd_q, lat_rsp); end
                    else begin addr_q <= next_addr; state_q <= WR_DATA; w_q <= draw(rnd_q, lat_gnt); end
                WR_RESP: if (bready && bvalid) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
    // protocol: a raised valid stays until accepted, its payload unchanged
    logic            ar_w_q, aw_w_q, w_w_q;
    logic [31:0]     ar_a_q, aw_a_q;
    logic [DW-1:0]   w_d_q;
    logic [10:0]     ar_l_q, aw_l_q;
    logic [DW/8-1:0] w_s_q;
    logic            w_l_q;
    always_ff @(posedge clk) begin
        if (~rst_n) begin ar_w_q <= 1'b0; aw_w_q <= 1'b0; w_w_q <= 1'b0; end
        else begin
            ar_w_q <= arvalid && !arready; ar_a_q <= araddr; ar_l_q <= {arlen, arsize};
            aw_w_q <= awvalid && !awready; aw_a_q <= awaddr; aw_l_q <= {awlen, awsize};
            w_w_q  <= wvalid && !wready;   w_d_q  <= wdata;  w_s_q  <= wstrb; w_l_q <= wlast;
        end
    end
    assign proto_err = rst_n && ((ar_w_q && (!arvalid || araddr != ar_a_q || {arlen, arsize} != ar_l_q)) ||
                                 (aw_w_q && (!awvalid || awaddr != aw_a_q || {awlen, awsize} != aw_l_q)) ||
                                 (w_w_q && (!wvalid || wdata != w_d_q || wstrb != w_s_q || wlast != w_l_q)));
endmodule : ocv_axi_mem
