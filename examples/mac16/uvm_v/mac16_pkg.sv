// mac16_pkg.sv - a UVM testbench for mac16 written the usual way: transactions, a driver and
// monitors on the pins (mac16_if), agents, a random sequence, a scoreboard with the reference
// model in SystemVerilog fed by the input monitor, in-order comparison of both outputs.
//   +N=<operands> (default 1000)
`include "uvm_macros.svh"

package mac16_pkg;
    import uvm_pkg::*;

    `uvm_analysis_imp_decl(_op)
    `uvm_analysis_imp_decl(_res)
    `uvm_analysis_imp_decl(_prod)

    class op_item extends uvm_sequence_item;
        `uvm_object_utils(op_item)
        rand bit signed [15:0] a;
        rand bit signed [15:0] b;
        rand bit               clr;
        function new(string name = "op_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("a=%0d b=%0d clr=%0d", a, b, clr); endfunction
    endclass

    class res_item extends uvm_sequence_item;
        `uvm_object_utils(res_item)
        bit signed [39:0] acc;
        bit        [15:0] ts;
        function new(string name = "res_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("acc=%0d ts=%0d", acc, ts); endfunction
    endclass

    class prod_item extends uvm_sequence_item;
        `uvm_object_utils(prod_item)
        bit signed [31:0] prod;
        function new(string name = "prod_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("prod=%0d", prod); endfunction
    endclass

    // ---------------- operands: driver + input monitor ----------------
    class op_driver extends uvm_driver #(op_item);
        `uvm_component_utils(op_driver)
        virtual mac16_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            op_item t;
            vif.s_valid <= 1'b0;
            @(posedge vif.rst_n);
            forever begin
                seq_item_port.get_next_item(t);
                vif.s_valid <= 1'b1;
                vif.s_a     <= t.a;
                vif.s_b     <= t.b;
                vif.s_clr   <= t.clr;
                do @(posedge vif.clk); while (!vif.s_ready);
                vif.s_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class op_monitor extends uvm_monitor;
        `uvm_component_utils(op_monitor)
        virtual mac16_if vif;
        uvm_analysis_port #(op_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.s_valid && vif.s_ready) begin
                    op_item t = op_item::type_id::create("t");
                    t.a   = vif.s_a;
                    t.b   = vif.s_b;
                    t.clr = vif.s_clr;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class op_agent extends uvm_agent;
        `uvm_component_utils(op_agent)
        uvm_sequencer #(op_item) sqr;
        op_driver                drv;
        op_monitor               mon;
        uvm_analysis_port #(op_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = uvm_sequencer #(op_item)::type_id::create("sqr", this);
            drv = op_driver::type_id::create("drv", this);
            mon = op_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
            ap = mon.ap;
        endfunction
    endclass

    // ---------------- results (the testbench is always ready) ----------------
    class res_monitor extends uvm_monitor;
        `uvm_component_utils(res_monitor)
        virtual mac16_if vif;
        uvm_analysis_port #(res_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.m_valid && vif.m_ready) begin
                    res_item t = res_item::type_id::create("t");
                    t.acc = vif.m_acc;
                    t.ts  = vif.m_ts;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class res_agent extends uvm_agent;
        `uvm_component_utils(res_agent)
        res_monitor mon;
        uvm_analysis_port #(res_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); mon = res_monitor::type_id::create("mon", this); endfunction
        function void connect_phase(uvm_phase phase); ap = mon.ap; endfunction
    endclass

    // ---------------- products (observation port) ----------------
    class prod_monitor extends uvm_monitor;
        `uvm_component_utils(prod_monitor)
        virtual mac16_if vif;
        uvm_analysis_port #(prod_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.dbg_valid) begin
                    prod_item t = prod_item::type_id::create("t");
                    t.prod = vif.dbg_prod;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class prod_agent extends uvm_agent;
        `uvm_component_utils(prod_agent)
        prod_monitor mon;
        uvm_analysis_port #(prod_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); mon = prod_monitor::type_id::create("mon", this); endfunction
        function void connect_phase(uvm_phase phase); ap = mon.ap; endfunction
    endclass

    // random operands, edge values often; clr with probability 1/clr_one_in
    class rand_seq extends uvm_sequence #(op_item);
        `uvm_object_utils(rand_seq)
        int unsigned n = 1000;
        int unsigned clr_one_in = 16;
        function new(string name = "rand_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                op_item t = op_item::type_id::create("t");
                start_item(t);
                if (!t.randomize() with {
                        a dist { -32768 := 1, 32767 := 1, 0 := 1, [-32767:32766] :/ 17 };
                        b dist { -32768 := 1, 32767 := 1, 0 := 1, [-32767:32766] :/ 17 };
                        clr dist { 1 := 1, 0 := clr_one_in - 1 }; })
                    `uvm_fatal("SEQ", "randomize failed")
                finish_item(t);
            end
        endtask
    endclass

    // reference model of mac16 + in-order comparison of both outputs (ts is a timestamp: not compared)
    class scoreboard extends uvm_component;
        `uvm_component_utils(scoreboard)
        uvm_analysis_imp_op   #(op_item,   scoreboard) op_imp;
        uvm_analysis_imp_res  #(res_item,  scoreboard) res_imp;
        uvm_analysis_imp_prod #(prod_item, scoreboard) prod_imp;
        longint          acc;
        bit signed [39:0] exp_acc[$];
        bit signed [31:0] exp_prod[$];
        int unsigned     n_results, n_products, n_errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            op_imp = new("op_imp", this);
            res_imp = new("res_imp", this);
            prod_imp = new("prod_imp", this);
        endfunction

        function void write_op(op_item t);
            bit signed [31:0] p = 32'(t.a * t.b);
            acc = (t.clr ? 64'sd0 : acc) + longint'(p);
            acc = (acc <<< 24) >>> 24;                  // wrap to 40 bits, sign-extended
            exp_prod.push_back(p);
            exp_acc.push_back(acc[39:0]);
        endfunction

        function void write_res(res_item t);
            n_results++;
            if (exp_acc.size() == 0) begin n_errors++; `uvm_error("SB", $sformatf("unexpected result #%0d: %s", n_results, t.convert2string())) return; end
            if (t.acc != exp_acc[0]) begin
                n_errors++;
                `uvm_error("SB", $sformatf("MISMATCH result #%0d: dut %s, model acc=%0d", n_results, t.convert2string(), exp_acc[0]))
            end
            void'(exp_acc.pop_front());
        endfunction

        function void write_prod(prod_item t);
            n_products++;
            if (exp_prod.size() == 0) begin n_errors++; `uvm_error("SB", $sformatf("unexpected product #%0d: %s", n_products, t.convert2string())) return; end
            if (t.prod != exp_prod[0]) begin
                n_errors++;
                `uvm_error("SB", $sformatf("MISMATCH product #%0d: dut %s, model prod=%0d", n_products, t.convert2string(), exp_prod[0]))
            end
            void'(exp_prod.pop_front());
        endfunction

        function void check_phase(uvm_phase phase);
            if (exp_acc.size() || exp_prod.size())
                `uvm_error("SB", $sformatf("missing outputs: %0d results, %0d products never came", exp_acc.size(), exp_prod.size()))
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("%0d results, %0d products compared, %0d errors", n_results, n_products, n_errors), UVM_NONE)
        endfunction
    endclass

    class env extends uvm_env;
        `uvm_component_utils(env)
        op_agent   op;
        res_agent  res;
        prod_agent prod;
        scoreboard sb;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            op   = op_agent::type_id::create("op", this);
            res  = res_agent::type_id::create("res", this);
            prod = prod_agent::type_id::create("prod", this);
            sb   = scoreboard::type_id::create("sb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            op.ap.connect(sb.op_imp);
            res.ap.connect(sb.res_imp);
            prod.ap.connect(sb.prod_imp);
        endfunction
    endclass

    class rand_test extends uvm_test;
        `uvm_component_utils(rand_test)
        env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); e = env::type_id::create("e", this); endfunction
        task run_phase(uvm_phase phase);
            rand_seq seq = rand_seq::type_id::create("seq");
            void'($value$plusargs("N=%d", seq.n));
            phase.raise_objection(this);
            seq.start(e.op.sqr);
            wait (e.sb.n_results >= seq.n && e.sb.n_products >= seq.n);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
