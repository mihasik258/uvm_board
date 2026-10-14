// sha_pkg.sv - a UVM testbench for the SHA-256 core written the usual way: the reference model is
// SystemVerilog in the scoreboard (FIPS 180-4 compression, chained), fed by the input monitor.
//   +N=<blocks> (default 1000). Block 0 is "abc" padded: its digest is the standard test vector.
`include "uvm_macros.svh"

package sha_pkg;
    import uvm_pkg::*;

    `uvm_analysis_imp_decl(_blk)
    `uvm_analysis_imp_decl(_dig)

    class blk_item extends uvm_sequence_item;
        `uvm_object_utils(blk_item)
        bit [511:0] block;
        bit         init;
        function new(string name = "blk_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("init=%0d block=%h", init, block); endfunction
    endclass

    class dig_item extends uvm_sequence_item;
        `uvm_object_utils(dig_item)
        bit [255:0] digest;
        function new(string name = "dig_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("digest=%h", digest); endfunction
    endclass

    class blk_driver extends uvm_driver #(blk_item);
        `uvm_component_utils(blk_driver)
        virtual sha_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual sha_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            blk_item t;
            vif.in_valid <= 1'b0;
            @(posedge vif.rst_n);
            forever begin
                seq_item_port.get_next_item(t);
                vif.in_valid <= 1'b1;
                vif.in_block <= t.block;
                vif.in_init  <= t.init;
                do @(posedge vif.clk); while (!vif.in_ready);
                vif.in_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class blk_monitor extends uvm_monitor;
        `uvm_component_utils(blk_monitor)
        virtual sha_if vif;
        uvm_analysis_port #(blk_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual sha_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.in_valid && vif.in_ready) begin
                    blk_item t = blk_item::type_id::create("t");
                    t.block = vif.in_block;
                    t.init  = vif.in_init;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class blk_agent extends uvm_agent;
        `uvm_component_utils(blk_agent)
        uvm_sequencer #(blk_item) sqr;
        blk_driver                drv;
        blk_monitor               mon;
        uvm_analysis_port #(blk_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = uvm_sequencer #(blk_item)::type_id::create("sqr", this);
            drv = blk_driver::type_id::create("drv", this);
            mon = blk_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
            ap = mon.ap;
        endfunction
    endclass

    class dig_monitor extends uvm_monitor;
        `uvm_component_utils(dig_monitor)
        virtual sha_if vif;
        uvm_analysis_port #(dig_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual sha_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.out_valid) begin
                    dig_item t = dig_item::type_id::create("t");
                    t.digest = vif.out_digest;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class dig_agent extends uvm_agent;
        `uvm_component_utils(dig_agent)
        dig_monitor mon;
        uvm_analysis_port #(dig_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); mon = dig_monitor::type_id::create("mon", this); endfunction
        function void connect_phase(uvm_phase phase); ap = mon.ap; endfunction
    endclass

    // N blocks: the first is "abc" padded (a new message), then random blocks, a new message 1 in 8
    class blk_seq extends uvm_sequence #(blk_item);
        `uvm_object_utils(blk_seq)
        int unsigned n = 1000;
        function new(string name = "blk_seq"); super.new(name); endfunction
        task body();
            for (int i = 0; i < n; i++) begin
                blk_item t = blk_item::type_id::create("t");
                start_item(t);
                if (i == 0) begin
                    t.block = {32'h61626380, {14{32'h0}}, 32'h00000018};
                    t.init  = 1'b1;
                end else begin
                    for (int k = 0; k < 16; k++) t.block[32*k +: 32] = $urandom;
                    t.init = ($urandom_range(0, 7) == 0);
                end
                finish_item(t);
            end
        endtask
    endclass

    class scoreboard extends uvm_component;
        `uvm_component_utils(scoreboard)
        uvm_analysis_imp_blk #(blk_item, scoreboard) blk_imp;
        uvm_analysis_imp_dig #(dig_item, scoreboard) dig_imp;
        bit [31:0]   H [8];
        bit [255:0]  exp_q [$];
        int unsigned n, n_errors;
        bit          abc_ok;

        localparam bit [31:0] K [64] = '{
            32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5, 32'h3956c25b, 32'h59f111f1, 32'h923f82a4, 32'hab1c5ed5,
            32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3, 32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174,
            32'he49b69c1, 32'hefbe4786, 32'h0fc19dc6, 32'h240ca1cc, 32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
            32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7, 32'hc6e00bf3, 32'hd5a79147, 32'h06ca6351, 32'h14292967,
            32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13, 32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85,
            32'ha2bfe8a1, 32'ha81a664b, 32'hc24b8b70, 32'hc76c51a3, 32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
            32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5, 32'h391c0cb3, 32'h4ed8aa4a, 32'h5b9cca4f, 32'h682e6ff3,
            32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208, 32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2};

        function new(string name, uvm_component parent);
            super.new(name, parent);
            blk_imp = new("blk_imp", this);
            dig_imp = new("dig_imp", this);
        endfunction

        static function bit [31:0] rotr(bit [31:0] x, int s); return (x >> s) | (x << (32 - s)); endfunction

        // the expected digest: FIPS 180-4 compression of the block onto the chaining value
        function void write_blk(blk_item t);
            bit [31:0] w [64], a, b, c, d, e, f, g, h, t1, t2;
            if (t.init) H = '{32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
                              32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};
            for (int i = 0; i < 16; i++) w[i] = t.block[511 - 32*i -: 32];
            for (int i = 16; i < 64; i++)
                w[i] = (rotr(w[i-2], 17) ^ rotr(w[i-2], 19) ^ (w[i-2] >> 10)) + w[i-7] +
                       (rotr(w[i-15], 7) ^ rotr(w[i-15], 18) ^ (w[i-15] >> 3)) + w[i-16];
            {a, b, c, d, e, f, g, h} = {H[0], H[1], H[2], H[3], H[4], H[5], H[6], H[7]};
            for (int i = 0; i < 64; i++) begin
                t1 = h + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
                t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
                {h, g, f, e, d, c, b, a} = {g, f, e, d + t1, c, b, a, t1 + t2};
            end
            H[0] += a; H[1] += b; H[2] += c; H[3] += d; H[4] += e; H[5] += f; H[6] += g; H[7] += h;
            exp_q.push_back({H[0], H[1], H[2], H[3], H[4], H[5], H[6], H[7]});
        endfunction

        function void write_dig(dig_item t);
            n++;
            if (exp_q.size() == 0) begin
                n_errors++;
                `uvm_error("SB", $sformatf("unexpected digest #%0d: %s", n, t.convert2string()))
                return;
            end
            if (t.digest != exp_q[0]) begin
                n_errors++;
                `uvm_error("SB", $sformatf("MISMATCH digest #%0d: dut %h, model %h", n, t.digest, exp_q[0]))
            end
            if (n == 1) abc_ok = (t.digest == 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad);
            void'(exp_q.pop_front());
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("%0d digests compared, %0d errors, test vector 'abc' %s", n, n_errors,
                                      abc_ok ? "ok" : "WRONG"), UVM_NONE)
            if (!abc_ok) `uvm_error("SB", "the 'abc' test vector does not match FIPS 180-4")
        endfunction
    endclass

    class env extends uvm_env;
        `uvm_component_utils(env)
        blk_agent  blk;
        dig_agent  dig;
        scoreboard sb;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            blk = blk_agent::type_id::create("blk", this);
            dig = dig_agent::type_id::create("dig", this);
            sb  = scoreboard::type_id::create("sb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            blk.ap.connect(sb.blk_imp);
            dig.ap.connect(sb.dig_imp);
        endfunction
    endclass

    class sha_test extends uvm_test;
        `uvm_component_utils(sha_test)
        env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); e = env::type_id::create("e", this); endfunction
        task run_phase(uvm_phase phase);
            blk_seq seq = blk_seq::type_id::create("seq");
            void'($value$plusargs("N=%d", seq.n));
            phase.raise_objection(this);
            seq.start(e.blk.sqr);
            wait (e.sb.n >= seq.n);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
