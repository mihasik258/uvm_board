/// OCV hub - the single AXI4-Lite slave through which the PS sees one DUT's verification
/// environment, whatever the number of channels.
///
/// Address space: N_EP+1 slots of 2**SLOT_AW bytes. Slot 0 is the hub itself (directory and DUT
/// control, ocv_pkg HUB_REG_*); slot k (1..N_EP) is endpoint k-1, reached over a register bus.
/// Software needs only the hub base address: it reads LAYOUT to find the slots and each
/// endpoint's KIND/GEOMETRY to find the rest. DUT_ID lets software check that the metadata it
/// was built with matches the bitstream.
///
/// DUT control: dut_rst_o (active high) holds the DUT in reset while DUT_CTRL[0] is set; the
/// wrapper also feeds it to the endpoints' clear inputs, so every DUT run starts a fresh
/// capture and rewinds stimulus. CYCLES counts clocks while the DUT is out of reset.
module ocv_hub #(
    parameter int unsigned N_EP         = 1,
    parameter int unsigned SLOT_AW      = 18,     // bytes per slot = 2**SLOT_AW (>= every EP_AW)
    parameter logic [31:0] DUT_ID       = '0,
    parameter bit          DUT_RST_INIT = 1'b0,   // DUT_CTRL[0] after reset
    // Derived - do not override.
    parameter int unsigned SEL_W        = $clog2(N_EP + 1),
    parameter int unsigned ADDR_W       = SLOT_AW + SEL_W
) (
    input  logic                         clk,
    input  logic                         rst_n,
    // AXI4-Lite slave
    input  logic [ADDR_W-1:0]            s_axi_awaddr,
    input  logic [2:0]                   s_axi_awprot,
    input  logic                         s_axi_awvalid,
    output logic                         s_axi_awready,
    input  logic [31:0]                  s_axi_wdata,
    input  logic [3:0]                   s_axi_wstrb,
    input  logic                         s_axi_wvalid,
    output logic                         s_axi_wready,
    output logic [1:0]                   s_axi_bresp,
    output logic                         s_axi_bvalid,
    input  logic                         s_axi_bready,
    input  logic [ADDR_W-1:0]            s_axi_araddr,
    input  logic [2:0]                   s_axi_arprot,
    input  logic                         s_axi_arvalid,
    output logic                         s_axi_arready,
    output logic [31:0]                  s_axi_rdata,
    output logic [1:0]                   s_axi_rresp,
    output logic                         s_axi_rvalid,
    input  logic                         s_axi_rready,
    // endpoint register buses (address/data shared, strobes per endpoint)
    output logic [N_EP-1:0]              ep_wr,
    output logic [SLOT_AW-1:0]           ep_waddr,
    output logic [31:0]                  ep_wdata,
    output logic [3:0]                   ep_wstrb,
    output logic [N_EP-1:0]              ep_rd,
    output logic [SLOT_AW-1:0]           ep_raddr,
    output logic [SLOT_AW-1:0]           ep_rd_addr_q,
    input  logic [N_EP-1:0][31:0]        ep_rdata,
    // DUT control
    output logic                         dut_rst_o
);
    import ocv_pkg::*;

    if (N_EP < 1 || N_EP > 255 || SLOT_AW < 8 || SLOT_AW > 30) begin : g_bad_params
        $error("ocv_hub: need 1 <= N_EP <= 255 and 8 <= SLOT_AW <= 30");
    end

    logic              req_wr, req_rd;
    logic [ADDR_W-1:0] req_waddr, req_raddr, rd_addr_q;
    logic [31:0]       req_wdata, rd_data;
    logic [3:0]        req_wstrb;

    ocv_axil_slave #(.ADDR_W(ADDR_W)) i_axil (
        .clk, .rst_n,
        .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,
        .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
        .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
        .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,
        .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
        .req_wr, .req_waddr, .req_wdata, .req_wstrb,
        .req_rd, .req_raddr, .rd_addr_q, .rd_data
    );

    // ---------------- decode ----------------
    logic [SEL_W-1:0] wsel, rsel, rsel_q;
    assign wsel   = req_waddr[ADDR_W-1 -: SEL_W];
    assign rsel   = req_raddr[ADDR_W-1 -: SEL_W];
    assign rsel_q = rd_addr_q[ADDR_W-1 -: SEL_W];

    assign ep_waddr     = req_waddr[SLOT_AW-1:0];
    assign ep_wdata     = req_wdata;
    assign ep_wstrb     = req_wstrb;
    assign ep_raddr     = req_raddr[SLOT_AW-1:0];
    assign ep_rd_addr_q = rd_addr_q[SLOT_AW-1:0];

    always_comb begin
        for (int k = 0; k < N_EP; k++) begin
            ep_wr[k] = req_wr & (wsel == SEL_W'(k + 1));
            ep_rd[k] = req_rd & (rsel == SEL_W'(k + 1));
        end
    end

    // ---------------- hub registers ----------------
    logic        dut_rst_q;
    logic [63:0] cycles_q, snap_q;
    logic        hub_wr, hub_rd;

    assign hub_wr    = req_wr & (wsel == '0);
    assign hub_rd    = req_rd & (rsel == '0);
    assign dut_rst_o = dut_rst_q;

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            dut_rst_q <= DUT_RST_INIT;
            cycles_q  <= '0;
            snap_q    <= '0;
        end else begin
            if (hub_wr && req_waddr[SLOT_AW-1:0] == SLOT_AW'(HUB_REG_DUT_CTRL) && req_wstrb[0])
                dut_rst_q <= req_wdata[DUT_CTRL_RESET];
            if (dut_rst_q) cycles_q <= '0;
            else           cycles_q <= cycles_q + 1'b1;
            if (hub_rd && req_raddr[SLOT_AW-1:0] == SLOT_AW'(HUB_REG_CYCLES_LO))
                snap_q <= cycles_q;
        end
    end

    logic [31:0] hub_rdata;
    always_comb begin
        unique case (rd_addr_q[SLOT_AW-1:0])
            SLOT_AW'(HUB_REG_ID):        hub_rdata = HUB_ID;
            SLOT_AW'(HUB_REG_VERSION):   hub_rdata = HUB_VERSION;
            SLOT_AW'(HUB_REG_LAYOUT):    hub_rdata = {16'b0, 8'(SLOT_AW), 8'(N_EP)};
            SLOT_AW'(HUB_REG_DUT_ID):    hub_rdata = DUT_ID;
            SLOT_AW'(HUB_REG_DUT_CTRL):  hub_rdata = 32'(dut_rst_q);
            SLOT_AW'(HUB_REG_CYCLES_LO): hub_rdata = snap_q[31:0];
            SLOT_AW'(HUB_REG_CYCLES_HI): hub_rdata = snap_q[63:32];
            default:                     hub_rdata = '0;
        endcase
    end

    // ---------------- read data mux (cycle after req_rd) ----------------
    always_comb begin
        rd_data = '0;
        if (rsel_q == '0) rd_data = hub_rdata;
        for (int k = 0; k < N_EP; k++)
            if (rsel_q == SEL_W'(k + 1)) rd_data = ep_rdata[k];
    end

endmodule : ocv_hub
