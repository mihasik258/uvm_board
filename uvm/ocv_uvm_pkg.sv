// ocv_uvm_pkg.sv - OCV base classes for UVM agents: the same testbench runs in simulation (agents
// drive the DUT's pins) and on the board (agents exchange transactions with the DUT in the FPGA;
// the testbench itself runs on the processor of the hybrid SoC).
//
// Build:  simulation - the DUT's RTL + the generated harness, as usual;
//         board      - +define+OCV_BOARD, no DUT RTL; the testbench is linked with ocv_uvm_dpi.c
//                      and a bus (ocv_uvm_bus_mmap.c on the board, ocv_uvm_bus_vlt.cpp on a PC).
//
// Rules for a testbench that runs on the board as well (what the board build cannot do):
//  1. talk to the DUT only through agents derived from ocv_source_driver / ocv_monitor (or the
//     generated ones) - no hierarchical references into the DUT, no direct pin access;
//  2. pin-level code lives only in drive() / sample() (simulation); sequences, scoreboards,
//     coverage and models work on transactions;
//  3. no assumption about the cycle a transaction happens in: the board runs the DUT at its own
//     clock, the testbench at the processor's pace (the DUT waits for it - no loss);
//  4. the test ends on transactions (expected count received), not on a delay;
//  5. transactions extend ocv_item, one item class per channel, created through the factory
//     (<item>::type_id::create): their record packing is derived, not written (uvm/ocv_contract.py);
//  6. a driver extends ocv_source_driver and puts one item on the pins in drive(t): the item's fields to
//     interface signals, a valid raised with them, `do @(posedge vif.clk); while (!vif.<ready>);`, valid
//     lowered; a monitor extends ocv_monitor and takes one transfer in sample(t):
//     `do @(posedge vif.clk); while (!(vif.<valid> [&& vif.<ready>]));`, the item created, its fields from
//     interface signals. From these shapes and the top's wiring of the DUT to the interface the DUT's
//     description is derived - there is no description file to write (uvm/ocv_contract.py, uvm/tbparse.py);
//  7. functional coverage: a uvm_subscriber #(<item>) with the covergroups, connected to the agent's `ap` (a source
//     agent's: the items given to the DUT; an output agent's: what its monitor took). On the board a channel the
//     model checker checks makes no UVM object per record: its monitor's `ap` then gets the model's records (the
//     DUT's, in a passing run) thinned to those that can change the coverage - a record whose projection on the
//     item's fields the subscribers read (with the history they keep) is new (uvm/ocv_uvm_tap.h). The bins come out
//     as in simulation, not how often each was hit. A subscriber with a state of its own (other than covergroups and
//     items) declares its depth - `localparam int ocv_cov_history = K;`: its state is the last K transactions it
//     got - or it gets every record (exact, slower). Derived by uvm/ocv_contract.py; nothing to write for the board.
`ifndef OCV_UVM_PKG_SV
`define OCV_UVM_PKG_SV
`include "uvm_macros.svh"

package ocv_uvm_pkg;
    timeunit 1ns; timeprecision 1ps;
    import uvm_pkg::*;

    typedef longint unsigned ocv_u64_t;

    localparam int OCV_UVM_REC_BITS = 1024;          // = 32 * OCV_UVM_REC_WORDS in ocv_uvm_dpi.c
    typedef bit [OCV_UVM_REC_BITS-1:0] ocv_rec_t;

`ifdef OCV_BOARD
    import "DPI-C" function int     ocv_dpi_open(string base);
    import "DPI-C" function int     ocv_dpi_send(int ch, input ocv_rec_t rec);
    import "DPI-C" function longint ocv_dpi_service(output int moved);
    import "DPI-C" function int     ocv_dpi_recv(int ch, output ocv_rec_t rec);
    import "DPI-C" function int     ocv_dpi_pending(int ch);
    import "DPI-C" function string  ocv_dpi_close();
    import "DPI-C" function int     ocv_dpi_go(int squash);
    import "DPI-C" function void    ocv_dpi_first_error();
