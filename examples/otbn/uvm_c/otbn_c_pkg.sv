// otbn_c_pkg.sv - a UVM test of OpenTitan's OTBN with its KMAC (examples/otbn/otbn_kmac_ocv.sv) written by the OCV
// contract (uvm/ocv_uvm_pkg.sv, the rules in its header): the DUT is reached only through otbn_if; its bus has a
// transaction and driver (bus_item, ocv_source_driver) and its responses a transaction and monitor (rsp_item,
// ocv_monitor); the scoreboard is an ocv_model_checker - every response against the reference model
// (examples/otbn/otbn_model.c: ML-DSA-87 of mldsa-native). The same files run in simulation (the RTL) and on the
// board (the DUT in the FPGA).
//
// The test is what software does with the pair (OpenTitan's crypto library): KMAC set up for its application
// interface (kmac_hwip_default_configure), OTBN's ML-DSA-87 app loaded (run_mldsa87), then rounds of
//   keygen (deterministic) from a random seed xi, in two shares  -> the public key read back
//   sign (deterministic) of a random message representative mu    -> the signature read back
// with ERR_BITS read after each run. A run ends when OTBN is idle again: a wait request (bus_item.wait_idle).
// Each round starts from the app's DMEM image, as software loads the app before it uses it (otbn_load_app): the
// operations share DMEM (sign overwrites what keygen started from).
//   +PROG=<run_mldsa87>     the program: <run_mldsa87>.load (bus words) and .sym (DMEM buffers), otbn_prog.py
//   +ROUNDS=<n>             keygen+sign rounds (default 1); +SEED=<n> the random seed (default 1)
`include "uvm_macros.svh"

package otbn_c_pkg;
    import uvm_pkg::*;
    import ocv_uvm_pkg::*;

    // ---------------- the bus: an access, or a wait for OTBN to be idle ----------------
    class bus_item extends ocv_item;
        `uvm_object_utils(bus_item)
        bit          we;
        bit          wait_idle;
        bit [31:0]   addr;
        bit [31:0]   wdata;
        bit [3:0]    be;
        function new(string name = "bus_item"); super.new(name); endfunction
        function string convert2string();
            return wait_idle ? "wait" : $sformatf("%s addr=0x%0h data=0x%0h", we ? "write" : "read", addr, wdata);
        endfunction
    endclass
    class bus_driver extends ocv_source_driver #(bus_item);
        `uvm_component_utils(bus_driver)
        virtual otbn_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual otbn_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task drive(bus_item t);
            vif.req_valid <= 1'b1;
            vif.req_we <= t.we;
            vif.req_wait <= t.wait_idle;
            vif.req_addr <= t.addr;
            vif.req_wdata <= t.wdata;
            vif.req_be <= t.be;
            do @(posedge vif.clk); while (!vif.req_ready);
            vif.req_valid <= 1'b0;
        endtask
    endclass
    typedef ocv_source_agent #(bus_item, bus_driver) bus_agent;

    // ---------------- the responses ----------------
    class rsp_item extends ocv_item;
        `uvm_object_utils(rsp_item)
        bit [31:0]   rdata;
        bit          err;
        function new(string name = "rsp_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("rdata=0x%0h err=%0d", rdata, err); endfunction
    endclass
    class rsp_monitor extends ocv_monitor #(rsp_item);
        `uvm_component_utils(rsp_monitor)
        virtual otbn_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db #(virtual otbn_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task sample(output rsp_item t);
            do @(posedge vif.clk); while (!(vif.rst_n && vif.rsp_valid));
            t = rsp_item::type_id::create("t");
            t.rdata = vif.rsp_rdata;
            t.err = vif.rsp_err;
        endtask
    endclass
    typedef ocv_output_agent #(rsp_item, rsp_monitor) rsp_agent;

    // ---------------- what software does on the bus ----------------
    localparam bit [31:0] OTBN = 32'h0, KMAC = 32'h1_0000, IMEM = 32'h4000, DMEM = 32'h8000;
    localparam bit [31:0] OTBN_CMD = OTBN + 'h10, OTBN_ERR_BITS = OTBN + 'h1c, CMD_EXECUTE = 'hd8;
    localparam bit [31:0] MODE_KEYGEN_DET = 'hfaacd725, MODE_SIGN_DET = 'h8accea7f;

    class bus_seq extends uvm_sequence #(bus_item);
        `uvm_object_utils(bus_seq)
        function new(string name = "bus_seq"); super.new(name); endfunction
        task access(bit we, bit [31:0] addr, bit [31:0] wdata = 0, bit wait_idle = 0);
            bus_item t = bus_item::type_id::create("t");
            start_item(t);
            t.we = we; t.wait_idle = wait_idle; t.addr = addr; t.wdata = wdata; t.be = 4'hf;
            finish_item(t);
        endtask
        task wr(bit [31:0] addr, bit [31:0] wdata); access(1, addr, wdata); endtask
        task rd(bit [31:0] addr); access(0, addr); endtask
        task wait_idle(); access(0, 0, 0, 1); endtask
        task wr_shadowed(bit [31:0] addr, bit [31:0] wdata); wr(addr, wdata); wr(addr, wdata); endtask
    endclass

    class idle_seq extends bus_seq;
        `uvm_object_utils(idle_seq)
        function new(string name = "idle_seq"); super.new(name); endfunction
        task body(); wait_idle(); endtask
    endclass

    // KMAC set up as OpenTitan's kmac_hwip_default_configure does: no interrupts, the longest entropy period and
    // refresh threshold, CFG: EDN entropy, entropy ready, little-endian, no sideload
    class kmac_init_seq extends bus_seq;
        `uvm_object_utils(kmac_init_seq)
        function new(string name = "kmac_init_seq"); super.new(name); endfunction
        task body();
            wr(KMAC + 'h04, 0);                       // INTR_ENABLE
            wr(KMAC + 'h20, 32'hffff_03ff);           // ENTROPY_PERIOD: wait_timer, prescaler
            wr_shadowed(KMAC + 'h28, 32'h3ff);        // ENTROPY_REFRESH_THRESHOLD_SHADOWED
            wr_shadowed(KMAC + 'h14, 32'h0101_0000);  // CFG_SHADOWED: entropy_ready, entropy_mode = EDN
        endtask
    endclass

    // the program: its words over the bus (IMEM, then DMEM; dmem_only: DMEM's)
    class load_seq extends bus_seq;
        `uvm_object_utils(load_seq)
        bit [31:0] addrs[$], words[$];
        bit dmem_only;
        function new(string name = "load_seq"); super.new(name); endfunction
        function void read(string file);
            int fd = $fopen(file, "r");
            bit [31:0] a, w;
            if (fd == 0) `uvm_fatal("TEST", $sformatf("%s: cannot open", file))
            while ($fscanf(fd, "%h %h\n", a, w) == 2) begin addrs.push_back(a); words.push_back(w); end
            $fclose(fd);
        endfunction
        task body();
            foreach (words[i]) if (!dmem_only || addrs[i] >= DMEM) wr(addrs[i], words[i]);
        endtask
    endclass

    // rounds of keygen and sign; the buffers' DMEM offsets from the program's symbols
    class mldsa_seq extends bus_seq;
        `uvm_object_utils(mldsa_seq)
        int unsigned rounds = 1;
        int unsigned sym[string];
        load_seq dmem;                                  // the app's DMEM image, written at the start of a round
        function new(string name = "mldsa_seq"); super.new(name); endfunction
        function void read_syms(string file);
            int fd = $fopen(file, "r");
            string n;
            int unsigned v;
            if (fd == 0) `uvm_fatal("TEST", $sformatf("%s: cannot open", file))
            while ($fscanf(fd, "%s %h\n", n, v) == 2) sym[n] = v;
            $fclose(fd);
        endfunction
        function bit [31:0] at(string name);
            if (!sym.exists(name)) `uvm_fatal("TEST", $sformatf("no symbol %s in the program", name))
            return DMEM + sym[name];
        endfunction
        task wr_words(string buf_, int n, bit rnd, bit [31:0] first = 0);
            for (int i = 0; i < n; i++) wr(at(buf_) + 4 * i, i == 0 && !rnd ? first : rnd ? $urandom : 0);
        endtask
        task rd_words(string buf_, int n);
            for (int i = 0; i < n; i++) rd(at(buf_) + 4 * i);
        endtask
        task run_otbn();
            wr(OTBN_CMD, CMD_EXECUTE);
            wait_idle();
            rd(OTBN_ERR_BITS);
        endtask
        task body();
            repeat (rounds) begin
                dmem.start(m_sequencer, this);
                // keygen: xi in two shares (xi = share0 ^ share1)
                wr_words("mldsa87_mode", 8, 0, MODE_KEYGEN_DET);
                wr_words("mldsa87_keygen_xi_share0", 8, 1);
                wr_words("mldsa87_keygen_xi_share1", 8, 1);
                run_otbn();
                rd_words("mldsa87_pk_rho", 8);
                rd_words("mldsa87_pk_t1", 640);         // 8 polynomials of 256 10-bit coefficients
                // sign: mu, no randomness (deterministic), the rejection counter from 0
                wr_words("mldsa87_mode", 8, 0, MODE_SIGN_DET);
                wr_words("mldsa87_mu", 16, 1);
                wr_words("mldsa87_sign_rnd_share0", 8, 0);
                wr_words("mldsa87_sign_rnd_share1", 8, 0);
                wr_words("mldsa87_sign_kappa", 8, 0);
                run_otbn();
                rd_words("mldsa87_sig_c_tilde", 16);
                rd_words("mldsa87_sig_z", 1120);        // 7 polynomials of 256 20-bit coefficients
                rd_words("mldsa87_sig_h", 21);          // omega + k = 83 bytes (and one more)
            end
        endtask
    endclass

    class otbn_env extends uvm_env;
        `uvm_component_utils(otbn_env)
        bus_agent bus;
        rsp_agent rsp;
        ocv_model_checker chk;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            string prog;
            bus = bus_agent::type_id::create("bus", this);
            rsp = rsp_agent::type_id::create("rsp", this);
            chk = ocv_model_checker::type_id::create("chk", this);
            // (board: OTBN works ~1 million clocks between two responses - the runner neither takes that for a
            // stall nor bounds the polls of a run)
            chk.run_args = "--squash 4096 --stall-polls 0 --max-polls 0";
            if ($value$plusargs("PROG=%s", prog)) chk.opts = {"syms=", prog, ".sym"};   // (+OCV_MODEL=... replaces it)
        endfunction
    endclass

    class otbn_mldsa_test extends uvm_test;
        `uvm_component_utils(otbn_mldsa_test)
        otbn_env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            e = otbn_env::type_id::create("e", this);
        endfunction
        task run_phase(uvm_phase phase);
            string prog;
            int unsigned rounds = 1, seed = 1;
            idle_seq      w = idle_seq::type_id::create("w");
            kmac_init_seq k = kmac_init_seq::type_id::create("k");
            load_seq      l = load_seq::type_id::create("l");
            mldsa_seq     m = mldsa_seq::type_id::create("m");
            if (!$value$plusargs("PROG=%s", prog)) `uvm_fatal("TEST", "give +PROG=<build/otbn/prog/run_mldsa87>")
            void'($value$plusargs("ROUNDS=%d", rounds));
            void'($value$plusargs("SEED=%d", seed));
            void'($urandom(seed));
            l.read({prog, ".load"});
            m.read_syms({prog, ".sym"});
            m.rounds = rounds;
            `uvm_info("TEST", $sformatf("%s: %0d words, %0d round(s) of keygen + sign", prog, l.words.size(), rounds), UVM_LOW)
            phase.raise_objection(this);
            w.start(e.bus.sqr);                        // (OTBN's secure wipe after reset)
            k.start(e.bus.sqr);
            l.start(e.bus.sqr);                        // the app (its DMEM image again at each round)
            m.dmem = load_seq::type_id::create("dmem");
            m.dmem.addrs = l.addrs; m.dmem.words = l.words; m.dmem.dmem_only = 1;
            m.start(e.bus.sqr);
            e.chk.finish();
            phase.drop_objection(this);
        endtask
    endclass
endpackage
