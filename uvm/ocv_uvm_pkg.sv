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
//  4. the test ends on transactions (expected count received), not on a delay.
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
    import "DPI-C" function void   ocv_dpi_check_status(int ch, output longint checked, output longint errors,
                                                        output int done);
    import "DPI-C" function int    ocv_dpi_check_mismatch(int ch, output ocv_rec_t dut, output ocv_rec_t exp,
                                                          output int field, output longint index);
`endif

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
        pure virtual function ocv_rec_t to_rec();
        pure virtual function void from_rec(ocv_rec_t r);
        function void add_record(ocv_item r);
            blk.push_back(r.to_rec());
        endfunction
        virtual function void do_copy(uvm_object rhs);
            ocv_item o;
            super.do_copy(rhs);
            if ($cast(o, rhs)) blk = o.blk;
        endfunction
    endclass

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
            if (ocv_opened) return;
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
            if (ocv_opened) `uvm_info("OCV", ocv_dpi_close(), UVM_NONE)
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
            ap = new("ap", this);
            ocv_board::open();
        endfunction

        task run_phase(uvm_phase phase);
            T t;
            if (ocv_board::is_board()) ocv_board::start();
            forever begin
                seq_item_port.get_next_item(t);
`ifdef OCV_BOARD
                if (t.blk.size() == 0) begin
                    while (!ocv_dpi_send(ch, t.to_rec())) ocv_board::wait_progress();   // ring full
                    ocv_sent++;
                end else begin
                    foreach (t.blk[i]) begin
                        while (!ocv_dpi_send(ch, t.blk[i])) ocv_board::wait_progress();
                        ocv_sent++;
                    end
                end
`else
                if (t.blk.size() == 0) drive(t);
                else foreach (t.blk[i]) begin         // a block on the pins: record by record
                    T x = new();
                    x.from_rec(t.blk[i]);
                    drive(x);
                end
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
            ap = new("ap", this);
            ocv_board::open();
        endfunction

        task run_phase(uvm_phase phase);
            T t;
            if (ocv_board::is_board()) ocv_board::start();
            forever begin
`ifdef OCV_BOARD
                ocv_rec_t r;
                if (!ocv_dpi_recv(ch, r)) begin
                    ocv_board::wait_progress();
                    continue;
                end
                t = T::type_id::create("t");
                t.from_rec(r);
`else
                sample(t);
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
            if (ch < 0) `uvm_fatal("OCV", "ocv_checker: set ch (the channel number) before build")
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
