// ocv_cva6_cov_top.sv - CVA6's own functional coverage (core-v-verif: the isacov agent's covergroups and
// uvme_cva6_cov_model_c's), fed with RVFI records the reference model wrote (uvm/cov/ocv_cov_feed.c) in
// place of a simulated core. The testbench's classes as they are: its configuration (uvme_cva6_cfg_c,
// randomized and set from the core's configuration as its base test does), its agent and models, connected
// as uvme_cva6_env_c::connect_coverage_model connects them.
//   +OCV_RVFI=<file>     the records
//   +OCV_FIRST=<file>    also the records that hit a bin for the first time: "<record> <new bins>" (each record
//                        sampled before the next: slower) - how few records a filter has to keep
//   +OCV_CHECK=<file>    what isacov's monitor and coverage model made of each record (each record sampled before
//                        the next: slower): a line "cfg <flag>=<v>..." (the flags of isacov's sample() branches),
//                        then per record "<history moved> <raw_hazard> <csr_hazard>" and the value of every
//                        coverpoint expression and condition reading only the transaction (ocv_cov_fields.svh,
//                        tools/cov/cov_fields.py --sv) - the filter's fields checked by tools/cov/cov_check.py
`include "uvm_macros.svh"
module ocv_cva6_cov_top;
    import uvm_pkg::*;
    import uvma_rvfi_pkg::*;
    import uvma_core_cntrl_pkg::*;
    import uvma_isacov_pkg::*;
    import uvme_cva6_pkg::*;
    import uvma_cva6pkg_utils_pkg::*;
    import uvml_hrtbt_pkg::*;

    import "DPI-C" function int ocv_cov_open(string file);
    import "DPI-C" function int ocv_cov_next(output longint unsigned f[16]);
    import "DPI-C" function longint unsigned vl_covergroup_first_hits();
    import "DPI-C" function void vl_covergroup_enable(int on);
`include "ocv_cov_fields.svh"

    // the monitor's last transaction (check mode)
    class ocv_cov_tap extends uvm_subscriber#(uvma_isacov_mon_trn_c);
        `uvm_component_utils(ocv_cov_tap)
        uvma_isacov_mon_trn_c last;
        function new(string name = "ocv_cov_tap", uvm_component parent = null);
            super.new(name, parent);
        endfunction
        function void write(uvma_isacov_mon_trn_c t);
            last = t;
        endfunction
    endclass

    class ocv_cva6_cov_test extends uvm_test;
        `uvm_component_utils(ocv_cva6_cov_test)
        uvme_cva6_cfg_c                  cfg;
        uvme_cva6_cntxt_c                cntxt;
        uvma_isacov_agent_c#(ILEN, XLEN) isacov_agent;
        uvme_cva6_cov_model_c            cov_model;
        ocv_cov_tap                      tap;
        longint unsigned                 records;

        function new(string name = "ocv_cva6_cov_test", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            st_core_cntrl_cfg st;
            super.build_phase(phase);
            cfg = uvme_cva6_cfg_c::type_id::create("cfg");
            if (!cfg.randomize()) `uvm_fatal("OCV", "cannot randomize the configuration")
            // as uvmt_cva6_base_test_c::pkg_to_cfg
            st = cfg.to_struct();
            st = cva6pkg_to_core_cntrl_cfg(st);
            cfg.from_struct(st);
            cfg.post_randomize();
            uvml_default_hrtbt.enabled = 0;     // as uvmt_cva6_base_test_c::cfg_hrtbt_monitor
            cntxt = uvme_cva6_cntxt_c::type_id::create("cntxt");
            uvm_config_db#(uvma_isacov_cfg_c)::set(this, "*isacov_agent", "cfg", cfg.isacov_cfg);
            uvm_config_db#(uvme_cva6_cfg_c)::set(this, "cov_model", "cfg", cfg);
            uvm_config_db#(uvme_cva6_cntxt_c)::set(this, "cov_model", "cntxt", cntxt);
            isacov_agent = uvma_isacov_agent_c#(ILEN, XLEN)::type_id::create("isacov_agent", this);
            cov_model = uvme_cva6_cov_model_c::type_id::create("cov_model", this);
            tap = ocv_cov_tap::type_id::create("tap", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            // as uvme_cva6_env_c::connect_coverage_model (the RVFI agent's port is this test)
            if (cfg.isacov_cfg.cov_model_enabled) begin
                isacov_agent.monitor.ap.connect(cov_model.isa_covg.mon_trn_fifo.analysis_export);
                isacov_agent.monitor.ap.connect(cov_model.illegal_covg.mon_trn_fifo.analysis_export);
                isacov_agent.monitor.ap.connect(cov_model.exception_covg.mon_trn_fifo.analysis_export);
            end
            if (cfg.interrupt_cfg.cov_model_enabled)
                isacov_agent.monitor.ap.connect(cov_model.interrupt_covg.mon_trn_fifo.analysis_export);
            isacov_agent.monitor.ap.connect(tap.analysis_export);
        endfunction

        function uvma_rvfi_csr_seq_item_c#(XLEN) csr(longint unsigned v);
            csr = new("csr");
            csr.wdata = v;
            csr.rdata = v;
        endfunction

        task run_phase(uvm_phase phase);
            longint unsigned f[16], hits, h;
            longint unsigned contexts = 0;
            string file, first, check;
            int fd = 0, fc = 0;
            uvma_isacov_instr_c p;
            phase.raise_objection(this);
            if (!$value$plusargs("OCV_RVFI=%s", file)) `uvm_fatal("OCV", "+OCV_RVFI=<records> missing")
            if (ocv_cov_open(file) != 0) `uvm_fatal("OCV", {"cannot open ", file})
            if ($value$plusargs("OCV_FIRST=%s", first)) fd = $fopen(first, "w");
            if ($value$plusargs("OCV_CHECK=%s", check)) begin
                fc = $fopen(check, "w");
                $fwrite(fc, "%s\n", ocv_cov_cfg(cfg.isacov_cfg.core_cfg));
            end
            hits = vl_covergroup_first_hits();
            while (ocv_cov_next(f)) begin
                uvma_rvfi_instr_seq_item_c#(ILEN, XLEN) it = new("rvfi");
                it.insn = f[0]; it.pc_rdata = f[1]; it.trap = f[2];
                it.rs1_addr = f[3]; it.rs1_rdata = f[4]; it.rs2_addr = f[5]; it.rs2_rdata = f[6];
                it.rd1_addr = f[7]; it.rd1_wdata = f[8]; it.mem_addr = f[9]; it.intr = f[10];
                it.mode = UVMA_RVFI_M_MODE;
                it.name_csrs["mcause"] = csr(f[11]);
                it.name_csrs["mstatus"] = csr(f[12]);
                it.name_csrs["mie"] = csr(f[13]);
                it.name_csrs["mip"] = csr(f[14]);
                if (f[15] != 0) begin
                    // a context record: the models take it (their state) with no covergroup sampling
                    #1;                               // (the records before it sampled first)
                    vl_covergroup_enable(0);
                    isacov_agent.monitor.write_rvfi_instr(it);
                    #1;
                    vl_covergroup_enable(1);
                    contexts++;
                    continue;
                end
                p = isacov_agent.cov_model.instr_prev;
                isacov_agent.monitor.write_rvfi_instr(it);
                records++;
                if (fc != 0) begin
                    #1;                           // isacov's model has taken this record
                    $fwrite(fc, "%0d %0d %0d%s\n", isacov_agent.cov_model.instr_prev == tap.last.instr,
                            isacov_agent.cov_model.is_raw_hazard(tap.last.instr, p),
                            isacov_agent.cov_model.is_csr_hazard(tap.last.instr, p), ocv_cov_fields(tap.last.instr));
                end
                if (fd != 0) begin
                    #1;                           // every model has sampled this record
                    h = vl_covergroup_first_hits();
                    if (h != hits) $fwrite(fd, "%0d %0d\n", records - 1, h - hits);
                    hits = h;
                end else if (records % 4096 == 0) #1;   // (the models take their fifos' items)
            end
            #10;
            if (fd != 0) $fclose(fd);
            if (fc != 0) $fclose(fc);
            `uvm_info("OCV", $sformatf("%0d RVFI records sampled, %0d context records", records, contexts), UVM_LOW)
            phase.drop_objection(this);
        endtask
    endclass

    initial run_test("ocv_cva6_cov_test");
endmodule
