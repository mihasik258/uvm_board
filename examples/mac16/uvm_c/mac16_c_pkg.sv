// mac16_c_pkg.sv - the UVM test of mac16 written by the OCV contract (uvm/ocv_uvm_pkg.sv, the rules in its header):
// the DUT is reached only through mac16_if (examples/mac16/uvm_v/mac16_if.sv); operands have a transaction and a
// driver (op_item, ocv_source_driver), results and products a transaction and a monitor each (res_item, prod_item,
// ocv_monitor); the scoreboard is an ocv_model_checker - every result and product against the reference model in C
// (examples/mac16/mac16_model.c). The same files run in simulation (the RTL) and on the board (the DUT in the FPGA).
// It is the test of examples/mac16/uvm_v (random operands, edge values often, a clear 1 in 16) without its
// scoreboard in SystemVerilog.
//   +N=<operands>   (default 1000)
//   +PKT=<k>        operands per UVM transaction (default 1): k randomised operands go to the driver as one item
//                   (ocv_item's block, add_record) - the length of a transaction, for the curve of FOCUS 4.10
//   +SEED=<n>       the random seed
`include "uvm_macros.svh"

package mac16_c_pkg;
    import uvm_pkg::*;
    import ocv_uvm_pkg::*;

    // ---------------- operands ----------------
    class op_item extends ocv_item;
        `uvm_object_utils(op_item)
        rand bit signed [15:0] a;
        rand bit signed [15:0] b;
        rand bit               clr;
        constraint c_edges {
            a dist { -32768 := 1, 32767 := 1, 0 := 1, [-32767:32766] :/ 17 };
            b dist { -32768 := 1, 32767 := 1, 0 := 1, [-32767:32766] :/ 17 };
            clr dist { 1 := 1, 0 := 15 };
        }
        function new(string name = "op_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("a=%0d b=%0d clr=%0d", a, b, clr); endfunction
    endclass
    class op_driver extends ocv_source_driver #(op_item);
        `uvm_component_utils(op_driver)
        virtual mac16_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(op_item t);
            wait (vif.rst_n);                   // (the DUT takes no transfer in reset: its ready is not held low there)
            vif.s_valid <= 1'b1;
            vif.s_a <= t.a;
            vif.s_b <= t.b;
            vif.s_clr <= t.clr;
            do @(posedge vif.clk); while (!vif.s_ready);
            vif.s_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(op_item, op_driver) op_agent;

    // ---------------- results (the testbench always takes them: tb_top) ----------------
    class res_item extends ocv_item;
        `uvm_object_utils(res_item)
        bit signed [39:0] acc;
        function new(string name = "res_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("acc=%0d", acc); endfunction
    endclass
    class res_monitor extends ocv_monitor #(res_item);
        `uvm_component_utils(res_monitor)
        virtual mac16_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output res_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.m_valid && vif.m_ready));
            t = res_item::type_id::create("t");
            t.acc = vif.m_acc;                  // (m_ts, a timestamp, is not part of the result)
        endtask
    endclass
    typedef ocv_output_agent #(res_item, res_monitor) res_agent;

    // ---------------- products (the observation port) ----------------
    class prod_item extends ocv_item;
        `uvm_object_utils(prod_item)
        bit signed [31:0] prod;
        function new(string name = "prod_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("prod=%0d", prod); endfunction
    endclass
    class prod_monitor extends ocv_monitor #(prod_item);
        `uvm_component_utils(prod_monitor)
        virtual mac16_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual mac16_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output prod_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.dbg_valid));
            t = prod_item::type_id::create("t");
            t.prod = vif.dbg_prod;
        endtask
    endclass
    typedef ocv_output_agent #(prod_item, prod_monitor) prod_agent;

    // n random operands, pkt of them per transaction
    class rand_seq extends uvm_sequence #(op_item);
        `uvm_object_utils(rand_seq)
        int unsigned n = 1000;
        int unsigned pkt = 1;
        function new(string name = "rand_seq"); super.new(name); endfunction
        task body();
            op_item one = op_item::type_id::create("one");
            for (int unsigned i = 0; i < n; i += pkt) begin
                op_item t = op_item::type_id::create("t");
                start_item(t);
                if (pkt == 1) begin
                    if (!t.randomize()) `uvm_fatal("SEQ", "randomize failed")
                end else
                    for (int unsigned k = 0; k < pkt && i + k < n; k++) begin
                        if (!one.randomize()) `uvm_fatal("SEQ", "randomize failed")
                        t.add_record(one);
                    end
                finish_item(t);
            end
        endtask
    endclass

    class mac16_env extends uvm_env;
        `uvm_component_utils(mac16_env)
        op_agent   op;
        res_agent  res;
        prod_agent prod;
        ocv_model_checker chk;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            op   = op_agent::type_id::create("op", this);
            res  = res_agent::type_id::create("res", this);
            prod = prod_agent::type_id::create("prod", this);
            chk  = ocv_model_checker::type_id::create("chk", this);
        endfunction
    endclass

    class mac16_rand_test extends uvm_test;
        `uvm_component_utils(mac16_rand_test)
        mac16_env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); e = mac16_env::type_id::create("e", this); endfunction
        task run_phase(uvm_phase phase);
            rand_seq seq = rand_seq::type_id::create("seq");
            int unsigned seed = 1;
            void'($value$plusargs("N=%d", seq.n));
            void'($value$plusargs("PKT=%d", seq.pkt));
            void'($value$plusargs("SEED=%d", seed));
            if (seq.pkt == 0) seq.pkt = 1;
            seq.srandom(seed);
            `uvm_info("TEST", $sformatf("%0d operands, %0d per transaction", seq.n, seq.pkt), UVM_LOW)
            phase.raise_objection(this);
            seq.start(e.op.sqr);
            e.chk.finish();
            phase.drop_objection(this);
        endtask
    endclass
endpackage
