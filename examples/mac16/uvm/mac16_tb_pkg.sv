// mac16_tb_pkg.sv - a UVM testbench for mac16 as a verifier writes it: a sequence, a scoreboard
// with the reference model, an environment and a test. It uses the agents generated from
// mac16.json (mac16_ocv_uvm_pkg) and nothing board-specific: the same file runs in simulation and,
// built with +define+OCV_BOARD, on the board against mac16 in the FPGA.
`include "uvm_macros.svh"

package mac16_tb_pkg;
    import uvm_pkg::*;
    import ocv_uvm_pkg::*;
    import mac16_ocv_uvm_pkg::*;

    `uvm_analysis_imp_decl(_operands)
    `uvm_analysis_imp_decl(_results)
    `uvm_analysis_imp_decl(_products)

    // random operands, edge values often; clr with probability 1/clr_one_in
    class mac16_rand_seq extends uvm_sequence #(mac16_operands_item);
        `uvm_object_utils(mac16_rand_seq)
        int unsigned n = 1000;
        int unsigned clr_one_in = 16;
        function new(string name = "mac16_rand_seq"); super.new(name); endfunction
        task body();
            repeat (n) begin
                mac16_operands_item t = mac16_operands_item::type_id::create("t");
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

    // reference model of mac16 + in-order comparison of both outputs
    class mac16_scoreboard extends uvm_component;
        `uvm_component_utils(mac16_scoreboard)
        uvm_analysis_imp_operands #(mac16_operands_item, mac16_scoreboard) operands_imp;
        uvm_analysis_imp_results  #(mac16_results_item,  mac16_scoreboard) results_imp;
        uvm_analysis_imp_products #(mac16_products_item, mac16_scoreboard) products_imp;

        longint             acc;                    // model state: 40-bit accumulator
        mac16_results_item  exp_results[$];
        mac16_products_item exp_products[$];
        int unsigned        n_results, n_products, n_errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            operands_imp = new("operands_imp", this);
            results_imp  = new("results_imp", this);
            products_imp = new("products_imp", this);
        endfunction

        function void write_operands(mac16_operands_item t);
            mac16_results_item  r = mac16_results_item::type_id::create("exp");
            mac16_products_item p = mac16_products_item::type_id::create("exp");
            p.prod = 32'(t.a * t.b);
            acc = (t.clr ? 64'sd0 : acc) + longint'(p.prod);
            acc = (acc <<< 24) >>> 24;                  // wrap to 40 bits, sign-extended
            r.acc = acc[39:0];
            exp_products.push_back(p);
            exp_results.push_back(r);
        endfunction

        function void write_results(mac16_results_item t);
            n_results++;
            if (exp_results.size() == 0) begin
                n_errors++;
                `uvm_error("SB", $sformatf("unexpected result #%0d: %s", n_results, t.convert2string()))
                return;
            end
            compare_one("results", n_results, t.mismatch(exp_results[0]), t.convert2string(), exp_results[0].convert2string());
            void'(exp_results.pop_front());
        endfunction

        function void write_products(mac16_products_item t);
            n_products++;
            if (exp_products.size() == 0) begin
                n_errors++;
                `uvm_error("SB", $sformatf("unexpected product #%0d: %s", n_products, t.convert2string()))
                return;
            end
            compare_one("products", n_products, t.mismatch(exp_products[0]), t.convert2string(), exp_products[0].convert2string());
            void'(exp_products.pop_front());
        endfunction

        function void compare_one(string ch, int unsigned i, string field, string dut, string model);
            if (field == "") return;
            n_errors++;
            `uvm_error("SB", $sformatf("MISMATCH %s #%0d field '%s': dut %s, model %s", ch, i, field, dut, model))
        endfunction

        function void check_phase(uvm_phase phase);
            if (exp_results.size() || exp_products.size())
                `uvm_error("SB", $sformatf("missing outputs: %0d results, %0d products never came",
                                           exp_results.size(), exp_products.size()))
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("%0d results, %0d products compared, %0d errors",
                                      n_results, n_products, n_errors), UVM_NONE)
        endfunction
    endclass

    class mac16_env extends uvm_env;
        `uvm_component_utils(mac16_env)
        mac16_operands_agent operands;
        mac16_results_agent  results;
        mac16_products_agent products;
        mac16_scoreboard     sb;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            operands = mac16_operands_agent::type_id::create("operands", this);
            results  = mac16_results_agent::type_id::create("results", this);
            products = mac16_products_agent::type_id::create("products", this);
            sb       = mac16_scoreboard::type_id::create("sb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            operands.ap.connect(sb.operands_imp);
            results.ap.connect(sb.results_imp);
            products.ap.connect(sb.products_imp);
        endfunction
    endclass

    // +N=<operands> (default 1000); ends when every output is back
    class mac16_rand_test extends uvm_test;
        `uvm_component_utils(mac16_rand_test)
        mac16_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            env = mac16_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            mac16_rand_seq seq = mac16_rand_seq::type_id::create("seq");
            void'($value$plusargs("N=%d", seq.n));
            phase.raise_objection(this);
            seq.start(env.operands.sqr);
            wait (env.sb.n_results >= seq.n && env.sb.n_products >= seq.n);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
