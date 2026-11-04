// ibex_ocv_core.sv - Ibex (lowRISC) as the OCV core wrapper (gen/cpu_wrap.py, ibex.bind)
// takes a core: plain ports. Nothing of Ibex RTL is changed - this instantiates ibex_top
// and flattens its ports (same pattern as examples/cva6/cva6_ocv_core.sv).
`include "prim_assert.sv"

module ibex_ocv_core import ibex_pkg::*; (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] boot_addr_i,

    // OBI instruction interface
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,

    // OBI data interface
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [3:0]  data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,

    // RVFI, flat
    output logic        rvfi_valid,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,
    output logic [4:0]  rvfi_rd_addr,
    output logic [31:0] rvfi_rd_wdata,
    output logic [31:0] rvfi_pc_rdata,
    output logic [31:0] rvfi_pc_wdata,
    output logic [31:0] rvfi_mem_addr,
    output logic [3:0]  rvfi_mem_wmask,
    output logic [31:0] rvfi_mem_wdata
);

    ibex_top #(
        .RV32M(RV32MFast),
        .RV32B(RV32BNone),
        .RV32ZC(RV32ZcaZcbZcmp),
        .RegFile(RegFileFF),
        .ICache(1'b0),
        .SecureIbex(1'b0)
    ) u_ibex_top (
        .clk_i,
        .rst_ni,

        .test_en_i              (1'b1), // bypass clock gating during reset
        .ram_cfg_icache_tag_i   ('0),
        .ram_cfg_icache_tag_o   (),
        .ram_cfg_icache_data_i  ('0),
        .ram_cfg_icache_data_o  (),

        .cheriot_enable_i       (IbexMuBiOff),

        .hart_id_i              (32'h0),
        .boot_addr_i            (boot_addr_i),

        .trvk_heap_base_addr_i  (32'h0),

        .instr_req_o            (instr_req_o),
        .instr_gnt_i            (instr_gnt_i),
        .instr_rvalid_i         (instr_rvalid_i),
        .instr_addr_o           (instr_addr_o),
        .instr_rdata_i          (instr_rdata_i),
        .instr_rdata_intg_i     (7'h0),
        .instr_err_i            (1'b0),

        .data_req_o             (data_req_o),
        .data_gnt_i             (data_gnt_i),
        .data_rvalid_i          (data_rvalid_i),
        .data_we_o              (data_we_o),
        .data_be_o              (data_be_o),
        .data_addr_o            (data_addr_o),
        .data_wdata_o           (data_wdata_o),
        .data_wdata_intg_o      (),
        .data_tag_o             (),
        .data_rdata_i           (data_rdata_i),
        .data_rdata_intg_i      (7'h0),
        .data_tag_i             (1'b0),
        .data_err_i             (1'b0),

        .trvk_revbm_req_o       (),
        .trvk_revbm_gnt_i       (1'b0),
        .trvk_revbm_rvalid_i    (1'b0),
        .trvk_revbm_addr_o      (),
        .trvk_revbm_rdata_i     (32'h0),
        .trvk_revbm_rdata_intg_i(7'h0),
        .trvk_revbm_err_i       (1'b0),

        .irq_software_i         (1'b0),
        .irq_timer_i            (1'b0),
        .irq_external_i         (1'b0),
        .irq_fast_i             (15'b0),
        .irq_nm_i               (1'b0),

        .scramble_key_valid_i   (1'b0),
        .scramble_key_i         ('0),
        .scramble_nonce_i       ('0),
        .scramble_req_o         (),

        .debug_req_i            (1'b0),
        .crash_dump_o           (),
        .double_fault_seen_o    (),

`ifdef RVFI
        .rvfi_valid             (rvfi_valid),
        .rvfi_order             (),
        .rvfi_insn              (rvfi_insn),
        .rvfi_trap              (rvfi_trap),
        .rvfi_halt              (),
        .rvfi_intr              (),
        .rvfi_mode              (),
        .rvfi_ixl               (),
        .rvfi_rs1_addr          (),
        .rvfi_rs2_addr          (),
        .rvfi_rs3_addr          (),
        .rvfi_rs1_rdata         (),
        .rvfi_rs2_rdata         (),
        .rvfi_rs3_rdata         (),
        .rvfi_rs1_rcap          (),
        .rvfi_rs2_rcap          (),
        .rvfi_rd_wcap           (),
        .rvfi_rd_addr           (rvfi_rd_addr),
        .rvfi_rd_wdata          (rvfi_rd_wdata),
        .rvfi_pc_rdata          (rvfi_pc_rdata),
        .rvfi_pc_wdata          (rvfi_pc_wdata),
        .rvfi_mem_addr          (rvfi_mem_addr),
        .rvfi_mem_rmask         (),
        .rvfi_mem_wmask         (rvfi_mem_wmask),
        .rvfi_mem_rdata         (),
        .rvfi_mem_wdata         (rvfi_mem_wdata),
        .rvfi_mem_is_cap        (),
        .rvfi_mem_rcap          (),
        .rvfi_mem_wcap          (),
        .rvfi_ext_pre_mip       (),
        .rvfi_ext_post_mip      (),
        .rvfi_ext_nmi           (),
        .rvfi_ext_nmi_int       (),
        .rvfi_ext_debug_req     (),
        .rvfi_ext_debug_mode    (),
        .rvfi_ext_rf_wr_suppress(),
        .rvfi_ext_mcycle        (),
        .rvfi_ext_mhpmcounters  (),
        .rvfi_ext_mhpmcountersh (),
        .rvfi_ext_ic_scr_key_valid(),
        .rvfi_ext_irq_valid     (),
        .rvfi_ext_expanded_insn_valid(),
        .rvfi_ext_expanded_insn (),
        .rvfi_ext_expanded_insn_last(),
`endif

        .fetch_enable_i         (IbexMuBiOn),
        .mcounteren_writable_i  (IbexMuBiOff),
        .alert_minor_o          (),
        .alert_major_internal_o (),
        .alert_major_bus_o      (),
        .core_sleep_o           (),

        .scan_rst_ni            (1'b1),
        .lockstep_cmp_en_o      (),
        .data_req_shadow_o      ()
    );

endmodule
