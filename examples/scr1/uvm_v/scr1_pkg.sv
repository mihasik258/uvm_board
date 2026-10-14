// scr1_pkg.sv - a UVM testbench for SCR1 written the usual way: transactions, a driver and a
// monitor on the pins (scr1_if), agents, a sequence that loads a program image, a scoreboard
// that steps a C reference model (DPI, scr1_ref_dpi.c) and compares every committed instruction:
// pc, next pc, rd, trap, and what it stored and wrote to CSRs (as RVFI's rvfi_mem_* / rvfi_csr_*).
//   +PROG=<file.hex>   program image ($readmemh, byte-addressed, e.g. objcopy -O verilog)
`include "uvm_macros.svh"

package scr1_pkg;
    import uvm_pkg::*;

    import "DPI-C" function void scr1_ref_load(int addr, int data);
    import "DPI-C" function int  scr1_ref_start();
    import "DPI-C" function void scr1_ref_step_all(output int pc, output int pc_next, output int rd_addr,
                                                   output int rd_wdata, output int trap,
                                                   output int mem_we, output int mem_wmask, output int mem_addr,
                                                   output int mem_wdata, output int csrw_we, output int csrw_cmd,
                                                   output int csrw_addr, output int csrw_data);
    import "DPI-C" function void scr1_ref_timer(int value);   // a counter read: the core's value

    localparam int unsigned SIM_EXIT = 32'h0000_00F8;

    // ---------------- transactions ----------------
    class prog_item extends uvm_sequence_item;
        `uvm_object_utils(prog_item)
        bit [13:0] addr;
        bit [31:0] data;
        bit        last;
        function new(string name = "prog_item"); super.new(name); endfunction
        function string convert2string(); return $sformatf("addr=0x%0h data=0x%08h last=%0d", addr, data, last); endfunction
    endclass

    class retire_item extends uvm_sequence_item;
        `uvm_object_utils(retire_item)
        bit [31:0] pc;
        bit [31:0] pc_next;
        bit [4:0]  rd_addr;
        bit [31:0] rd_wdata;
        bit        trap;
        bit        csr_rd;
        bit [11:0] csr_addr;
        bit        mem_we;              // a store: bytes mem_wmask from mem_addr
        bit [3:0]  mem_wmask;
        bit [31:0] mem_addr;
        bit [31:0] mem_wdata;
        bit        csrw_we;             // a CSR write: cmd 0 write, 1 set, 2 clear
        bit [1:0]  csrw_cmd;
        bit [11:0] csrw_addr;
        bit [31:0] csrw_data;
        function new(string name = "retire_item"); super.new(name); endfunction
        function string convert2string();
            string s = $sformatf("pc=0x%0h pc_next=0x%0h rd_addr=%0d rd_wdata=0x%0h trap=%0d", pc, pc_next, rd_addr, rd_wdata, trap);
            if (mem_we)  s = {s, $sformatf(" store[0x%0h]/%b=0x%0h", mem_addr, mem_wmask, mem_wdata)};
            if (csrw_we) s = {s, $sformatf(" csr 0x%0h cmd %0d op 0x%0h", csrw_addr, csrw_cmd, csrw_data)};
            return s;
        endfunction
    endclass

    // ---------------- program agent: driver on the load port ----------------
    class prog_driver extends uvm_driver #(prog_item);
        `uvm_component_utils(prog_driver)
        virtual scr1_if vif;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual scr1_if)::get(this, "", "vif", vif)) `uvm_fatal("DRV", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            prog_item t;
            vif.prog_valid <= 1'b0;
            @(posedge vif.rst_n);
            forever begin
                seq_item_port.get_next_item(t);
                vif.prog_valid <= 1'b1;
                vif.prog_addr  <= t.addr;
                vif.prog_data  <= t.data;
                vif.prog_last  <= t.last;
                do @(posedge vif.clk); while (!vif.prog_ready);
                vif.prog_valid <= 1'b0;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class prog_agent extends uvm_agent;
        `uvm_component_utils(prog_agent)
        uvm_sequencer #(prog_item) sqr;
        prog_driver                drv;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            sqr = uvm_sequencer #(prog_item)::type_id::create("sqr", this);
            drv = prog_driver::type_id::create("drv", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // ---------------- retire agent: monitor on the retire port ----------------
    class retire_monitor extends uvm_monitor;
        `uvm_component_utils(retire_monitor)
        virtual scr1_if vif;
        uvm_analysis_port #(retire_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            ap = new("ap", this);
            if (!uvm_config_db #(virtual scr1_if)::get(this, "", "vif", vif)) `uvm_fatal("MON", "no vif")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.rst_n && vif.rvfi_valid) begin
                    retire_item t = retire_item::type_id::create("t");
                    t.pc       = vif.rvfi_pc;
                    t.pc_next  = vif.rvfi_pc_next;
                    t.rd_addr  = vif.rvfi_rd_addr;
                    t.rd_wdata = vif.rvfi_rd_wdata;
                    t.trap     = vif.rvfi_trap;
                    t.csr_rd   = vif.rvfi_csr_rd;
                    t.csr_addr = vif.rvfi_csr_addr;
                    t.mem_we    = vif.rvfi_mem_we;
                    t.mem_wmask = vif.rvfi_mem_wmask;
                    t.mem_addr  = vif.rvfi_mem_addr;
                    t.mem_wdata = vif.rvfi_mem_wdata;
                    t.csrw_we   = vif.rvfi_csrw_we;
                    t.csrw_cmd  = vif.rvfi_csrw_cmd;
                    t.csrw_addr = vif.rvfi_csrw_addr;
                    t.csrw_data = vif.rvfi_csrw_data;
                    ap.write(t);
                end
            end
        endtask
    endclass

    class retire_agent extends uvm_agent;
        `uvm_component_utils(retire_agent)
        retire_monitor mon;
        uvm_analysis_port #(retire_item) ap;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            mon = retire_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            ap = mon.ap;
        endfunction
    endclass

    // ---------------- sequence: the program image ----------------
    class load_seq extends uvm_sequence #(prog_item);
        `uvm_object_utils(load_seq)
        bit [7:0] image[65536];
        int unsigned n_words;
        function new(string name = "load_seq"); super.new(name); endfunction
        function void read(string file);
            $readmemh(file, image);
            n_words = 0;
            for (int w = 0; w < 16384; w++)
                if ({image[4*w+3], image[4*w+2], image[4*w+1], image[4*w]} != 0) n_words = w + 1;
        endfunction
        task body();
            // the whole memory: words past the image are zeroed, as the model's memory is (the core's
            // memory keeps what the previous test left; a program may read past its image)
            for (int w = 0; w < 16384; w++) begin
                prog_item t = prog_item::type_id::create("t");
                start_item(t);
                t.addr = 14'(w);
                t.data = {image[4*w+3], image[4*w+2], image[4*w+1], image[4*w]};
                t.last = (w == 16383);
                finish_item(t);
            end
        endtask
    endclass

    // ---------------- scoreboard: the C reference model in step ----------------
    class scoreboard extends uvm_subscriber #(retire_item);
        `uvm_component_utils(scoreboard)
        int unsigned n, n_errors;
        bit          done;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void start(load_seq s);
            for (int w = 0; w < s.n_words; w++)
                scr1_ref_load(4 * w, {s.image[4*w+3], s.image[4*w+2], s.image[4*w+1], s.image[4*w]});
            if (!scr1_ref_start()) `uvm_fatal("SB", "reference model did not start")
        endfunction

        function void write(retire_item t);
            retire_item m = retire_item::type_id::create("m");
            int pc, pc_next, rd_addr, rd_wdata, trap;
            int mem_we, mem_wmask, mem_addr, mem_wdata, csrw_we, csrw_cmd, csrw_addr, csrw_data;
            string f = "";
            // counters (cycle, time, instret and their M- and high forms) depend on timing: the
            // model takes the value the core read
            if (t.csr_rd && t.csr_addr inside {12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82,
                                               12'hB00, 12'hB02, 12'hB80, 12'hB82})
                scr1_ref_timer(t.rd_wdata);
            scr1_ref_step_all(pc, pc_next, rd_addr, rd_wdata, trap,
                              mem_we, mem_wmask, mem_addr, mem_wdata, csrw_we, csrw_cmd, csrw_addr, csrw_data);
            m.pc = pc; m.pc_next = pc_next; m.rd_addr = rd_addr; m.rd_wdata = rd_wdata; m.trap = trap;
            m.mem_we = mem_we; m.mem_wmask = mem_wmask; m.mem_addr = mem_addr; m.mem_wdata = mem_wdata;
            m.csrw_we = csrw_we; m.csrw_cmd = csrw_cmd; m.csrw_addr = csrw_addr; m.csrw_data = csrw_data;
            n++;
            if      (t.pc       != m.pc)       f = "pc";
            else if (t.pc_next  != m.pc_next)  f = "pc_next";
            else if (t.rd_addr  != m.rd_addr)  f = "rd_addr";
            else if (t.rd_wdata != m.rd_wdata) f = "rd_wdata";
            else if (t.trap     != m.trap)     f = "trap";
            else if (t.mem_we    != m.mem_we)    f = "mem_we";
            else if (t.mem_wmask != m.mem_wmask) f = "mem_wmask";
            else if (t.mem_addr  != m.mem_addr)  f = "mem_addr";
            else if (t.mem_wdata != m.mem_wdata) f = "mem_wdata";
            else if (t.csrw_we   != m.csrw_we)   f = "csrw_we";
            else if (t.csrw_cmd  != m.csrw_cmd)  f = "csrw_cmd";
            else if (t.csrw_addr != m.csrw_addr) f = "csrw_addr";
            else if (t.csrw_data != m.csrw_data) f = "csrw_data";
            if (f != "") begin
                n_errors++;
                `uvm_error("SB", $sformatf("MISMATCH instruction #%0d field '%s': dut %s, model %s",
                                           n, f, t.convert2string(), m.convert2string()))
            end
            if (t.pc_next == SIM_EXIT) done = 1;
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf("%0d instructions compared, %0d errors%s", n, n_errors,
                                      done ? "" : " - the program did not reach SIM_EXIT"), UVM_NONE)
            if (!done) `uvm_error("SB", "program did not finish")
        endfunction
    endclass

    class env extends uvm_env;
        `uvm_component_utils(env)
        prog_agent   prog;
        retire_agent retire;
        scoreboard   sb;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            prog   = prog_agent::type_id::create("prog", this);
            retire = retire_agent::type_id::create("retire", this);
            sb     = scoreboard::type_id::create("sb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            retire.ap.connect(sb.analysis_export);
        endfunction
    endclass

    class prog_test extends uvm_test;
        `uvm_component_utils(prog_test)
        env e;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            e = env::type_id::create("e", this);
        endfunction
        task run_phase(uvm_phase phase);
            load_seq seq = load_seq::type_id::create("seq");
            string file;
            if (!$value$plusargs("PROG=%s", file)) `uvm_fatal("TEST", "give +PROG=<program.hex>")
            phase.raise_objection(this);
            seq.read(file);
            if (seq.n_words == 0) `uvm_fatal("TEST", $sformatf("%s: no program (file missing or empty)", file))
            `uvm_info("TEST", $sformatf("%s: %0d words", file, seq.n_words), UVM_LOW)
            e.sb.start(seq);
            seq.start(e.prog.sqr);
            wait (e.sb.done || e.sb.n_errors > 10);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
