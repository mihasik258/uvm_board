// sha_c_pkg.sv - the UVM test of the SHA-256 core written by the OCV contract (uvm/ocv_uvm_pkg.sv, the rules in its
// header): the DUT is reached only through sha_if (examples/sha256/uvm_v/sha_if.sv); blocks have a transaction and a
// driver (blk_item, ocv_source_driver), digests a transaction and a monitor (dig_item, ocv_monitor); the scoreboard
// is an ocv_model_checker - every digest against the reference model in C (examples/sha256/sha256_model.c, FIPS 180-4).
// The same files run in simulation (the RTL) and on the board (the DUT in the FPGA). It is the test of
// examples/sha256/uvm_v without its scoreboard in SystemVerilog.
//   +N=<blocks>     (default 1000). Block 0 is "abc" padded, a new message: its digest is the standard test vector
//                   (the model checks it against FIPS 180-4 as well)
//   +PKT=<k>        blocks per UVM transaction: one message of k blocks (the first starts it) goes to the driver as
//                   one item (ocv_item's block, add_record) - the length of a transaction, for the curve of FOCUS
//                   4.10. Without it: one block per transaction, a new message 1 in 8 (as examples/sha256/uvm_v)
//   +SEED=<n>       the random seed
`include "uvm_macros.svh"

package sha_c_pkg;
    import uvm_pkg::*;
    import ocv_uvm_pkg::*;

    // ---------------- blocks ----------------
    class blk_item extends ocv_item;
        `uvm_object_utils(blk_item)
        bit [511:0] block;
        bit         init;
        function new(string name = "blk_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("init=%0d block=%h", init, block); endfunction
    endclass
    class blk_driver extends ocv_source_driver #(blk_item);
        `uvm_component_utils(blk_driver)
        virtual sha_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual sha_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(blk_item t);
            wait (vif.rst_n);                   // (the DUT takes no transfer in reset: its ready is not held low there)
            vif.in_valid <= 1'b1;
            vif.in_block <= t.block;
            vif.in_init <= t.init;
            do @(posedge vif.clk); while (!vif.in_ready);
            vif.in_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(blk_item, blk_driver) blk_agent;

    // ---------------- digests ----------------
    class dig_item extends ocv_item;
        `uvm_object_utils(dig_item)
        bit [255:0] digest;
        function new(string name = "dig_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("digest=%h", digest); endfunction
    endclass
    class dig_monitor extends ocv_monitor #(dig_item);
        `uvm_component_utils(dig_monitor)
        virtual sha_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual sha_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output dig_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.out_valid));
            t = dig_item::type_id::create("t");
            t.digest = vif.out_digest;
        endtask
    endclass
    typedef ocv_output_agent #(dig_item, dig_monitor) dig_agent;

    // n blocks: "abc" padded first, then random blocks; pkt == 0: one block per item, a new message 1 in 8;
    // pkt > 0: messages of pkt blocks, one item each
    class blk_seq extends uvm_sequence #(blk_item);
        `uvm_object_utils(blk_seq)
        int unsigned n = 1000;
        int unsigned pkt = 0;
        function new(string name = "blk_seq"); super.new(name); endfunction
        function void fill(blk_item t, int unsigned i, bit init);
            if (i == 0) t.block = {32'h61626380, {14{32'h0}}, 32'h00000018};
            else for (int k = 0; k < 16; k++) t.block[32*k +: 32] = $urandom;
            t.init = init;
        endfunction
        task body();
            blk_item one = blk_item::type_id::create("one");
            for (int unsigned i = 0; i < n; i += (pkt ? pkt : 1)) begin
                blk_item t = blk_item::type_id::create("t");
                start_item(t);
                if (pkt == 0) fill(t, i, i == 0 || $urandom_range(0, 7) == 0);
                else for (int unsigned k = 0; k < pkt && i + k < n; k++) begin
                    fill(one, i + k, k == 0);
                    t.add_record(one);
                end
                finish_item(t);
            end
        endtask
    endclass

    class sha_env extends uvm_env;
        `uvm_component_utils(sha_env)
        blk_agent blk;
        dig_agent dig;
        ocv_model_checker chk;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            blk = blk_agent::type_id::create("blk", this);
            dig = dig_agent::type_id::create("dig", this);
            chk = ocv_model_checker::type_id::create("chk", this);
        endfunction
    endclass

    class sha_test extends uvm_test;
        `uvm_component_utils(sha_test)
        sha_env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase); e = sha_env::type_id::create("e", this); endfunction
        task run_phase(uvm_phase phase);
            blk_seq seq = blk_seq::type_id::create("seq");
            int unsigned seed = 1;
            void'($value$plusargs("N=%d", seq.n));
            void'($value$plusargs("PKT=%d", seq.pkt));
            void'($value$plusargs("SEED=%d", seed));
            void'($urandom(seed));
            `uvm_info("TEST", $sformatf("%0d blocks, %0s", seq.n, seq.pkt ? $sformatf("messages of %0d per transaction", seq.pkt)
                                                                         : "one per transaction"), UVM_LOW)
            phase.raise_objection(this);
            seq.start(e.blk.sqr);
            e.chk.finish();
            phase.drop_objection(this);
        endtask
    endclass
endpackage
