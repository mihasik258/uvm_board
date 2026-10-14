/// AXI4 slave -> one port of a word-wide RAM (one-cycle registered read).
///
/// Part of the SCR1 OCV adapter. One transaction at a time; INCR and FIXED bursts; writes
/// honour WSTRB. Addresses outside [0, 4*2^AW) are accepted: writes are dropped, reads return 0
/// (the SCR1 tests write their console output to such an address). Response is always OKAY.
/// WRITE_EN = 0 makes a read-only port (instruction fetch): AW/W are never accepted.
module scr1_ocv_axi_mem #(
    parameter int unsigned AW       = 14,     // RAM words = 2**AW
    parameter bit          WRITE_EN = 1'b1
) (
    input  logic          clk,
    input  logic          rst_n,
    // AXI4 slave
    input  logic [3:0]    awid,
    input  logic [31:0]   awaddr,
    input  logic [7:0]    awlen,
    input  logic [1:0]    awburst,
    input  logic          awvalid,
    output logic          awready,
    input  logic [31:0]   wdata,
    input  logic [3:0]    wstrb,
    input  logic          wlast,
    input  logic          wvalid,
    output logic          wready,
    output logic [3:0]    bid,
    output logic [1:0]    bresp,
    output logic          bvalid,
    input  logic          bready,
    input  logic [3:0]    arid,
    input  logic [31:0]   araddr,
    input  logic [7:0]    arlen,
    input  logic [1:0]    arburst,
    input  logic          arvalid,
    output logic          arready,
    output logic [3:0]    rid,
    output logic [31:0]   rdata,
    output logic [1:0]    rresp,
    output logic          rlast,
    output logic          rvalid,
    input  logic          rready,
    // RAM port
    output logic          ram_en,
    output logic [3:0]    ram_we,
    output logic [AW-1:0] ram_addr,
    output logic [31:0]   ram_wdata,
    input  logic [31:0]   ram_rdata
);
    typedef enum logic [2:0] {IDLE, RD_FETCH, RD_DATA, WR_DATA, WR_RESP} state_e;
    state_e      state_q;
    logic [31:0] addr_q;
    logic [7:0]  len_q, beat_q;
    logic        fixed_q;
    logic [3:0]  id_q;
    logic        in_range_q;

    function automatic logic in_range(input logic [31:0] a);
        return (a >> (AW + 2)) == '0;
    endfunction

    logic [31:0] next_addr;
    assign next_addr = fixed_q ? addr_q : addr_q + 32'd4;

    assign arready = (state_q == IDLE) & ~(WRITE_EN & awvalid);   // writes first when both wait
    assign awready = WRITE_EN & (state_q == IDLE);
    assign wready  = (state_q == WR_DATA);
    assign rvalid  = (state_q == RD_DATA);
    assign rdata   = in_range_q ? ram_rdata : 32'h0;
    assign rid     = id_q;
    assign rresp   = 2'b00;
    assign rlast   = (beat_q == len_q);
    assign bvalid  = (state_q == WR_RESP);
    assign bid     = id_q;
    assign bresp   = 2'b00;

    // RAM port: a read is issued in RD_FETCH, a write on each accepted in-range W beat.
    always_comb begin
        ram_en    = 1'b0;
        ram_we    = '0;
        ram_addr  = addr_q[AW+1:2];
        ram_wdata = wdata;
        if (state_q == RD_FETCH) ram_en = 1'b1;
        if (state_q == WR_DATA && wvalid && in_range(addr_q)) begin
            ram_en = 1'b1;
            ram_we = wstrb;
        end
    end

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            state_q <= IDLE;
            addr_q <= '0; len_q <= '0; beat_q <= '0; fixed_q <= 1'b0; id_q <= '0; in_range_q <= 1'b0;
        end else begin
            unique case (state_q)
                IDLE: begin
                    beat_q <= '0;
                    if (awready && awvalid) begin
                        addr_q <= awaddr; len_q <= awlen; fixed_q <= (awburst == 2'b00); id_q <= awid;
                        state_q <= WR_DATA;
                    end else if (arready && arvalid) begin
                        addr_q <= araddr; len_q <= arlen; fixed_q <= (arburst == 2'b00); id_q <= arid;
                        state_q <= RD_FETCH;
                    end
                end
                RD_FETCH: begin
                    in_range_q <= in_range(addr_q);
                    state_q    <= RD_DATA;
                end
                RD_DATA: if (rready) begin
                    if (rlast) state_q <= IDLE;
                    else begin
                        beat_q  <= beat_q + 1'b1;
                        addr_q  <= next_addr;
                        state_q <= RD_FETCH;
                    end
                end
                WR_DATA: if (wvalid) begin
                    addr_q <= next_addr;
                    if (wlast) state_q <= WR_RESP;
                end
                WR_RESP: if (bready) state_q <= IDLE;
                default: state_q <= IDLE;
            endcase
        end
    end
endmodule : scr1_ocv_axi_mem
