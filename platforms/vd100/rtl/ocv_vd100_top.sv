/// ocv_vd100_top - OCV platform top for the ALINX VD100: the board block design (PS, DDR4, PL clock,
/// AXI4-Lite master) plus one generated verification environment on its AXI4-Lite port.
///
/// The environment is chosen at build time, not by editing this file:
///   OCV_ENV   module name of the generated wrapper (<name>_ocv)
///   OCV_AW    its AXI4-Lite address width (addr_w in <name>_ocv_meta.json)
/// The hub decodes the low OCV_AW bits; the BD window (create_bd.tcl) is 2^OCV_AW bytes.
///   OCV_DMA_DW, OCV_DMA_IDW  (a wrapper built with --dma) data and ID width of its AXI4 master: it
///             goes to the BD port ocv_dma (NoC -> DDR), ID zero-extended to the port's 4 bits.
`ifndef OCV_ENV
    `error "OCV_ENV (generated wrapper module) is not defined"
`endif
`ifndef OCV_AW
    `error "OCV_AW (wrapper address width) is not defined"
`endif
// OCV_DEBUG (debug build): keep the hub's AXI4-Lite bus and reset for the ILA that tcl/build.tcl
// inserts after synthesis.
`ifdef OCV_DEBUG
    `define OCV_PROBE (* mark_debug = "true" *)
`else
    `define OCV_PROBE
`endif

module ocv_vd100_top (
    input  logic [ 0:0] sys_clk_p,
    input  logic [ 0:0] sys_clk_n,
    output logic [ 0:0] DDR4_act_n,
    output logic [16:0] DDR4_adr,
    output logic [ 1:0] DDR4_ba,
    output logic [ 0:0] DDR4_bg,
    output logic [ 0:0] DDR4_ck_c,
    output logic [ 0:0] DDR4_ck_t,
    output logic [ 0:0] DDR4_cke,
    output logic [ 0:0] DDR4_cs_n,
    inout  wire  [ 7:0] DDR4_dm_n,
    inout  wire  [63:0] DDR4_dq,
    inout  wire  [ 7:0] DDR4_dqs_c,
    inout  wire  [ 7:0] DDR4_dqs_t,
    output logic [ 0:0] DDR4_odt,
    output logic [ 0:0] DDR4_reset_n
);
    logic                  clk;
    `OCV_PROBE logic        rst_n;
    `OCV_PROBE logic [31:0] awaddr, araddr, wdata, rdata;
    logic [ 2:0]           awprot, arprot;
    `OCV_PROBE logic [ 3:0] wstrb;
    `OCV_PROBE logic [ 1:0] bresp, rresp;
    `OCV_PROBE logic        awvalid, awready, wvalid, wready, bvalid, bready;
    `OCV_PROBE logic        arvalid, arready, rvalid, rready;
`ifdef OCV_DMA_DW
    localparam int DDW = `OCV_DMA_DW, DIW = `OCV_DMA_IDW;
    logic [DIW-1:0]   d_awid, d_bid, d_arid, d_rid;
    logic [63:0]      d_awaddr, d_araddr;
    logic [7:0]       d_awlen, d_arlen;
    logic [2:0]       d_awsize, d_arsize, d_awprot, d_arprot;
    logic [1:0]       d_awburst, d_arburst, d_bresp, d_rresp;
    logic [3:0]       d_awcache, d_arcache, d_awqos, d_arqos, bd_bid, bd_rid;
    logic             d_awlock, d_arlock, d_awvalid, d_awready, d_wlast, d_wvalid, d_wready;
    logic             d_bvalid, d_bready, d_arvalid, d_arready, d_rlast, d_rvalid, d_rready;
    logic [DDW-1:0]   d_wdata, d_rdata;
    logic [DDW/8-1:0] d_wstrb;
    assign d_bid = DIW'(bd_bid);
    assign d_rid = DIW'(bd_rid);