`endif

    // reference checkers in C (ocv_uvm_check.h): in every build
    import "DPI-C" function int    ocv_dpi_check(int ch, input ocv_rec_t rec, output ocv_rec_t exp, output int last);
    import "DPI-C" function string ocv_dpi_field_name(int ch, int field);
    import "DPI-C" function int    ocv_dpi_check_enable(int ch);
    import "DPI-C" function int    ocv_dpi_check_deliver(int ch);
`ifdef OCV_BOARD
    // the board side of ocv_model_checker (ocv_uvm_runner.c): the runner owns the hub, the agents take part
    import "DPI-C" function int    ocv_dpi_model_board_open(string args);
    import "DPI-C" function void   ocv_dpi_model_send(int ch, input ocv_rec_t rec);
    import "DPI-C" function int    ocv_dpi_model_recv(int ch, output ocv_rec_t rec);
    import "DPI-C" function void   ocv_dpi_model_wait();
    import "DPI-C" function int    ocv_dpi_model_board_done(output int rc);
    import "DPI-C" function void   ocv_dpi_check_status(int ch, output longint checked, output longint errors,
                                                        output int done);
    import "DPI-C" function int    ocv_dpi_check_mismatch(int ch, output ocv_rec_t dut, output ocv_rec_t exp,
                                                          output int field, output longint index);
    // coverage on the board (rule 7): a channel's records for its coverage subscribers; the covergroups off while
    // context records go by (OCV's Verilator runtime; a stand-in in ocv_uvm_model.c for a build without covergroups)
    import "DPI-C" function int    ocv_dpi_model_tap(int ch, string spec);
    import "DPI-C" function void   vl_covergroup_enable(int on);
