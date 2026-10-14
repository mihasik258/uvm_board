/// scr1_ocv_dut - SCR1 as an OCV DUT: the core, 64 KiB of program RAM behind its AXI ports, a
/// program loader and the committed-instruction (RVFI-lite) stream.
///
/// Run protocol, driven only through the two OCV channels:
///   1. after reset the core is held in reset and the RAM accepts `prog_*` records
///      (word address, data, last) - the program image, loaded by the PS as stimulus;
///   2. the record with prog_last releases the core, which starts at the reset vector (0x200);
///   3. every retired instruction appears on `rvfi_*`, with what it wrote: rd, a store (`rvfi_mem_*`),
///      a CSR (`rvfi_csrw_*`) - as RVFI's rvfi_mem_* / rvfi_csr_*;
///   4. the program ends by jumping to SIM_EXIT (0xF8, the SCR1 test convention): the retirement
///      that leaves for 0xF8 is the last record, then the core is held in reset again.
///
/// Memory map as seen by the core (default SCR1 configuration): RAM here at [0, 64 KiB); TCM
/// (0x0048_0000) and timer (0x0049_0000) are inside scr1_top_axi; every other address is
/// accepted on AXI, writes are dropped and reads return 0 (e.g. the console port 0xF000_0000).
///
/// Build with SCR1_RVFI_EN (raw retire stream) and the SCR1 configuration defines.
`include "scr1_arch_description.svh"

module scr1_ocv_dut (
    input  logic         clk,
    input  logic         rst_n,
    // program loader (OCV source channel)
    input  logic         prog_valid,
    output logic         prog_ready,
    input  logic [13:0]  prog_addr,      // word address
    input  logic [31:0]  prog_data,
    input  logic         prog_last,
    // committed instructions (OCV monitor channel)
    output logic         rvfi_valid,
    output logic [31:0]  rvfi_pc,
    output logic [31:0]  rvfi_pc_next,
    output logic [4:0]   rvfi_rd_addr,
    output logic [31:0]  rvfi_rd_wdata,
    output logic         rvfi_trap,
    output logic         rvfi_csr_rd,      // the instruction read a CSR ...
    output logic [11:0]  rvfi_csr_addr,    // ... this one (0 if none)
    output logic         rvfi_mem_we,      // a store ...
    output logic [3:0]   rvfi_mem_wmask,   // ... of these bytes from rvfi_mem_addr (0001 / 0011 / 1111)
    output logic [31:0]  rvfi_mem_addr,
    output logic [31:0]  rvfi_mem_wdata,   // bytes outside the mask 0
    output logic         rvfi_csrw_we,     // a CSR write ...
    output logic [1:0]   rvfi_csrw_cmd,    // ... 0 write, 1 set bits, 2 clear bits
    output logic [11:0]  rvfi_csrw_addr,
    output logic [31:0]  rvfi_csrw_data    // the operand (rs1 or uimm)
);
    localparam int unsigned AW        = 14;             // 16 Ki words = 64 KiB
    localparam logic [31:0] SIM_EXIT  = 32'h0000_00F8;

    //------------------------------------------------------------------
    // Run control: LOAD -> RUN -> HALT (until the next DUT reset)
    //------------------------------------------------------------------
    typedef enum logic [1:0] {LOAD, RUN, HALT} state_e;
    state_e       state_q;
    logic         core_valid;
    logic [127:0] core_rec, core_ext;

    assign prog_ready = (state_q == LOAD);

    always_ff @(posedge clk) begin
        if (~rst_n) state_q <= LOAD;
        else unique case (state_q)
            LOAD:    if (prog_valid && prog_last) state_q <= RUN;
            RUN:     if (core_valid && core_rec[63:32] == SIM_EXIT) state_q <= HALT;
            default: ;
        endcase
    end

    // the retire port is registered: the core's retire strobe comes through a deep path (EXU, the
    // multiplier, the trap logic), which must end at a flip-flop, not at the channel's buffer
    logic         ret_q;
    logic [127:0] rec_q, ext_q;
    always_ff @(posedge clk) begin
        ret_q <= rst_n & core_valid & (state_q == RUN);
        rec_q <= core_rec;
        ext_q <= core_ext;
    end
    assign rvfi_valid    = ret_q;
    assign rvfi_pc       = rec_q[31:0];
    assign rvfi_pc_next  = rec_q[63:32];
    assign rvfi_rd_wdata = rec_q[95:64];
    assign rvfi_rd_addr  = rec_q[100:96];
    assign rvfi_trap     = rec_q[101];
    assign rvfi_csr_rd   = rec_q[102];
    assign rvfi_csr_addr = rec_q[114:103];
    assign rvfi_mem_we    = ext_q[0];
    assign rvfi_mem_wmask = ext_q[4:1];
    assign rvfi_mem_addr  = ext_q[36:5];
    assign rvfi_mem_wdata = ext_q[68:37];
    assign rvfi_csrw_we   = ext_q[69];
    assign rvfi_csrw_cmd  = ext_q[71:70];
    assign rvfi_csrw_data = ext_q[103:72];
    assign rvfi_csrw_addr = ext_q[115:104];
    logic unused_rec;
    assign unused_rec = ^{rec_q[127:115], ext_q[127:116]};   // reserved bits of the RVFI-lite record

    //------------------------------------------------------------------
    // Program RAM: port A = instruction fetch (and the loader while the core is in reset),
    //              port B = data.
    //------------------------------------------------------------------
    logic          a_en, b_en, i_en;
    logic [3:0]    a_we, b_we, i_we;
    logic [AW-1:0] a_addr, b_addr, i_addr;
    logic [31:0]   a_wdata, b_wdata, i_wdata, a_rdata, b_rdata;

    assign a_en    = (state_q == LOAD) ? (prog_valid & prog_ready) : i_en;
    assign a_we    = (state_q == LOAD) ? {4{prog_valid & prog_ready}} : i_we;
    assign a_addr  = (state_q == LOAD) ? prog_addr : i_addr;
    assign a_wdata = (state_q == LOAD) ? prog_data : i_wdata;

    (* ram_style = "block" *) logic [31:0] ram [0:(1<<AW)-1];
    always_ff @(posedge clk) if (a_en) begin
        for (int i = 0; i < 4; i++) if (a_we[i]) ram[a_addr][8*i +: 8] <= a_wdata[8*i +: 8];
        a_rdata <= ram[a_addr];
    end
    always_ff @(posedge clk) if (b_en) begin
        for (int i = 0; i < 4; i++) if (b_we[i]) ram[b_addr][8*i +: 8] <= b_wdata[8*i +: 8];
        b_rdata <= ram[b_addr];
    end

    //------------------------------------------------------------------
    // SCR1
    //------------------------------------------------------------------
    // AXI instruction port (read only) and data port
    logic [3:0]  im_awid, im_arid, im_rid, im_bid, dm_awid, dm_arid, dm_rid, dm_bid;
    logic [31:0] im_awaddr, im_araddr, im_wdata, im_rdata, dm_awaddr, dm_araddr, dm_wdata, dm_rdata;
    logic [7:0]  im_awlen, im_arlen, dm_awlen, dm_arlen;
    logic [1:0]  im_awburst, im_arburst, dm_awburst, dm_arburst, im_bresp, im_rresp, dm_bresp, dm_rresp;
    logic [3:0]  im_wstrb, dm_wstrb;
    logic        im_awvalid, im_awready, im_wvalid, im_wready, im_wlast, im_bvalid, im_bready;
    logic        im_arvalid, im_arready, im_rvalid, im_rready, im_rlast;
    logic        dm_awvalid, dm_awready, dm_wvalid, dm_wready, dm_wlast, dm_bvalid, dm_bready;
    logic        dm_arvalid, dm_arready, dm_rvalid, dm_rready, dm_rlast;

    logic        core_rst_n;
    assign core_rst_n = rst_n & (state_q == RUN);

    scr1_top_axi i_scr1 (
        .pwrup_rst_n            (rst_n),
        .rst_n                  (rst_n),
        .cpu_rst_n              (core_rst_n),
        .test_mode              (1'b0),
        .test_rst_n             (1'b1),
        .clk                    (clk),
        .rtc_clk                (1'b0),
`ifdef SCR1_DBG_EN
        .sys_rst_n_o            (),
        .sys_rdc_qlfy_o         (),
