// cva6_ocv_core.sv - CVA6 as the OCV core wrapper (gen/cpu_wrap.py, cva6.bind) takes a core: plain
// ports. Nothing of CVA6 is changed - this only instantiates it (as its own testbench's cva6_tb_wrapper
// does) and lays its structures out flat:
//   - the configuration: the official cv32a60x (TARGET_CFG) with what the platform needs changed, listed
//     in ocv_cfg() below;
//   - the AXI port (noc_req_o / noc_resp_i): 64-bit data, addresses cut to 32 bits (the map lies below 4 GiB);
//   - RVFI: cva6_rvfi (as the testbench) turns the core's probes into retirements; one commit port.
// The interrupt in RVFI: the interrupted instruction retires no record, the handler's first one carries
// intr[2]; the commit that takes it is seen on cva6_rvfi's trace port (an exception with cause[31]):
// irq_take, irq_cause - in that clock no instruction retires.
`include "rvfi_types.svh"

module cva6_ocv_core
    import ariane_pkg::*;
#(
    parameter logic [63:0] RAM_TOP = 64'h1000_0000     // cached, idempotent memory below; devices above
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] boot_addr_i,
    input  logic [31:0] irq_i,             // interrupt lines as mip: 3 software, 7 timer, 11 external
    // AXI4 master
    output logic [3:0]  axi_awid,
    output logic [31:0] axi_awaddr,
    output logic [7:0]  axi_awlen,
    output logic [2:0]  axi_awsize,
    output logic [1:0]  axi_awburst,
    output logic        axi_awvalid,
    input  logic        axi_awready,
    output logic [63:0] axi_wdata,
    output logic [7:0]  axi_wstrb,
    output logic        axi_wlast,
    output logic        axi_wvalid,
    input  logic        axi_wready,
    input  logic [3:0]  axi_bid,
    input  logic [1:0]  axi_bresp,
    input  logic        axi_bvalid,
    output logic        axi_bready,
    output logic [3:0]  axi_arid,
    output logic [31:0] axi_araddr,
    output logic [7:0]  axi_arlen,
    output logic [2:0]  axi_arsize,
    output logic [1:0]  axi_arburst,
    output logic        axi_arvalid,
    input  logic        axi_arready,
    input  logic [3:0]  axi_rid,
    input  logic [63:0] axi_rdata,
    input  logic [1:0]  axi_rresp,
    input  logic        axi_rlast,
    input  logic        axi_rvalid,
    output logic        axi_rready,
    // RVFI, flat (commit port 0)
    output logic        rvfi_valid,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,
    output logic [31:0] rvfi_cause,
    output logic [31:0] rvfi_intr,
    output logic [31:0] rvfi_pc_rdata,
    output logic [4:0]  rvfi_rd_addr,
    output logic [31:0] rvfi_rd_wdata,
    output logic [31:0] rvfi_mem_addr,
    output logic [3:0]  rvfi_mem_rmask,
    output logic [3:0]  rvfi_mem_wmask,
    output logic [31:0] rvfi_mem_rdata,
    output logic [31:0] rvfi_mem_wdata,
    output logic        irq_take,          // the core takes an interrupt (same timing as rvfi_*)
    output logic [31:0] irq_cause
);
    // the configuration: cv32a60x, changed where the platform needs it
    function automatic config_pkg::cva6_user_cfg_t ocv_cfg();
        config_pkg::cva6_user_cfg_t c = cva6_config_pkg::cva6_cfg;
        // no ASIC SRAM cut macros (TechnoCut: a black box outside an ASIC flow) - the caches' generic RAMs.
        // FpgaEn stays off: its register file is not reset (registers keep the last program's values - the
        // ISA leaves them unspecified, the model and core-v-verif's programs take them as 0)
        c.TechnoCut   = 1'b0;
        // the instruction set the reference models have: RV32IMC + Zicsr + Zifencei, machine mode
        c.RVB         = 1'b0;
        c.RVZCB       = 1'b0;
        // no coprocessor on CV-X-IF (the example one adds custom instructions)
        c.CvxifEn     = 1'b0;
        // no AXI user signals: nothing on the platform uses them
        c.DataUserEn  = 0;
        c.FetchUserEn = 0;
        // the map: RAM from 0 (cached), the device windows above (not idempotent: no speculative reads)
        c.NrCachedRegionRules      = 1;
        c.CachedRegionAddrBase     = '0;
        c.CachedRegionLength       = '0;
        c.CachedRegionLength[0]    = RAM_TOP;
        c.NrNonIdempotentRules     = 1;
        c.NonIdempotentAddrBase    = '0;
        c.NonIdempotentLength      = '0;
        c.NonIdempotentAddrBase[0] = RAM_TOP;
        c.NonIdempotentLength[0]   = 64'h1_0000_0000 - RAM_TOP;
        return c;
    endfunction
    localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(ocv_cfg());

    localparam type rvfi_instr_t        = `RVFI_INSTR_T(CVA6Cfg);
    localparam type rvfi_csr_elmt_t     = `RVFI_CSR_ELMT_T(CVA6Cfg);
    localparam type rvfi_csr_t          = `RVFI_CSR_T(CVA6Cfg, rvfi_csr_elmt_t);
    localparam type rvfi_to_iti_t       = `RVFI_TO_ITI_T(CVA6Cfg);
    localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
    localparam type rvfi_probes_csr_t   = `RVFI_PROBES_CSR_T(CVA6Cfg);
    localparam type rvfi_probes_t = struct packed {
        rvfi_probes_csr_t   csr;
        rvfi_probes_instr_t instr;
    };

    // the AXI types as cva6 declares them by default
    localparam type axi_aw_chan_t = struct packed {
        logic [CVA6Cfg.AxiIdWidth-1:0]   id;
        logic [CVA6Cfg.AxiAddrWidth-1:0] addr;
        axi_pkg::len_t                   len;
        axi_pkg::size_t                  size;
        axi_pkg::burst_t                 burst;
        logic                            lock;
        axi_pkg::cache_t                 cache;
        axi_pkg::prot_t                  prot;
        axi_pkg::qos_t                   qos;
        axi_pkg::region_t                region;
        axi_pkg::atop_t                  atop;
        logic [CVA6Cfg.AxiUserWidth-1:0] user;
    };
    localparam type axi_ar_chan_t = struct packed {
        logic [CVA6Cfg.AxiIdWidth-1:0]   id;
        logic [CVA6Cfg.AxiAddrWidth-1:0] addr;
        axi_pkg::len_t                   len;
        axi_pkg::size_t                  size;
        axi_pkg::burst_t                 burst;
        logic                            lock;
        axi_pkg::cache_t                 cache;
        axi_pkg::prot_t                  prot;
        axi_pkg::qos_t                   qos;
        axi_pkg::region_t                region;
        logic [CVA6Cfg.AxiUserWidth-1:0] user;
    };
    localparam type axi_w_chan_t = struct packed {
        logic [CVA6Cfg.AxiDataWidth-1:0]     data;
        logic [(CVA6Cfg.AxiDataWidth/8)-1:0] strb;
        logic                                last;
        logic [CVA6Cfg.AxiUserWidth-1:0]     user;
    };
    localparam type b_chan_t = struct packed {
        logic [CVA6Cfg.AxiIdWidth-1:0]   id;
        axi_pkg::resp_t                  resp;
        logic [CVA6Cfg.AxiUserWidth-1:0] user;
    };
    localparam type r_chan_t = struct packed {
        logic [CVA6Cfg.AxiIdWidth-1:0]   id;
        logic [CVA6Cfg.AxiDataWidth-1:0] data;
        axi_pkg::resp_t                  resp;
        logic                            last;
        logic [CVA6Cfg.AxiUserWidth-1:0] user;
    };
    localparam type noc_req_t = struct packed {
        axi_aw_chan_t aw;
        logic         aw_valid;
        axi_w_chan_t  w;
        logic         w_valid;
        logic         b_ready;
        axi_ar_chan_t ar;
        logic         ar_valid;
        logic         r_ready;
    };
    localparam type noc_resp_t = struct packed {
        logic    aw_ready;
        logic    ar_ready;
        logic    w_ready;
        logic    b_valid;
        b_chan_t b;
        logic    r_valid;
        r_chan_t r;
    };

    noc_req_t     req;
    noc_resp_t    resp;
    rvfi_probes_t probes;
    rvfi_instr_t [CVA6Cfg.NrCommitPorts-1:0] rvfi;
    rvfi_csr_t    rvfi_csr;
    rvfi_to_iti_t rvfi_iti;

    cva6 #(
        .CVA6Cfg             (CVA6Cfg),
        .rvfi_probes_instr_t (rvfi_probes_instr_t),
        .rvfi_probes_csr_t   (rvfi_probes_csr_t),
        .rvfi_probes_t       (rvfi_probes_t),
        .axi_ar_chan_t       (axi_ar_chan_t),
        .axi_aw_chan_t       (axi_aw_chan_t),
        .axi_w_chan_t        (axi_w_chan_t),
        .b_chan_t            (b_chan_t),
        .r_chan_t            (r_chan_t),
        .noc_req_t           (noc_req_t),
        .noc_resp_t          (noc_resp_t)
    ) i_cva6 (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .boot_addr_i   (CVA6Cfg.VLEN'(boot_addr_i)),
        .hart_id_i     ('0),
        .irq_i         ({1'b0, irq_i[11]}),
        .ipi_i         (irq_i[3]),
        .time_irq_i    (irq_i[7]),
        .debug_req_i   (1'b0),
        .rvfi_probes_o (probes),
        .cvxif_req_o   (),
        .cvxif_resp_i  ('0),
        .noc_req_o     (req),
        .noc_resp_i    (resp)
    );

    cva6_rvfi #(
        .CVA6Cfg             (CVA6Cfg),
        .rvfi_instr_t        (rvfi_instr_t),
        .rvfi_csr_t          (rvfi_csr_t),
        .rvfi_probes_instr_t (rvfi_probes_instr_t),
        .rvfi_probes_csr_t   (rvfi_probes_csr_t),
        .rvfi_probes_t       (rvfi_probes_t),
        .rvfi_to_iti_t       (rvfi_to_iti_t)
    ) i_cva6_rvfi (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .rvfi_probes_i (probes),
        .rvfi_instr_o  (rvfi),
        .rvfi_to_iti_o (rvfi_iti),
        .rvfi_csr_o    (rvfi_csr)
    );

    // AXI, flat
    assign axi_awid    = req.aw.id;
    assign axi_awaddr  = req.aw.addr[31:0];
    assign axi_awlen   = req.aw.len;
    assign axi_awsize  = req.aw.size;
    assign axi_awburst = req.aw.burst;
    assign axi_awvalid = req.aw_valid;
    assign axi_wdata   = req.w.data;
    assign axi_wstrb   = req.w.strb;
    assign axi_wlast   = req.w.last;
    assign axi_wvalid  = req.w_valid;
    assign axi_bready  = req.b_ready;
    assign axi_arid    = req.ar.id;
    assign axi_araddr  = req.ar.addr[31:0];
    assign axi_arlen   = req.ar.len;
    assign axi_arsize  = req.ar.size;
    assign axi_arburst = req.ar.burst;
    assign axi_arvalid = req.ar_valid;
    assign axi_rready  = req.r_ready;
    always_comb begin
        resp          = '0;
        resp.aw_ready = axi_awready;
        resp.ar_ready = axi_arready;
        resp.w_ready  = axi_wready;
        resp.b_valid  = axi_bvalid;
        resp.b.id     = axi_bid;
        resp.b.resp   = axi_bresp;
        resp.r_valid  = axi_rvalid;
        resp.r.id     = axi_rid;
        resp.r.data   = axi_rdata;
        resp.r.resp   = axi_rresp;
        resp.r.last   = axi_rlast;
    end

    // RVFI, flat
    assign rvfi_valid     = rvfi[0].valid;
    assign rvfi_insn      = rvfi[0].insn;
    assign rvfi_trap      = rvfi[0].trap;
    assign rvfi_cause     = rvfi[0].cause;
    assign rvfi_intr      = rvfi[0].intr;
    assign rvfi_pc_rdata  = rvfi[0].pc_rdata;
    assign rvfi_rd_addr   = rvfi[0].rd_addr;
    assign rvfi_rd_wdata  = rvfi[0].rd_wdata;
    assign rvfi_mem_addr  = rvfi[0].mem_addr;
    assign rvfi_mem_rmask = rvfi[0].mem_rmask;
    assign rvfi_mem_wmask = rvfi[0].mem_wmask;
    assign rvfi_mem_rdata = rvfi[0].mem_rdata;
    assign rvfi_mem_wdata = rvfi[0].mem_wdata;

    // the interrupt: at the commit that takes it (ITI: an exception with cause[31])
    assign irq_take  = rvfi_iti.ex_valid && rvfi_iti.cause[31];
    assign irq_cause = rvfi_iti.cause;
endmodule : cva6_ocv_core
