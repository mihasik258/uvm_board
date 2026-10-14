// scr1_tb_pkg.sv - a UVM testbench for SCR1 as a verifier writes it: a sequence loads a program
// image, the retire monitor gives every committed instruction, the scoreboard runs a C reference
// model (DPI, scr1_ref_dpi.c) in step and compares. Nothing board-specific: the same file runs in
// simulation and, built with +define+OCV_BOARD, on the board against SCR1 in the FPGA.
//   +PROG=<file.hex>   program image ($readmemh, byte-addressed, e.g. objcopy -O verilog)
`include "uvm_macros.svh"

package scr1_tb_pkg;
    import uvm_pkg::*;
    import ocv_uvm_pkg::*;
    import scr1_ocv_uvm_pkg::*;

    import "DPI-C" function void scr1_ref_load(int addr, int data);
    import "DPI-C" function int  scr1_ref_start();
    import "DPI-C" function void scr1_ref_step(output int pc, output int pc_next, output int rd_addr,
                                               output int rd_wdata, output int trap);

    localparam int unsigned SIM_EXIT = 32'h0000_00F8;

    // the program image: words 0 .. last non-zero one; `last` on the final word starts the core
    class scr1_load_seq extends uvm_sequence #(scr1_program_item);
        `uvm_object_utils(scr1_load_seq)
        bit [7:0] image[65536];
        int unsigned n_words;
        function new(string name = "scr1_load_seq"); super.new(name); endfunction
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
                scr1_program_item t = scr1_program_item::type_id::create("t");
                start_item(t);
                t.addr = 14'(w);
                t.data = {image[4*w+3], image[4*w+2], image[4*w+1], image[4*w]};
                t.last = (w == 16383);
                finish_item(t);
            end
        endtask
    endclass

    class scr1_scoreboard extends uvm_subscriber #(scr1_retire_item);
        `uvm_component_utils(scr1_scoreboard)
        int unsigned n, n_errors;
        bit          done;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction

        function void start(scr1_load_seq s);
            for (int w = 0; w < s.n_words; w++)
                scr1_ref_load(4 * w, {s.image[4*w+3], s.image[4*w+2], s.image[4*w+1], s.image[4*w]});
            if (!scr1_ref_start()) `uvm_fatal("SB", "reference model did not start")
        endfunction

        function void write(scr1_retire_item t);
            scr1_retire_item m = scr1_retire_item::type_id::create("m");
            int pc, pc_next, rd_addr, rd_wdata, trap;
            string f = "";
            scr1_ref_step(pc, pc_next, rd_addr, rd_wdata, trap);
            m.pc = pc; m.pc_next = pc_next; m.rd_addr = rd_addr; m.rd_wdata = rd_wdata; m.trap = trap;
            n++;
            if      (t.pc       != m.pc)       f = "pc";
            else if (t.pc_next  != m.pc_next)  f = "pc_next";
            else if (t.rd_addr  != m.rd_addr)  f = "rd_addr";
            else if (t.rd_wdata != m.rd_wdata) f = "rd_wdata";
            else if (t.trap     != m.trap)     f = "trap";
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

    class scr1_env extends uvm_env;
        `uvm_component_utils(scr1_env)
        scr1_program_agent prog;
        scr1_retire_agent  retire;
        scr1_scoreboard    sb;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            prog    = scr1_program_agent::type_id::create("prog", this);
            retire  = scr1_retire_agent::type_id::create("retire", this);
            sb      = scr1_scoreboard::type_id::create("sb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            retire.ap.connect(sb.analysis_export);
        endfunction
    endclass

    class scr1_prog_test extends uvm_test;
        `uvm_component_utils(scr1_prog_test)
        scr1_env env;
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void build_phase(uvm_phase phase);
            env = scr1_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            scr1_load_seq seq = scr1_load_seq::type_id::create("seq");
            string file;
            if (!$value$plusargs("PROG=%s", file)) `uvm_fatal("TEST", "give +PROG=<program.hex>")
            phase.raise_objection(this);
            seq.read(file);
            if (seq.n_words == 0) `uvm_fatal("TEST", $sformatf("%s: no program (file missing or empty)", file))
            `uvm_info("TEST", $sformatf("%s: %0d words", file, seq.n_words), UVM_LOW)
            env.sb.start(seq);
            seq.start(env.prog.sqr);
            wait (env.sb.done || env.sb.n_errors > 10);
            phase.drop_objection(this);
        endtask
    endclass
endpackage