`endif
        .fuse_mhartid           ('0),
`ifdef SCR1_DBG_EN
        .fuse_idcode            (`SCR1_TAP_IDCODE),
`endif
`ifdef SCR1_IPIC_EN
        .irq_lines              ('0),
`else
        .ext_irq                (1'b0),
`endif
        .soft_irq               (1'b0),
`ifdef SCR1_DBG_EN
        .trst_n                 (1'b0),       // debug TAP held in reset
        .tck                    (1'b0),
        .tms                    (1'b0),
        .tdi                    (1'b0),
        .tdo                    (),
        .tdo_en                 (),
`endif
        // instruction memory
        .io_axi_imem_awid       (im_awid),    .io_axi_imem_awaddr     (im_awaddr),
        .io_axi_imem_awlen      (im_awlen),   .io_axi_imem_awsize     (),
        .io_axi_imem_awburst    (im_awburst), .io_axi_imem_awlock     (),
        .io_axi_imem_awcache    (),           .io_axi_imem_awprot     (),
        .io_axi_imem_awregion   (),           .io_axi_imem_awuser     (),
        .io_axi_imem_awqos      (),           .io_axi_imem_awvalid    (im_awvalid),
        .io_axi_imem_awready    (im_awready), .io_axi_imem_wdata      (im_wdata),
        .io_axi_imem_wstrb      (im_wstrb),   .io_axi_imem_wlast      (im_wlast),
        .io_axi_imem_wuser      (),           .io_axi_imem_wvalid     (im_wvalid),
        .io_axi_imem_wready     (im_wready),  .io_axi_imem_bid        (im_bid),
        .io_axi_imem_bresp      (im_bresp),   .io_axi_imem_bvalid     (im_bvalid),
        .io_axi_imem_buser      ('0),         .io_axi_imem_bready     (im_bready),
        .io_axi_imem_arid       (im_arid),    .io_axi_imem_araddr     (im_araddr),
        .io_axi_imem_arlen      (im_arlen),   .io_axi_imem_arsize     (),
        .io_axi_imem_arburst    (im_arburst), .io_axi_imem_arlock     (),
        .io_axi_imem_arcache    (),           .io_axi_imem_arprot     (),
        .io_axi_imem_arregion   (),           .io_axi_imem_aruser     (),
        .io_axi_imem_arqos      (),           .io_axi_imem_arvalid    (im_arvalid),
        .io_axi_imem_arready    (im_arready), .io_axi_imem_rid        (im_rid),
        .io_axi_imem_rdata      (im_rdata),   .io_axi_imem_rresp      (im_rresp),
        .io_axi_imem_rlast      (im_rlast),   .io_axi_imem_ruser      ('0),
        .io_axi_imem_rvalid     (im_rvalid),  .io_axi_imem_rready     (im_rready),
        // data memory
        .io_axi_dmem_awid       (dm_awid),    .io_axi_dmem_awaddr     (dm_awaddr),
        .io_axi_dmem_awlen      (dm_awlen),   .io_axi_dmem_awsize     (),
        .io_axi_dmem_awburst    (dm_awburst), .io_axi_dmem_awlock     (),
        .io_axi_dmem_awcache    (),           .io_axi_dmem_awprot     (),
        .io_axi_dmem_awregion   (),           .io_axi_dmem_awuser     (),
        .io_axi_dmem_awqos      (),           .io_axi_dmem_awvalid    (dm_awvalid),
        .io_axi_dmem_awready    (dm_awready), .io_axi_dmem_wdata      (dm_wdata),
        .io_axi_dmem_wstrb      (dm_wstrb),   .io_axi_dmem_wlast      (dm_wlast),
        .io_axi_dmem_wuser      (),           .io_axi_dmem_wvalid     (dm_wvalid),
        .io_axi_dmem_wready     (dm_wready),  .io_axi_dmem_bid        (dm_bid),
        .io_axi_dmem_bresp      (dm_bresp),   .io_axi_dmem_bvalid     (dm_bvalid),
        .io_axi_dmem_buser      ('0),         .io_axi_dmem_bready     (dm_bready),
        .io_axi_dmem_arid       (dm_arid),    .io_axi_dmem_araddr     (dm_araddr),
        .io_axi_dmem_arlen      (dm_arlen),   .io_axi_dmem_arsize     (),
        .io_axi_dmem_arburst    (dm_arburst), .io_axi_dmem_arlock     (),
        .io_axi_dmem_arcache    (),           .io_axi_dmem_arprot     (),
        .io_axi_dmem_arregion   (),           .io_axi_dmem_aruser     (),
        .io_axi_dmem_arqos      (),           .io_axi_dmem_arvalid    (dm_arvalid),
        .io_axi_dmem_arready    (dm_arready), .io_axi_dmem_rid        (dm_rid),
        .io_axi_dmem_rdata      (dm_rdata),   .io_axi_dmem_rresp      (dm_rresp),
        .io_axi_dmem_rlast      (dm_rlast),   .io_axi_dmem_ruser      ('0),
        .io_axi_dmem_rvalid     (dm_rvalid),  .io_axi_dmem_rready     (dm_rready),
        // retire stream (the old capture ports are for the board build, not used here)
        .rvfi_trace_we_o        (),
        .rvfi_trace_waddr_o     (),
        .rvfi_trace_wdata_o     (),
        .rvfi_trace_count_o     (),
        .rvfi_valid_o           (core_valid),
        .rvfi_rec_o             (core_rec),
        .rvfi_ext_o             (core_ext)
    );

    scr1_ocv_axi_mem #(.AW(AW), .WRITE_EN(1'b0)) i_imem (
        .clk, .rst_n,
        .awid (im_awid), .awaddr (im_awaddr), .awlen (im_awlen), .awburst (im_awburst),
        .awvalid (im_awvalid), .awready (im_awready),
        .wdata (im_wdata), .wstrb (im_wstrb), .wlast (im_wlast), .wvalid (im_wvalid), .wready (im_wready),
        .bid (im_bid), .bresp (im_bresp), .bvalid (im_bvalid), .bready (im_bready),
        .arid (im_arid), .araddr (im_araddr), .arlen (im_arlen), .arburst (im_arburst),
        .arvalid (im_arvalid), .arready (im_arready),
        .rid (im_rid), .rdata (im_rdata), .rresp (im_rresp), .rlast (im_rlast),
        .rvalid (im_rvalid), .rready (im_rready),
        .ram_en (i_en), .ram_we (i_we), .ram_addr (i_addr), .ram_wdata (i_wdata), .ram_rdata (a_rdata)
    );

    scr1_ocv_axi_mem #(.AW(AW), .WRITE_EN(1'b1)) i_dmem (
        .clk, .rst_n,
        .awid (dm_awid), .awaddr (dm_awaddr), .awlen (dm_awlen), .awburst (dm_awburst),
        .awvalid (dm_awvalid), .awready (dm_awready),
        .wdata (dm_wdata), .wstrb (dm_wstrb), .wlast (dm_wlast), .wvalid (dm_wvalid), .wready (dm_wready),
        .bid (dm_bid), .bresp (dm_bresp), .bvalid (dm_bvalid), .bready (dm_bready),
        .arid (dm_arid), .araddr (dm_araddr), .arlen (dm_arlen), .arburst (dm_arburst),
        .arvalid (dm_arvalid), .arready (dm_arready),
        .rid (dm_rid), .rdata (dm_rdata), .rresp (dm_rresp), .rlast (dm_rlast),
        .rvalid (dm_rvalid), .rready (dm_rready),
        .ram_en (b_en), .ram_we (b_we), .ram_addr (b_addr), .ram_wdata (b_wdata), .ram_rdata (b_rdata)
    );

endmodule : scr1_ocv_dut
