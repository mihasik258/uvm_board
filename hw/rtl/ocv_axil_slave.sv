/// OCV AXI4-Lite slave front end -> simple register bus.
///
/// Write: AW and W are accepted together (the slave may wait for both); the accepting cycle
/// raises req_wr for one cycle with the address, data and strobes. Response is always OKAY.
///
/// Read: fixed two-cycle latency, so a register bus client can serve reads straight out of a
/// registered RAM:
///   cycle 0  req_rd = 1, req_raddr = address         (client starts a RAM read if it needs one)
///   cycle 1  client drives rd_data for rd_addr_q      (combinational from RAM output/registers)
///   cycle 2+ RVALID with that data until RREADY.
module ocv_axil_slave #(
    parameter int unsigned ADDR_W = 18
) (
    input  logic              clk,
    input  logic              rst_n,
    // AXI4-Lite slave
    input  logic [ADDR_W-1:0] s_axi_awaddr,
    input  logic [2:0]        s_axi_awprot,
    input  logic              s_axi_awvalid,
    output logic              s_axi_awready,
    input  logic [31:0]       s_axi_wdata,
    input  logic [3:0]        s_axi_wstrb,
    input  logic              s_axi_wvalid,
    output logic              s_axi_wready,
    output logic [1:0]        s_axi_bresp,
    output logic              s_axi_bvalid,
    input  logic              s_axi_bready,
    input  logic [ADDR_W-1:0] s_axi_araddr,
    input  logic [2:0]        s_axi_arprot,
    input  logic              s_axi_arvalid,
    output logic              s_axi_arready,
    output logic [31:0]       s_axi_rdata,
    output logic [1:0]        s_axi_rresp,
    output logic              s_axi_rvalid,
    input  logic              s_axi_rready,
    // register bus
    output logic              req_wr,
    output logic [ADDR_W-1:0] req_waddr,
    output logic [31:0]       req_wdata,
    output logic [3:0]        req_wstrb,
    output logic              req_rd,
    output logic [ADDR_W-1:0] req_raddr,
    output logic [ADDR_W-1:0] rd_addr_q,
    input  logic [31:0]       rd_data
);
    // ---------------- write ----------------
    assign req_wr        = s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid;
    assign s_axi_awready = req_wr;
    assign s_axi_wready  = req_wr;
    assign s_axi_bresp   = 2'b00;
    assign req_waddr     = s_axi_awaddr;
    assign req_wdata     = s_axi_wdata;
    assign req_wstrb     = s_axi_wstrb;

    always_ff @(posedge clk) begin
        if (~rst_n)          s_axi_bvalid <= 1'b0;
        else if (req_wr)     s_axi_bvalid <= 1'b1;
        else if (s_axi_bready) s_axi_bvalid <= 1'b0;
    end

    // ---------------- read ----------------
    typedef enum logic [1:0] {R_IDLE, R_WAIT, R_DATA} rstate_e;
    rstate_e rstate_q;

    assign s_axi_arready = (rstate_q == R_IDLE);
    assign req_rd        = s_axi_arvalid & s_axi_arready;
    assign req_raddr     = s_axi_araddr;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = (rstate_q == R_DATA);

    always_ff @(posedge clk) begin
        if (~rst_n) begin
            rstate_q    <= R_IDLE;
            rd_addr_q   <= '0;
            s_axi_rdata <= '0;
        end else begin
            unique case (rstate_q)
                R_IDLE: if (req_rd) begin
                            rd_addr_q <= s_axi_araddr;
                            rstate_q  <= R_WAIT;
                        end
                R_WAIT: begin
                            s_axi_rdata <= rd_data;
                            rstate_q    <= R_DATA;
                        end
                R_DATA: if (s_axi_rready) rstate_q <= R_IDLE;
                default: rstate_q <= R_IDLE;
            endcase
        end
    end

    // AxPROT is accepted and not used.
    logic unused;
    assign unused = ^{s_axi_awprot, s_axi_arprot};

endmodule : ocv_axil_slave
