// cva6_c_pkg.sv - a UVM test of CVA6 written by the OCV contract (uvm/ocv_uvm_pkg.sv, the rules in its header): the
// core under OCV's wrapper (gen/cpu_wrap.py) is reached only through cva6_if; each channel has its transaction
// (extends ocv_item) and its driver (ocv_source_driver, drive()) or monitor (ocv_monitor, sample()); a sequence loads
// the program, a responder answers the core's device reads as the test's devices; the scoreboard is an
// ocv_model_checker - every record of every channel against the reference model of the core
// (models/cpu/ocv_cpu_model.c). The same files run in simulation (the RTL) and on the board (the core in the FPGA).
//   +PROG=<file.hex>              program image ($readmemh bytes, "@addr" sections)
//   +OCV_MODEL="key=value ..."    model options (default "irq=0": the test drives no interrupts)
`include "uvm_macros.svh"

package cva6_c_pkg;
    import uvm_pkg::*;
    import ocv_uvm_pkg::*;

    class program_item extends ocv_item;
        `uvm_object_utils(program_item)
        bit [29:0]   addr;
        bit [31:0]   data;
        bit          last;
        function new(string name = "program_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("addr=0x%0h data=0x%0h last=0x%0h", addr, data, last); endfunction
    endclass
    class program_driver extends ocv_source_driver #(program_item);
        `uvm_component_utils(program_driver)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(program_item t);
            vif.prog_valid <= 1'b1;
            vif.prog_addr <= t.addr;
            vif.prog_data <= t.data;
            vif.prog_last <= t.last;
            do @(posedge vif.clk); while (!vif.prog_ready);
            vif.prog_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(program_item, program_driver) program_agent;

    class issue_item extends ocv_item;
        `uvm_object_utils(issue_item)
        bit [31:0]   pc;
        bit [31:0]   insn;
        bit          c;
        function new(string name = "issue_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("pc=0x%0h insn=0x%0h c=0x%0h", pc, insn, c); endfunction
    endclass
    class issue_monitor extends ocv_monitor #(issue_item);
        `uvm_component_utils(issue_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output issue_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.issue_valid));
            t = issue_item::type_id::create("t");
            t.pc = vif.issue_pc;
            t.insn = vif.issue_insn;
            t.c = vif.issue_c;
        endtask
    endclass
    typedef ocv_output_agent #(issue_item, issue_monitor) issue_agent;

    class regw_item extends ocv_item;
        `uvm_object_utils(regw_item)
        bit [4:0]    rd;
        bit [31:0]   data;
        function new(string name = "regw_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("rd=0x%0h data=0x%0h", rd, data); endfunction
    endclass
    class regw_monitor extends ocv_monitor #(regw_item);
        `uvm_component_utils(regw_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output regw_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.regw_valid));
            t = regw_item::type_id::create("t");
            t.rd = vif.regw_rd;
            t.data = vif.regw_data;
        endtask
    endclass
    typedef ocv_output_agent #(regw_item, regw_monitor) regw_agent;

    class store_item extends ocv_item;
        `uvm_object_utils(store_item)
        bit [31:0]   addr;
        bit [3:0]    be;
        bit [31:0]   data;
        function new(string name = "store_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("addr=0x%0h be=0x%0h data=0x%0h", addr, be, data); endfunction
    endclass
    class store_monitor extends ocv_monitor #(store_item);
        `uvm_component_utils(store_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output store_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.store_valid));
            t = store_item::type_id::create("t");
            t.addr = vif.store_addr;
            t.be = vif.store_be;
            t.data = vif.store_data;
        endtask
    endclass
    typedef ocv_output_agent #(store_item, store_monitor) store_agent;

    class irq_item extends ocv_item;
        `uvm_object_utils(irq_item)
        bit [31:0]   cause;
        bit [63:0]   seq;
        bit [63:0]   cycle;
        function new(string name = "irq_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("cause=0x%0h seq=0x%0h cycle=0x%0h", cause, seq, cycle); endfunction
    endclass
    class irq_monitor extends ocv_monitor #(irq_item);
        `uvm_component_utils(irq_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output irq_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.irq_valid));
            t = irq_item::type_id::create("t");
            t.cause = vif.irq_cause;
            t.seq = vif.irq_seq;
            t.cycle = vif.irq_cycle;
        endtask
    endclass
    typedef ocv_output_agent #(irq_item, irq_monitor) irq_agent;

    class csrr_item extends ocv_item;
        `uvm_object_utils(csrr_item)
        bit [31:0]   data;
        function new(string name = "csrr_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("data=0x%0h", data); endfunction
    endclass
    class csrr_monitor extends ocv_monitor #(csrr_item);
        `uvm_component_utils(csrr_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output csrr_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.csrr_valid));
            t = csrr_item::type_id::create("t");
            t.data = vif.csrr_data;
        endtask
    endclass
    typedef ocv_output_agent #(csrr_item, csrr_monitor) csrr_agent;

    class proto_item extends ocv_item;
        `uvm_object_utils(proto_item)
        bit [31:0]   value;
        bit [63:0]   cycle;
        function new(string name = "proto_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("value=0x%0h cycle=0x%0h", value, cycle); endfunction
    endclass
    class proto_monitor extends ocv_monitor #(proto_item);
        `uvm_component_utils(proto_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output proto_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.proto_valid));
            t = proto_item::type_id::create("t");
            t.value = vif.proto_value;
            t.cycle = vif.proto_cycle;
        endtask
    endclass
    typedef ocv_output_agent #(proto_item, proto_monitor) proto_agent;

    class dev_req_item extends ocv_item;
        `uvm_object_utils(dev_req_item)
        bit [7:0]    dev;
        bit [31:0]   addr;
        bit          we;
        bit [3:0]    be;
        bit [31:0]   wdata;
        bit [63:0]   cycle;
        function new(string name = "dev_req_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("dev=0x%0h addr=0x%0h we=0x%0h be=0x%0h wdata=0x%0h cycle=0x%0h", dev, addr, we, be, wdata, cycle); endfunction
    endclass
    class dev_req_monitor extends ocv_monitor #(dev_req_item);
        `uvm_component_utils(dev_req_monitor)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output dev_req_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.dev_req_valid));
            t = dev_req_item::type_id::create("t");
            t.dev = vif.dev_req_dev;
            t.addr = vif.dev_req_addr;
            t.we = vif.dev_req_we;
            t.be = vif.dev_req_be;
            t.wdata = vif.dev_req_wdata;
            t.cycle = vif.dev_req_cycle;
        endtask
    endclass
    typedef ocv_output_agent #(dev_req_item, dev_req_monitor) dev_req_agent;

    class dev_resp_item extends ocv_item;
        `uvm_object_utils(dev_resp_item)
        bit [31:0]   rdata;
        function new(string name = "dev_resp_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("rdata=0x%0h", rdata); endfunction
    endclass
    class dev_resp_driver extends ocv_source_driver #(dev_resp_item);
        `uvm_component_utils(dev_resp_driver)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(dev_resp_item t);
            vif.dev_resp_valid <= 1'b1;
            vif.dev_resp_rdata <= t.rdata;
            do @(posedge vif.clk); while (!vif.dev_resp_ready);
            vif.dev_resp_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(dev_resp_item, dev_resp_driver) dev_resp_agent;
    class in_irq_i_item extends ocv_item;
        `uvm_object_utils(in_irq_i_item)
        bit [63:0]   until_cycle;   // (the DUT's 'until': a keyword in SystemVerilog)
        bit [31:0]   value;
        function new(string name = "in_irq_i_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("until=0x%0h value=0x%0h", until_cycle, value); endfunction
    endclass
    class in_irq_i_driver extends ocv_source_driver #(in_irq_i_item);
        `uvm_component_utils(in_irq_i_driver)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(in_irq_i_item t);
            vif.in_irq_i_valid <= 1'b1;
            vif.in_irq_i_until <= t.until_cycle;
            vif.in_irq_i_value <= t.value;
            do @(posedge vif.clk); while (!vif.in_irq_i_ready);
            vif.in_irq_i_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(in_irq_i_item, in_irq_i_driver) in_irq_i_agent;

    class cfg_lat_item extends ocv_item;
        `uvm_object_utils(cfg_lat_item)
        bit [31:0]   seed;
        bit [7:0]    gnt;
        bit [7:0]    rsp;
        function new(string name = "cfg_lat_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("seed=0x%0h gnt=0x%0h rsp=0x%0h", seed, gnt, rsp); endfunction
    endclass
    class cfg_lat_driver extends ocv_source_driver #(cfg_lat_item);
        `uvm_component_utils(cfg_lat_driver)
        virtual cva6_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual cva6_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(cfg_lat_item t);
            vif.cfg_lat_valid <= 1'b1;
            vif.cfg_lat_seed <= t.seed;
            vif.cfg_lat_gnt <= t.gnt;
            vif.cfg_lat_rsp <= t.rsp;
            do @(posedge vif.clk); while (!vif.cfg_lat_ready);
            vif.cfg_lat_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(cfg_lat_item, cfg_lat_driver) cfg_lat_agent;

    // ---------------- the program: the image's non-zero words, `last` on the final one starts the core ----------------
    class load_seq extends uvm_sequence #(program_item);
        `uvm_object_utils(load_seq)
        bit [7:0]    image[4194304];             // 4 MiB: the RAM and the stack (cva6.bind)
        int unsigned words[$];
        function new(string name = "load_seq"); super.new(name); endfunction
        function void read(string file);
            $readmemh(file, image);
            words.delete();
            for (int w = 0; w < 1048576; w++)
                if ({image[4*w+3], image[4*w+2], image[4*w+1], image[4*w]} != 0) words.push_back(w);
        endfunction
        task body();
            foreach (words[i]) begin
                program_item t = program_item::type_id::create("t");
                const int unsigned w = words[i];
                start_item(t);
                t.addr = 30'(w);
                t.data = {image[4*w+3], image[4*w+2], image[4*w+1], image[4*w]};
                t.last = (i == words.size() - 1);
                finish_item(t);
            end
        endtask
    endclass

    // ---------------- the core's other inputs, set once per program: the interrupt lines' schedule and the memory's
    // delays (this test: no interrupt, ever; no delays) ----------------
    class inputs_seq extends uvm_sequence #(in_irq_i_item);
        `uvm_object_utils(inputs_seq)
        function new(string name = "inputs_seq"); super.new(name); endfunction
        task body();
            in_irq_i_item t = in_irq_i_item::type_id::create("t");
            start_item(t);
            t.until_cycle = '1;                        // the lines' value holds until this clock count: forever
            t.value = 0;
            finish_item(t);
        endtask
    endclass
    class lat_seq extends uvm_sequence #(cfg_lat_item);
        `uvm_object_utils(lat_seq)
        function new(string name = "lat_seq"); super.new(name); endfunction
        task body();
            cfg_lat_item t = cfg_lat_item::type_id::create("t");
            start_item(t);
            t.seed = 0; t.gnt = 0; t.rsp = 0;      // no random delays
            finish_item(t);
        endtask
    endclass

    // ---------------- the test's devices: printer (writes print), the rest read as 0 ----------------
    class dev_resp_seq extends uvm_sequence #(dev_resp_item);
        `uvm_object_utils(dev_resp_seq)
        bit [31:0] rdata;
        function new(string name = "dev_resp_seq"); super.new(name); endfunction
        task body();
            dev_resp_item t = dev_resp_item::type_id::create("t");
            start_item(t);
            t.rdata = rdata;
            finish_item(t);
        endtask
    endclass

    class cva6_env extends uvm_env;
        `uvm_component_utils(cva6_env)
        program_agent prog;
        issue_agent   issue;
        regw_agent    regw;
        store_agent   store;
        irq_agent     irq;
        csrr_agent    csrr;
        proto_agent   proto;
        dev_req_agent dev_req;
        dev_resp_agent dev_resp;
        in_irq_i_agent in_irq;
        cfg_lat_agent  lat;
        ocv_model_checker chk;
        uvm_tlm_analysis_fifo #(dev_req_item) dev_fifo;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            prog     = program_agent::type_id::create("prog", this);
            issue    = issue_agent::type_id::create("issue", this);
            regw     = regw_agent::type_id::create("regw", this);
            store    = store_agent::type_id::create("store", this);
            irq      = irq_agent::type_id::create("irq", this);
            csrr     = csrr_agent::type_id::create("csrr", this);
            proto    = proto_agent::type_id::create("proto", this);
            dev_req  = dev_req_agent::type_id::create("dev_req", this);
            dev_resp = dev_resp_agent::type_id::create("dev_resp", this);
            in_irq   = in_irq_i_agent::type_id::create("in_irq", this);
            lat      = cfg_lat_agent::type_id::create("lat", this);
            chk      = ocv_model_checker::type_id::create("chk", this);
            chk.opts = "irq=0";                     // (+OCV_MODEL=... replaces it)
            dev_fifo = new("dev_fifo", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            dev_req.ap.connect(dev_fifo.analysis_export);
        endfunction
        // answer the core's device requests: a write is posted, a read gets the test's value
        task respond();
            forever begin
                dev_req_item r;
                dev_fifo.get(r);
                if (r.we) begin
                    if (r.dev == 0) $write("%c", r.wdata[7:0]);        // the printer
                end else begin
                    dev_resp_seq s = dev_resp_seq::type_id::create("s");
                    s.rdata = 0;
                    s.start(dev_resp.sqr);
                end
            end
        endtask
    endclass

    class cva6_prog_test extends uvm_test;
        `uvm_component_utils(cva6_prog_test)
        cva6_env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            e = cva6_env::type_id::create("e", this);
        endfunction
        task run_phase(uvm_phase phase);
            load_seq seq = load_seq::type_id::create("seq");
            string file;
            if (!$value$plusargs("PROG=%s", file)) `uvm_fatal("TEST", "give +PROG=<program.hex>")
            phase.raise_objection(this);
            seq.read(file);
            if (seq.words.size() == 0) `uvm_fatal("TEST", $sformatf("%s: no program (file missing or empty)", file))
            `uvm_info("TEST", $sformatf("%s: %0d words", file, seq.words.size()), UVM_LOW)
            fork e.respond(); join_none
            // (alongside the load: the wrapper takes the lines' schedule only while the core runs)
            fork
                begin
                    lat_seq l = lat_seq::type_id::create("l");
                    l.start(e.lat.sqr);
                end
                begin
                    inputs_seq i = inputs_seq::type_id::create("i");
                    i.start(e.in_irq.sqr);
                end
            join_none
            seq.start(e.prog.sqr);
            wait (e.chk.done || e.chk.n_errors > 10);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