`endif

    // the whole-DUT reference model (ocv_uvm_model.c, ocv_model_checker): in every build
    import "DPI-C" function int    ocv_dpi_model_open(string opts);
    import "DPI-C" function void   ocv_dpi_model_in(int ch, input ocv_rec_t rec);
    import "DPI-C" function void   ocv_dpi_model_out(int ch, input ocv_rec_t rec);
    import "DPI-C" function void   ocv_dpi_model_status(output longint checked, output longint errors, output int done);
    import "DPI-C" function void   ocv_dpi_model_in_done();
    import "DPI-C" function int    ocv_dpi_model_mismatch(output int ch, output ocv_rec_t dut, output ocv_rec_t exp,
                                                          output int field, output longint index);
    import "DPI-C" function string ocv_dpi_model_channel(int ch);
    import "DPI-C" function string ocv_dpi_model_field(int ch, int field);
    import "DPI-C" function string ocv_dpi_model_format(int ch, input ocv_rec_t rec);
    import "DPI-C" function void   ocv_dpi_model_close();
    import "DPI-C" function longint ocv_dpi_model_records();
    import "DPI-C" function void   ocv_dpi_model_quiet();

    // one field compared by the descriptor's rule (ocv_meta.h ocv_cmp_t): 0 exact, 1 ignore,
    // 2 mask (arg), 3 abs (|a-b| <= arg as integers of the field), 4 ulp (IEEE fp of width fp)
    function automatic bit ocv_field_match(int code, longint unsigned arg, int fp, int width, bit sgn,
                                           longint unsigned a, longint unsigned b);
        longint unsigned m = width >= 64 ? '1 : (64'd1 << width) - 1;
        a &= m; b &= m;
        case (code)
            1: return 1;
            2: return ((a ^ b) & arg) == 0;
            3: begin
                longint sa = longint'(a), sb = longint'(b), d;
                if (sgn && width < 64) begin
                    sa = (a >> (width - 1)) ? longint'(a | ~m) : longint'(a);
                    sb = (b >> (width - 1)) ? longint'(b | ~m) : longint'(b);
                end
                if (!sgn) return (a > b ? a - b : b - a) <= arg;
                d = sa - sb;
                return ocv_u64_t'(d < 0 ? -d : d) <= arg;
            end
            4: begin
                int e = fp == 16 ? 5 : fp == 32 ? 8 : 11;
                longint unsigned mag = (64'd1 << (fp - 1)) - 1, ma = a & mag, mb = b & mag;
                longint unsigned emax = ((64'd1 << e) - 1) << (fp - 1 - e);
                bit nan_a = ma > emax, nan_b = mb > emax;
                longint oa, ob, d;
                if (nan_a || nan_b) return nan_a && nan_b;
                oa = (a >> (fp - 1)) ? -longint'(ma) : longint'(ma);
                ob = (b >> (fp - 1)) ? -longint'(mb) : longint'(mb);
                d = oa - ob;
                return ocv_u64_t'(d < 0 ? -d : d) <= arg;
            end
            default: return a == b;
        endcase
    endfunction

    // a transaction of one OCV channel: its fields packed as the hub's record. A *block* carries
    // many records in blk (add_record): one pass through the sequencer and the driver for all of
    // them - on the board the expensive part of UVM is per item, not per record.
    virtual class ocv_item extends uvm_sequence_item;
        ocv_rec_t blk[$];
        function new(string name = "ocv_item"); super.new(name); endfunction
        static function string type_name(); return "ocv_item"; endfunction   // (an item's `uvm_object_utils gives its own)
        // The packing of the fields into the hub's record. Nobody writes it: ocv_contract.py derives it from
        // the item class's fields (as the channel's descriptor does) into a subclass <item>__ocv, which the
        // factory gives for every <item>::type_id::create (so items are created through the factory, rule 5);
        // the generator of the description-file path (ocv_uvm_gen.py) writes it into the item itself.
        virtual function ocv_rec_t to_rec();
            `uvm_fatal("OCV", $sformatf("%s: no record packing - create the item with %s::type_id::create (rule 5), and build with uvm/ocv_contract.py", get_type_name(), get_type_name()))
            return '0;
        endfunction
        virtual function void from_rec(ocv_rec_t r);
            `uvm_fatal("OCV", $sformatf("%s: no record packing - create the item with %s::type_id::create (rule 5), and build with uvm/ocv_contract.py", get_type_name(), get_type_name()))
        endfunction
        function void add_record(ocv_item r);
            blk.push_back(r.to_rec());
        endfunction
        virtual function void do_copy(uvm_object rhs);
            ocv_item o;
            super.do_copy(rhs);
            if ($cast(o, rhs)) blk = o.blk;
        endfunction
    endclass

    // The channel of each item type (ocv_contract.py: one channel per item class, numbered as the hub's),
    // filled before any phase by the derived package's static initialisation; agents, drivers, monitors and
    // checkers whose `ch` nobody set find theirs here
    int ocv_channel_of[string];

    // What the derived package installs once UVM is up (the record packing's factory overrides): registered at
    // its static initialisation, run by the first agent's build_phase - the factory itself is made at UVM's own
    // static initialisation, which may come after the derived package's
    virtual class ocv_hook;
        pure virtual function void install();
    endclass
    ocv_hook ocv_hooks[$];
    bit      ocv_hooks_done;

    function automatic void ocv_install_hooks();
        if (ocv_hooks_done) return;
        ocv_hooks_done = 1;
        foreach (ocv_hooks[i]) ocv_hooks[i].install();
    endfunction

    function automatic int ocv_lookup_channel(string item_type, string who);
        if (!ocv_channel_of.exists(item_type))
            `uvm_fatal("OCV", $sformatf("%s: item type '%s' is no channel of this DUT (set ch, or build with uvm/ocv_contract.py)", who, item_type))
        return ocv_channel_of[item_type];
    endfunction

    // an ocv_model_checker is in the testbench: the base drivers and monitors hand it every record (simulation),
    // the runner owns the hub (board: the runner's options, the run is over, its exit status)
    bit    ocv_model_on;
    string ocv_model_run_args;
    bit    ocv_model_ended;
    int    ocv_model_rc;
    int    ocv_driving;                  // source drivers in drive() now: transfers the DUT has not taken yet

    // The coverage subscribers' needs per item type (rule 7, ocv_contract.py): "<field>,... <history>" (the DUT
    // fields they read, the history they keep) or "all"
    string ocv_cov_spec[string];
    int    ocv_cov_busy;                 // monitors handing tapped records to their subscribers now
    semaphore ocv_cov_lock = new(1);     // (one at a time: the covergroups' switch is global)

    // State shared by all agents. Package variables, not static class members: simulators
    // differ on statics (xsim loses their values); a package variable is plain and portable.
    bit          ocv_opened, ocv_running;
    int unsigned ocv_progress;   // records came out of the DUT / ring space was freed
    int unsigned ocv_sent;       // a driver wrote a record
    longint      ocv_dut_cycles; // DUT clocks seen so far: the testbench's time follows them
    real         ocv_clk_ns = 10.0;  // +OCV_CLK_NS: the DUT's clock period on the board

`ifdef OCV_BOARD
    // The first error of the run: the board prints the line that records its waveform on a PC
    // (the record's number in its channel; build_board.sh wave, tbwave.py).
    class ocv_error_catcher extends uvm_report_catcher;
        function new(string name = "ocv_error_catcher"); super.new(name); endfunction
        function action_e catch();
            if (get_severity() inside {UVM_ERROR, UVM_FATAL}) ocv_dpi_first_error();
            return THROW;
        endfunction
    endclass