`endif

    ocv_vd100_bd_wrapper i_bd (
        .sys_clk_p, .sys_clk_n,
        .DDR4_act_n, .DDR4_adr, .DDR4_ba, .DDR4_bg, .DDR4_ck_c, .DDR4_ck_t, .DDR4_cke,
        .DDR4_cs_n, .DDR4_dm_n, .DDR4_dq, .DDR4_dqs_c, .DDR4_dqs_t, .DDR4_odt, .DDR4_reset_n,
        .ocv_clk            (clk),
        .ocv_rst_n          (rst_n),
        .ocv_axil_awaddr    (awaddr),
        .ocv_axil_awprot    (awprot),
        .ocv_axil_awvalid   (awvalid),
        .ocv_axil_awready   (awready),
        .ocv_axil_wdata     (wdata),
        .ocv_axil_wstrb     (wstrb),
        .ocv_axil_wvalid    (wvalid),
        .ocv_axil_wready    (wready),
        .ocv_axil_bresp     (bresp),
        .ocv_axil_bvalid    (bvalid),
        .ocv_axil_bready    (bready),
        .ocv_axil_araddr    (araddr),
        .ocv_axil_arprot    (arprot),
        .ocv_axil_arvalid   (arvalid),
        .ocv_axil_arready   (arready),
        .ocv_axil_rdata     (rdata),
        .ocv_axil_rresp     (rresp),
        .ocv_axil_rvalid    (rvalid),
`ifdef OCV_DMA_DW
        .ocv_dma_awid       (4'(d_awid)),   .ocv_dma_awaddr  (d_awaddr), .ocv_dma_awlen   (d_awlen),
        .ocv_dma_awsize     (d_awsize),     .ocv_dma_awburst (d_awburst), .ocv_dma_awlock (d_awlock),
        .ocv_dma_awcache    (d_awcache),    .ocv_dma_awprot  (d_awprot), .ocv_dma_awqos   (d_awqos),
        .ocv_dma_awvalid    (d_awvalid),    .ocv_dma_awready (d_awready),
        .ocv_dma_wdata      (d_wdata),      .ocv_dma_wstrb   (d_wstrb),  .ocv_dma_wlast   (d_wlast),
        .ocv_dma_wvalid     (d_wvalid),     .ocv_dma_wready  (d_wready),
        .ocv_dma_bid        (bd_bid),       .ocv_dma_bresp   (d_bresp),  .ocv_dma_bvalid  (d_bvalid),
        .ocv_dma_bready     (d_bready),
        .ocv_dma_arid       (4'(d_arid)),   .ocv_dma_araddr  (d_araddr), .ocv_dma_arlen   (d_arlen),
        .ocv_dma_arsize     (d_arsize),     .ocv_dma_arburst (d_arburst), .ocv_dma_arlock (d_arlock),
        .ocv_dma_arcache    (d_arcache),    .ocv_dma_arprot  (d_arprot), .ocv_dma_arqos   (d_arqos),
        .ocv_dma_arvalid    (d_arvalid),    .ocv_dma_arready (d_arready),
        .ocv_dma_rid        (bd_rid),       .ocv_dma_rdata   (d_rdata),  .ocv_dma_rresp   (d_rresp),
        .ocv_dma_rlast      (d_rlast),      .ocv_dma_rvalid  (d_rvalid), .ocv_dma_rready  (d_rready),
`endif
        .ocv_axil_rready    (rready)
    );

    `OCV_ENV i_env (
        .clk, .rst_n,
        .s_axi_awaddr   (awaddr[`OCV_AW-1:0]),
        .s_axi_awprot   (awprot),
        .s_axi_awvalid  (awvalid),
        .s_axi_awready  (awready),
        .s_axi_wdata    (wdata),
        .s_axi_wstrb    (wstrb),
        .s_axi_wvalid   (wvalid),
        .s_axi_wready   (wready),
        .s_axi_bresp    (bresp),
        .s_axi_bvalid   (bvalid),
        .s_axi_bready   (bready),
        .s_axi_araddr   (araddr[`OCV_AW-1:0]),
        .s_axi_arprot   (arprot),
        .s_axi_arvalid  (arvalid),
        .s_axi_arready  (arready),
        .s_axi_rdata    (rdata),
        .s_axi_rresp    (rresp),
        .s_axi_rvalid   (rvalid),
`ifdef OCV_DMA_DW
        .m_axi_awid (d_awid), .m_axi_awaddr (d_awaddr), .m_axi_awlen (d_awlen), .m_axi_awsize (d_awsize),
        .m_axi_awburst (d_awburst), .m_axi_awcache (d_awcache), .m_axi_awprot (d_awprot),
        .m_axi_awlock (d_awlock), .m_axi_awqos (d_awqos), .m_axi_awvalid (d_awvalid), .m_axi_awready (d_awready),
        .m_axi_wdata (d_wdata), .m_axi_wstrb (d_wstrb), .m_axi_wlast (d_wlast), .m_axi_wvalid (d_wvalid),
        .m_axi_wready (d_wready), .m_axi_bid (d_bid), .m_axi_bresp (d_bresp), .m_axi_bvalid (d_bvalid),
        .m_axi_bready (d_bready),
        .m_axi_arid (d_arid), .m_axi_araddr (d_araddr), .m_axi_arlen (d_arlen), .m_axi_arsize (d_arsize),
        .m_axi_arburst (d_arburst), .m_axi_arcache (d_arcache), .m_axi_arprot (d_arprot),
        .m_axi_arlock (d_arlock), .m_axi_arqos (d_arqos), .m_axi_arvalid (d_arvalid), .m_axi_arready (d_arready),
        .m_axi_rid (d_rid), .m_axi_rdata (d_rdata), .m_axi_rresp (d_rresp), .m_axi_rlast (d_rlast),
        .m_axi_rvalid (d_rvalid), .m_axi_rready (d_rready),
`endif
        .s_axi_rready   (rready)
    );
endmodule : ocv_vd100_top
