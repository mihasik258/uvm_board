// otbn_kmac_ocv.sv - OpenTitan's OTBN (the big-number accelerator) with the KMAC it hashes through, as one DUT
// for OCV: the pair as Earl Grey connects them (earlgrey_pd_main.sv: OTBN on KMAC's application interface), the
// rest of the chip replaced by what the pair needs of it:
//   - the bus: one request/response port; the address's bit 16 picks the block (0: OTBN's registers, IMEM and
//     DMEM; 1: KMAC's registers), each behind its own TL-UL host adapter (the command integrity covers the
//     address, so the split is before the adapters); one request at a time
//   - entropy (EDN for OTBN's RND/URND and KMAC's masking) and OTBN's scrambling key (OTP): deterministic -
//     masking and scrambling, not results, depend on them (the same program gives the same results)
//   - life cycle: not escalated, no RMA; alerts: not acknowledged (an alert is a DUT output, alert_o)
//   - the key manager's sideloaded keys: none; KMAC's other application interfaces: idle
// OpenTitan's RTL as it is (ext/opentitan, Apache 2.0).
module otbn_kmac_ocv (
    input  logic        clk_i,
    input  logic        rst_ni,
    // the bus
    input  logic        req_valid_i,
    output logic        req_ready_o,
    input  logic        req_we_i,
    input  logic [31:0] req_addr_i,
    input  logic [31:0] req_wdata_i,
    input  logic [3:0]  req_be_i,
    output logic        rsp_valid_o,
    output logic [31:0] rsp_rdata_o,
    output logic        rsp_err_o,
    // interrupts and alerts
    output logic        intr_otbn_done_o,
    output logic        intr_kmac_err_o,
    output logic        alert_o
);
    import tlul_pkg::*;

    // ---- the bus: a host adapter per block ----
    localparam int N = 2;                       // 0: OTBN, 1: KMAC
    tl_h2d_t tl_h2d [N];
    tl_d2h_t tl_d2h [N];
    logic [N-1:0] gnt, valid, err;
    logic [31:0]  rdata [N];
    logic         busy_q;                       // a request is out, its response not back
    logic         sel;
    assign sel = req_addr_i[16];
    for (genvar i = 0; i < N; i++) begin : g_host
        tlul_adapter_host #(
            .MAX_REQS(1),
            .EnableDataIntgGen(1)
        ) u_host (
            .clk_i, .rst_ni,
            .req_i        (req_valid_i && !busy_q && sel == i[0]),
            .gnt_o        (gnt[i]),
            .addr_i       ({16'b0, req_addr_i[15:0]}),
            .we_i         (req_we_i),
            .wdata_i      (req_wdata_i),
            .wdata_intg_i ('0),
            .be_i         (req_be_i),
            .instr_type_i (prim_mubi_pkg::MuBi4False),
            .user_rsvd_i  ('0),
            .valid_o      (valid[i]),
            .rdata_o      (rdata[i]),
            .rdata_intg_o (),
            .err_o        (err[i]),
            .intg_err_o   (),
            .tl_o         (tl_h2d[i]),
            .tl_i         (tl_d2h[i])
        );
    end
    assign req_ready_o = !busy_q && (sel ? gnt[1] : gnt[0]);
    always_ff @(posedge clk_i or negedge rst_ni)
        if (!rst_ni) busy_q <= 1'b0;
        else if (req_valid_i && req_ready_o) busy_q <= 1'b1;
        else if (|valid) busy_q <= 1'b0;
    assign rsp_valid_o = |valid;
    assign rsp_rdata_o = valid[1] ? rdata[1] : rdata[0];
    assign rsp_err_o   = valid[1] ? err[1] : err[0];

    // ---- entropy: an EDN endpoint per requester, a 32-bit LFSR word one clock after the request ----
    edn_pkg::edn_req_t edn_req [3];             // 0: OTBN RND, 1: OTBN URND, 2: KMAC
    edn_pkg::edn_rsp_t edn_rsp [3];
    for (genvar i = 0; i < 3; i++) begin : g_edn
        logic        ack_q;
        logic [31:0] lfsr_q;
        always_ff @(posedge clk_i or negedge rst_ni)
            if (!rst_ni) begin
                ack_q  <= 1'b0;
                lfsr_q <= 32'h9e3779b9 ^ (32'h01000193 * (i + 1));
            end else begin
                ack_q <= edn_req[i].edn_req && !ack_q;
                if (ack_q) lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
            end
        assign edn_rsp[i] = '{edn_ack: ack_q, edn_fips: 1'b1, edn_bus: lfsr_q};
    end

    // ---- OTBN's scrambling key: a fixed key and nonce, acknowledged one clock after the request ----
    otp_ctrl_pkg::otbn_otp_key_req_t otp_req;
    logic otp_ack_q;
    always_ff @(posedge clk_i or negedge rst_ni)
        if (!rst_ni) otp_ack_q <= 1'b0;
        else otp_ack_q <= otp_req.req && !otp_ack_q;

    // ---- the pair ----
    kmac_pkg::app_req_t kmac_app_req;
    kmac_pkg::app_rsp_t kmac_app_rsp;
    prim_alert_pkg::alert_tx_t [1:0] otbn_alert, kmac_alert;

    otbn u_otbn (
        .clk_i, .rst_ni,
        .tl_i              (tl_h2d[0]),
        .tl_o              (tl_d2h[0]),
        .idle_o            (),
        .intr_done_o       (intr_otbn_done_o),
        .alert_rx_i        ({2{prim_alert_pkg::ALERT_RX_DEFAULT}}),
        .alert_tx_o        (otbn_alert),
        .lc_escalate_en_i  (lc_ctrl_pkg::Off),
        .lc_rma_req_i      (lc_ctrl_pkg::Off),
        .lc_rma_ack_o      (),
        .ram_cfg_imem_i    ('0),
        .ram_cfg_dmem_i    ('0),
        .ram_cfg_imem_o    (),
        .ram_cfg_dmem_o    (),
        .clk_edn_i         (clk_i),
        .rst_edn_ni        (rst_ni),
        .edn_rnd_o         (edn_req[0]),
        .edn_rnd_i         (edn_rsp[0]),
        .edn_urnd_o        (edn_req[1]),
        .edn_urnd_i        (edn_rsp[1]),
        .clk_otp_i         (clk_i),
        .rst_otp_ni        (rst_ni),
        .otbn_otp_key_o    (otp_req),
        .otbn_otp_key_i    ('{ack: otp_ack_q, key: 128'h48ecf6c738f0f108a5b08620695ffd4d,
                              nonce: 64'hf88c2578fa4cd123, seed_valid: 1'b1}),
        .keymgr_key_i      ('0),
        .kmac_data_o       (kmac_app_req),
        .kmac_data_i       (kmac_app_rsp)
    );

    // KMAC's four application interfaces as in Earl Grey (key manager, life cycle, ROM, OTBN): OTBN's is 3, the
    // others never request
    kmac_pkg::app_rsp_t [3:0] kmac_app_rsps;
    assign kmac_app_rsp = kmac_app_rsps[3];
    kmac u_kmac (
        .clk_i, .rst_ni,
        .rst_shadowed_ni   (rst_ni),
        .clk_edn_i         (clk_i),
        .rst_edn_ni        (rst_ni),
        .tl_i              (tl_h2d[1]),
        .tl_o              (tl_d2h[1]),
        .alert_rx_i        ({2{prim_alert_pkg::ALERT_RX_DEFAULT}}),
        .alert_tx_o        (kmac_alert),
        .keymgr_key_i      ('0),
        .app_i             ({kmac_app_req, {3{kmac_pkg::APP_REQ_DEFAULT}}}),
        .app_o             (kmac_app_rsps),
        .entropy_o         (edn_req[2]),
        .entropy_i         (edn_rsp[2]),
        .lc_escalate_en_i  (lc_ctrl_pkg::Off),
        .intr_kmac_done_o  (),
        .intr_fifo_empty_o (),
        .intr_kmac_err_o   (intr_kmac_err_o),
        .en_masking_o      (),
        .idle_o            ()
    );

    assign alert_o = otbn_alert[0].alert_p | otbn_alert[1].alert_p | kmac_alert[0].alert_p | kmac_alert[1].alert_p;
endmodule