`endif

    // The board: opened once by the first agent, polled by one process for all channels.
    class ocv_board;

        static function bit is_board();
`ifdef OCV_BOARD
            return 1;
`else
            return 0;
`endif
        endfunction

        static function void open();
`ifdef OCV_BOARD
            string s = "";
`endif
            ocv_install_hooks();
`ifdef OCV_BOARD
            if (ocv_opened) return;
            if (ocv_model_on) return;                  // (the runner opens the hub: start())
            void'($value$plusargs("OCV_BASE=%s", s));   // parsed in C: 64-bit, 0x... or decimal
            if (!ocv_dpi_open(s)) `uvm_fatal("OCV", "cannot open the DUT on the board (see the message above)")
            ocv_opened = 1;
            begin
                ocv_error_catcher c = new();
                uvm_report_cb::add(null, c);
            end
`endif
        endfunction

        // Progress is counted (ocv_progress, ocv_sent) and waited on level-sensitively: no
        // event can be missed.
        // One process talks to the hub for all channels. After each look at the hub the
        // testbench's time advances by exactly the clocks the DUT ran meanwhile, so time means
        // the DUT's time, as in simulation (and as in emulators). A DUT that does not run (frozen,
        // waiting for a record) holds time; the process then waits until a driver sends.
        static task start();
`ifdef OCV_BOARD
            int squash = 1;
            if (ocv_running) return;
            ocv_running = 1;
            if (ocv_model_on) begin
                // the runner checks the DUT against the model; the testbench takes part when the runner hands it the
                // token: more stimulus, a device access, the end (ocv_uvm_runner.c). Time: a step per hand-over.
                if (!ocv_dpi_model_board_open(ocv_model_run_args))
                    `uvm_fatal("OCV", "cannot start the runner on the board (see the message above)")
                fork
                    forever begin
                        #1ns;                          // (the testbench's zero-time work first: what its drivers send)
                        ocv_dpi_model_wait();
                        ocv_progress++;
                        if (ocv_dpi_model_board_done(ocv_model_rc)) begin
                            ocv_model_ended = 1;
                            break;
                        end
                    end
                join_none
                return;
            end
            void'($value$plusargs("OCV_CLK_NS=%f", ocv_clk_ns));
            void'($value$plusargs("OCV_SQUASH=%d", squash));   // engine A: fused windows of N records
            if (!ocv_dpi_go(squash)) `uvm_fatal("OCV", "cannot start the DUT (see the message above)")
            fork
                forever begin
                    int          moved;
                    int unsigned sent0 = ocv_sent;
                    longint      c = ocv_dpi_service(moved);
                    if (moved) ocv_progress++;
                    if (c > ocv_dut_cycles) begin
                        #((c - ocv_dut_cycles) * ocv_clk_ns);
                        ocv_dut_cycles = c;
                    end else
                        wait (ocv_sent != sent0);
                end
            join_none
