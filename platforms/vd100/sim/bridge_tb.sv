/// bridge_tb - the VD100 PS -> hub path without the board: the real SmartConnect of the platform
/// (bridge_bd, same cell as on the board) in front of a generated OCV environment, driven by the
/// unmodified PS program (runner + DUT model, C over DPI) through an AXI4 master that accesses the
/// bus like the A72 does through mmap(/dev/mem): single 32-bit transfers on the 128-bit M_AXI_LPD,
/// data and strobes in the lane of address bits [3:2].
///
/// Plusargs: +ARGS=<runner options, comma separated>  +JITTER=<0..100>  (% chance of a one-cycle stall per phase)
/// The environment module is chosen with the OCV_ENV macro.
`timescale 1ns/1ps
module bridge_tb;
    localparam logic [43:0] BASE = 44'h0_8000_0000;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;                              // 100 MHz, as the board default

    // M_AXI_LPD side (AXI4, 128-bit data, 44-bit address, 16-bit ID)
    logic [43:0]  awaddr, araddr;
    logic [7:0]   awlen = 0, arlen = 0;
    logic [2:0]   awsize = 3'd2, arsize = 3'd2, awprot = 0, arprot = 0;
    logic [1:0]   awburst = 2'b01, arburst = 2'b01;
    logic [15:0]  awid = 0, arid = 0, awuser = 0, aruser = 0;
    logic [3:0]   awcache = 0, arcache = 0, awqos = 0, arqos = 0;
    logic         awlock = 0, arlock = 0;
    logic         awvalid = 0, awready, wvalid = 0, wready, wlast = 1, bvalid, bready = 0;
    logic         arvalid = 0, arready, rvalid, rready = 0, rlast;
    logic [127:0] wdata, rdata;
    logic [15:0]  wstrb;
    logic [1:0]   bresp, rresp;
    logic [15:0]  bid, rid;

    // hub side (AXI4-Lite)
    logic [31:0] h_awaddr, h_araddr, h_wdata, h_rdata;
    logic [2:0]  h_awprot, h_arprot;
    logic [3:0]  h_wstrb;
    logic [1:0]  h_bresp, h_rresp;
    logic        h_awvalid, h_awready, h_wvalid, h_wready, h_bvalid, h_bready;
    logic        h_arvalid, h_arready, h_rvalid, h_rready;

    bridge_bd_wrapper i_bd (
        .clk, .rst_n,
        .S_AXI_awaddr(awaddr), .S_AXI_awlen(awlen), .S_AXI_awsize(awsize), .S_AXI_awburst(awburst),
        .S_AXI_awlock(awlock), .S_AXI_awcache(awcache), .S_AXI_awprot(awprot), .S_AXI_awqos(awqos),
        .S_AXI_awid(awid), .S_AXI_awuser(awuser), .S_AXI_awvalid(awvalid), .S_AXI_awready(awready),
        .S_AXI_wdata(wdata), .S_AXI_wstrb(wstrb), .S_AXI_wlast(wlast), .S_AXI_wvalid(wvalid),
        .S_AXI_wready(wready), .S_AXI_bid(bid), .S_AXI_bresp(bresp), .S_AXI_bvalid(bvalid),
        .S_AXI_bready(bready),
        .S_AXI_araddr(araddr), .S_AXI_arlen(arlen), .S_AXI_arsize(arsize), .S_AXI_arburst(arburst),
        .S_AXI_arlock(arlock), .S_AXI_arcache(arcache), .S_AXI_arprot(arprot), .S_AXI_arqos(arqos),
        .S_AXI_arid(arid), .S_AXI_aruser(aruser), .S_AXI_arvalid(arvalid), .S_AXI_arready(arready),
        .S_AXI_rid(rid), .S_AXI_rdata(rdata), .S_AXI_rresp(rresp), .S_AXI_rlast(rlast),
        .S_AXI_rvalid(rvalid), .S_AXI_rready(rready),
        .M_AXI_awaddr(h_awaddr), .M_AXI_awprot(h_awprot), .M_AXI_awvalid(h_awvalid),
        .M_AXI_awready(h_awready), .M_AXI_wdata(h_wdata), .M_AXI_wstrb(h_wstrb),
        .M_AXI_wvalid(h_wvalid), .M_AXI_wready(h_wready), .M_AXI_bresp(h_bresp),
        .M_AXI_bvalid(h_bvalid), .M_AXI_bready(h_bready),
        .M_AXI_araddr(h_araddr), .M_AXI_arprot(h_arprot), .M_AXI_arvalid(h_arvalid),
        .M_AXI_arready(h_arready), .M_AXI_rdata(h_rdata), .M_AXI_rresp(h_rresp),
        .M_AXI_rvalid(h_rvalid), .M_AXI_rready(h_rready)
    );

    `OCV_ENV i_env (
        .clk, .rst_n,
        .s_axi_awaddr (h_awaddr[`OCV_AW-1:0]), .s_axi_awprot (h_awprot), .s_axi_awvalid (h_awvalid),
        .s_axi_awready (h_awready), .s_axi_wdata (h_wdata), .s_axi_wstrb (h_wstrb),
        .s_axi_wvalid (h_wvalid), .s_axi_wready (h_wready), .s_axi_bresp (h_bresp),
        .s_axi_bvalid (h_bvalid), .s_axi_bready (h_bready),
        .s_axi_araddr (h_araddr[`OCV_AW-1:0]), .s_axi_arprot (h_arprot), .s_axi_arvalid (h_arvalid),
        .s_axi_arready (h_arready), .s_axi_rdata (h_rdata), .s_axi_rresp (h_rresp),
        .s_axi_rvalid (h_rvalid), .s_axi_rready (h_rready)
    );

    // ---------------- A72-like master, called from C ----------------
    int jitter = 0, n_rd = 0, n_wr = 0, errors = 0;
    task automatic stall();
        while ($urandom_range(99) < jitter) @(posedge clk);
    endtask

    export "DPI-C" task sv_wr32;
    task automatic sv_wr32(input int off, input int data);
        logic [1:0] lane = off[3:2];
        stall();
        @(posedge clk);
        awaddr <= BASE + 44'(unsigned'(off)); awvalid <= 1;
        wdata <= {4{data}}; wstrb <= 16'hF << (4 * lane); wvalid <= 1;
        fork
            begin do @(posedge clk); while (!awready); awvalid <= 0; end
            begin do @(posedge clk); while (!wready);  wvalid <= 0; end
        join
        stall();
        bready <= 1;
        do @(posedge clk); while (!bvalid);
        bready <= 0;
        if (bresp != 2'b00) begin
            $display("BRIDGE: write 0x%0h got BRESP %0d", off, bresp); errors++;
        end
        n_wr++;
    endtask

    export "DPI-C" task sv_rd32;
    task automatic sv_rd32(input int off, output int data);
        logic [1:0] lane = off[3:2];
        stall();
        @(posedge clk);
        araddr <= BASE + 44'(unsigned'(off)); arvalid <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        stall();
        rready <= 1;
        do @(posedge clk); while (!rvalid);
        rready <= 0;
        data = rdata[32 * lane +: 32];
        if (rresp != 2'b00 || !rlast) begin
            $display("BRIDGE: read 0x%0h got RRESP %0d RLAST %0d", off, rresp, rlast); errors++;
        end
        n_rd++;
    endtask

    import "DPI-C" context task ocv_dpi_main(input string args, output int rc);

    initial begin
        string args;
        int rc;
        if (!$value$plusargs("ARGS=%s", args)) args = "--info";
        void'($value$plusargs("JITTER=%d", jitter));
        repeat (20) @(posedge clk);
        rst_n <= 1;
        repeat (20) @(posedge clk);
        ocv_dpi_main(args, rc);
        $display("BRIDGE: runner exit %0d, %0d reads, %0d writes, %0d bus errors, %0t",
                 rc, n_rd, n_wr, errors, $time);
        $display("BRIDGE_RESULT: %s", (rc == 0 && errors == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule : bridge_tb
