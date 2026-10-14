/// OCV AXI write arbiter - the DMA sinks of one wrapper share its AXI4 master.
///
/// Each sink's ocv_dma_wr offers one burst at a time (address and data together). The arbiter
/// grants one sink per burst, round robin, and passes its AW and W channels through until both
/// the address handshake and the last data beat are done; meanwhile the others wait. AWID is the
/// sink's index, so write responses go back by BID (the interconnect may complete different IDs in
/// any order; each sink counts its own in order).
module ocv_axi_wr_arb #(
    parameter int unsigned N   = 2,
    parameter int unsigned DW  = 128,
    parameter int unsigned AW  = 64,
    parameter int unsigned IDW = (N > 1) ? $clog2(N) : 1
) (
    input  logic                  clk,
    input  logic                  rst_n,
    // from the sinks
    input  logic [N-1:0][AW-1:0]  s_awaddr,
    input  logic [N-1:0][7:0]     s_awlen,
    input  logic [N-1:0][2:0]     s_awsize,
    input  logic [N-1:0][1:0]     s_awburst,
    input  logic [N-1:0][3:0]     s_awcache,
    input  logic [N-1:0]          s_awvalid,
    output logic [N-1:0]          s_awready,
    input  logic [N-1:0][DW-1:0]  s_wdata,
    input  logic [N-1:0][DW/8-1:0] s_wstrb,
    input  logic [N-1:0]          s_wlast,
    input  logic [N-1:0]          s_wvalid,
    output logic [N-1:0]          s_wready,
    output logic [N-1:0][1:0]     s_bresp,
    output logic [N-1:0]          s_bvalid,
    input  logic [N-1:0]          s_bready,
    // to the PS memory
    output logic [IDW-1:0]        m_axi_awid,
    output logic [AW-1:0]         m_axi_awaddr,
    output logic [7:0]            m_axi_awlen,
    output logic [2:0]            m_axi_awsize,
    output logic [1:0]            m_axi_awburst,
    output logic [3:0]            m_axi_awcache,
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [DW-1:0]         m_axi_wdata,
    output logic [DW/8-1:0]       m_axi_wstrb,
    output logic                  m_axi_wlast,
    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    input  logic [IDW-1:0]        m_axi_bid,
    input  logic [1:0]            m_axi_bresp,
    input  logic                  m_axi_bvalid,
    output logic                  m_axi_bready
);
    localparam int unsigned SW = (N > 1) ? $clog2(N) : 1;

    logic          busy_q, aw_done_q, w_done_q;
    logic [SW-1:0] sel_q, rr_q, pick;
    logic          found;

    // round robin from the sink after the last one granted
    always_comb begin
        found = 1'b0;
        pick  = '0;
        for (int k = 0; k < N; k++) begin
            logic [SW-1:0] i;
            i = SW'((int'(rr_q) + 1 + k) % N);
            if (!found && s_awvalid[i]) begin found = 1'b1; pick = i; end
        end
    end

    logic aw_fire, w_last_fire;
    assign aw_fire     = busy_q & ~aw_done_q & m_axi_awvalid & m_axi_awready;
    assign w_last_fire = busy_q & ~w_done_q & m_axi_wvalid & m_axi_wready & m_axi_wlast;

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            busy_q <= 1'b0; aw_done_q <= 1'b0; w_done_q <= 1'b0; sel_q <= '0; rr_q <= SW'(N - 1);
        end else if (!busy_q) begin
            if (found) begin busy_q <= 1'b1; sel_q <= pick; rr_q <= pick; aw_done_q <= 1'b0; w_done_q <= 1'b0; end
        end else begin
            if (aw_fire)     aw_done_q <= 1'b1;
            if (w_last_fire) w_done_q  <= 1'b1;
            if ((aw_done_q | aw_fire) && (w_done_q | w_last_fire)) busy_q <= 1'b0;
        end
    end

    assign m_axi_awid    = IDW'(sel_q);
    assign m_axi_awaddr  = s_awaddr[sel_q];
    assign m_axi_awlen   = s_awlen[sel_q];
    assign m_axi_awsize  = s_awsize[sel_q];
    assign m_axi_awburst = s_awburst[sel_q];
    assign m_axi_awcache = s_awcache[sel_q];
    assign m_axi_awvalid = busy_q & ~aw_done_q & s_awvalid[sel_q];
    assign m_axi_wdata   = s_wdata[sel_q];
    assign m_axi_wstrb   = s_wstrb[sel_q];
    assign m_axi_wlast   = s_wlast[sel_q];
    assign m_axi_wvalid  = busy_q & ~w_done_q & s_wvalid[sel_q];
    assign m_axi_bready  = s_bready[SW'(m_axi_bid)];

    always_comb begin
        for (int i = 0; i < N; i++) begin
            s_awready[i] = busy_q & ~aw_done_q & (sel_q == SW'(i)) & m_axi_awready;
            s_wready[i]  = busy_q & ~w_done_q & (sel_q == SW'(i)) & m_axi_wready;
            s_bvalid[i]  = m_axi_bvalid & (SW'(m_axi_bid) == SW'(i));
            s_bresp[i]   = m_axi_bresp;
        end
    end

endmodule : ocv_axi_wr_arb