`endif
        endtask

        // until something moved between the testbench and the DUT
        static task wait_progress();
            int unsigned p0 = ocv_progress;
            wait (ocv_progress != p0);
        endtask


        static function void close();
`ifdef OCV_BOARD
            if (ocv_opened && !ocv_model_on) `uvm_info("OCV", ocv_dpi_close(), UVM_NONE)
            ocv_opened = 0;
`endif
        endfunction
    endclass

    // Driver of a source channel. Simulation: drive() puts the item on the pins (the generated
    // driver or the verifier's own, derived from this class). Board: the item goes to the FPGA.
    class ocv_source_driver #(type T = ocv_item) extends uvm_driver #(T);
        `uvm_component_param_utils(ocv_source_driver #(T))
        int ch = -1;                                 // channel number, set by the agent
        uvm_analysis_port #(T) ap;                   // every item the DUT was given (input monitor)

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (ch < 0) ch = ocv_lookup_channel(T::type_name(), get_full_name());
            ap = new("ap", this);
            ocv_board::open();
        endfunction

        task run_phase(uvm_phase phase);
            T t;
            if (ocv_board::is_board()) ocv_board::start();
            forever begin
                seq_item_port.get_next_item(t);
`ifdef OCV_BOARD
                if (ocv_model_on) begin               // the runner takes it (stimulus, or a device answer)
                    if (t.blk.size() == 0) ocv_dpi_model_send(ch, t.to_rec());
                    else foreach (t.blk[i]) ocv_dpi_model_send(ch, t.blk[i]);
                    ocv_sent++;
                end else if (t.blk.size() == 0) begin
                    while (!ocv_dpi_send(ch, t.to_rec())) ocv_board::wait_progress();   // ring full
                    ocv_sent++;
                end else begin
                    foreach (t.blk[i]) begin
                        while (!ocv_dpi_send(ch, t.blk[i])) ocv_board::wait_progress();
                        ocv_sent++;
                    end
                end
`else
                ocv_driving++;                        // (a transfer the DUT has not taken yet: it is not quiet)
                if (t.blk.size() == 0) begin
                    drive(t);
                    if (ocv_model_on) ocv_dpi_model_in(ch, t.to_rec());
                end else foreach (t.blk[i]) begin     // a block on the pins: record by record
                    T x = T::type_id::create("x");
                    x.from_rec(t.blk[i]);
                    drive(x);
                    if (ocv_model_on) ocv_dpi_model_in(ch, t.blk[i]);
                end
                ocv_driving--;
`endif
                ap.write(t);
                seq_item_port.item_done();
            end
        endtask

        // simulation only: put t on the DUT's pins, return when the DUT has taken it
        virtual task drive(T t);
            `uvm_fatal("OCV", $sformatf("%s: drive() not implemented - the simulation build needs a pin-level driver", get_full_name()))
        endtask

        // records written to the board but not yet taken by the DUT (0 in simulation)
        function int pending();
`ifdef OCV_BOARD
            return ocv_dpi_pending(ch);
`else
            return 0;
`endif
        endfunction

        function void report_phase(uvm_phase phase);
            ocv_board::close();         // the run is over: statistics, unmap
        endfunction
    endclass

    // Monitor of an output channel (sink or monitor). Simulation: sample() waits for the next
    // transaction on the pins. Board: transactions come from the FPGA. Each goes to `ap`.
    class ocv_monitor #(type T = ocv_item) extends uvm_monitor;
        `uvm_component_param_utils(ocv_monitor #(T))
        int ch = -1;
        uvm_analysis_port #(T) ap;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (ch < 0) ch = ocv_lookup_channel(T::type_name(), get_full_name());
            ap = new("ap", this);
            ocv_board::open();
        endfunction

        bit tapped;                                  // board, a model checker: the channel's records for its coverage

`ifdef OCV_BOARD
        // the connections are made: a channel the model checks, with coverage subscribers (rule 7), gets the model's
        // records the subscribers need (before the runner starts). +OCV_NO_TAP: none (the runner at its full speed -
        // a processor model folds the records of such a channel one by one, not per translated block)
        function void start_of_simulation_phase(uvm_phase phase);
            super.start_of_simulation_phase(phase);
            if (ocv_model_on && ap.size() > 0 && ocv_cov_spec.exists(T::type_name()) && !$test$plusargs("OCV_NO_TAP"))
                tapped = ocv_dpi_model_tap(ch, ocv_cov_spec[T::type_name()]) != 0;
        endfunction

        // a tapped channel: what has come, to the subscribers - a context record with the covergroups off
        // (#1ns around a switch: subscribers that sample from a fifo take what came before it first)
        task drain();
            T t;
            ocv_rec_t r;
            int k;
            bit off;
            ocv_cov_busy++;
            ocv_cov_lock.get();
            forever begin
                k = ocv_dpi_model_recv(ch, r);
                if (k == 0) break;
                if ((k == 2) != off) begin
                    #1ns;
                    off = k == 2;
                    vl_covergroup_enable(!off);
                end
                t = T::type_id::create("t");
                t.from_rec(r);
                ap.write(t);
            end
            if (off) begin #1ns; vl_covergroup_enable(1); end
            ocv_cov_lock.put();
            ocv_cov_busy--;
        endtask
`endif

        task run_phase(uvm_phase phase);
            T t;
            if (ocv_board::is_board()) ocv_board::start();
            forever begin
`ifdef OCV_BOARD
                ocv_rec_t r;
                if (tapped) begin
                    drain();
                    ocv_board::wait_progress();
                    continue;
                end
                if (!(ocv_model_on ? ocv_dpi_model_recv(ch, r) : ocv_dpi_recv(ch, r))) begin
                    ocv_board::wait_progress();
                    continue;
                end
                t = T::type_id::create("t");
                t.from_rec(r);
`else
                sample(t);
                if (ocv_model_on) ocv_dpi_model_out(ch, t.to_rec());
`endif
                ap.write(t);
            end
        endtask

        // simulation only: wait for the next transaction on the pins
        virtual task sample(output T t);
            `uvm_fatal("OCV", $sformatf("%s: sample() not implemented - the simulation build needs a pin-level monitor", get_full_name()))
        endtask

        function void report_phase(uvm_phase phase);
            ocv_board::close();         // the run is over: statistics, unmap
        endfunction
    endclass

    // Checker of an output channel against the testbench's C reference model (OCV_UVM_CHECKER in
    // its DPI code). Simulation: connect the channel's monitor to `analysis_export`, every
    // transaction is checked through DPI. Board: the records are checked in C as they leave the
    // FPGA - no UVM object per transaction; mismatches, counts and the end of the test come here.
    // `done` rises with the transaction the reference function marks as the last one.
    class ocv_checker #(type T = ocv_item) extends uvm_subscriber #(T);
        `uvm_component_param_utils(ocv_checker #(T))
        int     ch = -1;
        longint n_checked, n_errors;
        bit     done;
        int     max_reports = 10;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (ch < 0) ch = ocv_lookup_channel(T::type_name(), get_full_name());
            if (!ocv_dpi_check_enable(ch))
                `uvm_fatal("OCV", $sformatf("%s: no C reference function registered for channel %0d (OCV_UVM_CHECKER)", get_name(), ch))
            ocv_board::open();
        endfunction

        function void report_mismatch(T dut, ocv_rec_t exp, int field);
            T e = T::type_id::create("expected");
            e.from_rec(exp);
            if (n_errors <= max_reports)
                `uvm_error("OCV_CHECK", $sformatf("%s MISMATCH #%0d (transaction %0d) field '%s': dut %s, model %s",
                           get_name(), n_errors, n_checked, ocv_dpi_field_name(ch, field),
                           dut.convert2string(), e.convert2string()))
        endfunction

        // simulation: one transaction from the monitor
        function void write(T t);
            ocv_rec_t exp;
            int last, f;
            f = ocv_dpi_check(ch, t.to_rec(), exp, last);
            n_checked++;
            if (f >= 0) begin n_errors++; report_mismatch(t, exp, f); end
            if (last) done = 1;
        endfunction

`ifdef OCV_BOARD
        task run_phase(uvm_phase phase);
            ocv_rec_t d, e;
            int f, dn;
            longint ix;
            ocv_board::start();
            forever begin
                ocv_board::wait_progress();
                while (ocv_dpi_check_mismatch(ch, d, e, f, ix)) begin
                    T t = T::type_id::create("dut");
                    t.from_rec(d);
                    n_errors++;
                    report_mismatch(t, e, f);
                end
                ocv_dpi_check_status(ch, n_checked, n_errors, dn);
                done = dn;
            end
        endtask
`endif

        function void report_phase(uvm_phase phase);
            `uvm_info("OCV_CHECK", $sformatf("%s: %0d transactions checked in C, %0d mismatches", get_name(),
                                             n_checked, n_errors), UVM_NONE)
        endfunction
    endclass

    // Checker of the whole DUT against an OCV reference model (ocv_model.h - the runner's, e.g. a processor
    // core's models/cpu/ocv_cpu_model.c, linked into the testbench): every record of every output channel. The
    // testbench puts one in its env and connects nothing - the base drivers and monitors hand the model what
    // the DUT was given and what it made (simulation, ocv_uvm_model.c); `done` rises when the model has checked
    // the whole stimulus (a processor core: the program to its end). Model options: +OCV_MODEL="key=value ...".
    class ocv_model_checker extends uvm_component;
        `uvm_component_utils(ocv_model_checker)
        string  opts;
        longint n_checked, n_errors;
        bit     done;
        int     max_reports = 10;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ocv_model_on = 1;                // (before any agent's build_phase: on the board they then leave the hub to the runner)
        endfunction

        // the runner's options on the board (+OCV_RUN replaces them): windows of 4096 records; a DUT that works long
        // between its outputs (an accelerator) adds e.g. "--stall-polls 0 --max-polls 0"
        string run_args = "--squash 4096";

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            void'($value$plusargs("OCV_MODEL=%s", opts));   // (or what the env set before this phase)
`ifdef OCV_BOARD
            // the runner's options (+OCV_RUN, or what the env set in run_args) and the model's
            begin
                string run = run_args, t;
                int i0 = 0;
                void'($value$plusargs("OCV_RUN=%s", run));
                ocv_model_run_args = run;
                for (int i = 0; i <= opts.len(); i++)
                    if (i == opts.len() || opts[i] == " ") begin
                        t = opts.substr(i0, i - 1);
                        if (t.len() > 0) ocv_model_run_args = {ocv_model_run_args, " --model-opt ", t};
                        i0 = i + 1;
                    end
            end
`else
            if (!ocv_dpi_model_open(opts))
                `uvm_fatal("OCV", $sformatf("%s: no OCV reference model linked into the testbench", get_full_name()))
`endif
        endfunction

        function void collect();
            ocv_rec_t d, e;
            int c, f, dn;
            longint ix;
            while (ocv_dpi_model_mismatch(c, d, e, f, ix)) begin
                if (n_errors < max_reports)
                    `uvm_error("OCV_MODEL", $sformatf("MISMATCH channel '%s' record %0d field '%s': dut %s, model %s",
                               ocv_dpi_model_channel(c), ix, ocv_dpi_model_field(c, f), ocv_dpi_model_format(c, d),
                               ocv_dpi_model_format(c, e)))
                n_errors++;
            end
            begin
                longint ec;
                ocv_dpi_model_status(n_checked, ec, dn);
                if (ec > n_errors) n_errors = ec;
                done = dn;
            end
        endfunction

        // the test's stimulus is all sent: wait until the model has checked the DUT's records for all of it (a
        // test that knows its end calls this rather than waiting for `done`, which is also set whenever the model
        // has caught up with the stimulus so far - between two transfers, too)
        task finish();
`ifdef OCV_BOARD
            wait (ocv_model_ended);
            #1ns;                              // (and the coverage subscribers have the tapped records: rule 7)
            wait (ocv_cov_busy == 0);
`else
            ocv_dpi_model_in_done();
            do begin #1us; collect(); end while (!done);
`endif
        endtask

        int quiet_us = 100;              // no record of the DUT for this long (once it has made one), and no driver
                                         // waiting for the DUT to take a transfer: it is done (a DUT that works
                                         // long without output - an accelerator's operation - holds a transfer:
                                         // the next command, a wait for its end)

        task run_phase(uvm_phase phase);
            longint last = -1, n;
            int still = 0;
            bit told;
`ifdef OCV_BOARD
            // the runner checks; its verdict comes at the end (a mismatch: its line with the exact record above)
            ocv_board::start();
            wait (ocv_model_ended);
            #1ns;                              // the tapped channels' last records to their coverage subscribers (rule 7)
            wait (ocv_cov_busy == 0);
            if (ocv_model_rc != 0) begin
                n_errors++;
                `uvm_error("OCV_MODEL", $sformatf("the runner found the DUT and the model apart (exit %0d): see its MISMATCH line", ocv_model_rc))
            end
            done = 1;
            forever #1ms;
`endif
            forever begin
                #1us;
                collect();
                // the DUT is quiet - it makes no more records: the model goes on to the end without waiting for it
                n = ocv_dpi_model_records();
                if (n > 0 && n == last && ocv_driving == 0) still++; else still = 0;
                last = n;
                if (!told && still >= quiet_us) begin
                    ocv_dpi_model_quiet();
                    told = 1;
                end
            end
        endtask

        function void report_phase(uvm_phase phase);
`ifdef OCV_BOARD
            `uvm_info("OCV_MODEL", $sformatf("%s: the runner checked the DUT against the model: exit %0d", get_name(), ocv_model_rc), UVM_NONE)
            return;
`endif
            collect();
            ocv_dpi_model_close();
            `uvm_info("OCV_MODEL", $sformatf("%s: %0d records checked against the model, %0d mismatches%s", get_name(),
                                             n_checked, n_errors, done ? "" : " - the model did not finish the stimulus"),
                      UVM_NONE)
        endfunction
    endclass

    // Agents: D / M is the driver / monitor class (the generated pin-level one, or the verifier's
    // own derived from ocv_source_driver / ocv_monitor); the factory can override it as usual.
    class ocv_source_agent #(type T = ocv_item, type D = ocv_source_driver #(T)) extends uvm_agent;
        `uvm_component_param_utils(ocv_source_agent #(T, D))
        int                ch = -1;
        uvm_sequencer #(T) sqr;
        D                  drv;
        uvm_analysis_port #(T) ap;                   // items given to the DUT, in order

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            sqr = uvm_sequencer #(T)::type_id::create("sqr", this);
            drv = D::type_id::create("drv", this);
            drv.ch = ch;
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
            ap = drv.ap;
        endfunction
    endclass

    class ocv_output_agent #(type T = ocv_item, type M = ocv_monitor #(T)) extends uvm_agent;
        `uvm_component_param_utils(ocv_output_agent #(T, M))
        int              ch = -1;
        M                mon;
        uvm_analysis_port #(T) ap;

        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            mon = M::type_id::create("mon", this);
            mon.ch = ch;
        endfunction

        function void connect_phase(uvm_phase phase);
            ap = mon.ap;
        endfunction
    endclass
endpackage
`endif
