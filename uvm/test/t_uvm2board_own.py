#!/usr/bin/env python3
"""t_uvm2board_own.py - uvm2board.py (no description file) on scoreboard styles of the
verifier-style SCR1 testbench (examples/scr1/uvm_v): each must be translated with exactly the
comparison it makes, or left as it is with the reason - never translated with a different meaning."""
import json, os, re, subprocess, sys, tempfile

OCV = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
V = os.path.join(OCV, "examples", "scr1", "uvm_v")
IF, PKG, TOP = (os.path.join(V, f) for f in ("scr1_if.sv", "scr1_pkg.sv", "tb_top.sv"))
TB = open(PKG).read()
FULL = {"pc": "0xffffffff", "pc_next": "0xffffffff", "rd_addr": "0x1f", "rd_wdata": "0xffffffff", "trap": "0x1",
        "mem_we": "0x1", "mem_wmask": "0xf", "mem_addr": "0xffffffff", "mem_wdata": "0xffffffff",
        "csrw_we": "0x1", "csrw_cmd": "0x3", "csrw_addr": "0xfff", "csrw_data": "0xffffffff"}

CMP = '''            if      (t.pc       != m.pc)       f = "pc";
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
            end'''
ITEM = '''            return s;
        endfunction
    endclass'''
assert CMP in TB and ITEM in TB


def sub(text, old, new):
    assert old in text, old
    return text.replace(old, new)


ERR = '''begin
                n_errors++;
                `uvm_error("SB", $sformatf("MISMATCH #%0d: dut %s, model %s", n, t.convert2string(), m.convert2string()))
            end'''
DO_COMPARE = ITEM.replace("    endclass", '''        function bit do_compare(uvm_object rhs, uvm_comparer comparer);
            retire_item o;
            return $cast(o, rhs) && super.do_compare(rhs, comparer) &&
                   pc == o.pc && pc_next == o.pc_next && rd_addr == o.rd_addr && rd_wdata == o.rd_wdata;
        endfunction
    endclass''')
MACROS = TB.replace('''        `uvm_object_utils(retire_item)
''', "").replace('''        function new(string name = "retire_item"); super.new(name); endfunction''', '''        `uvm_object_utils_begin(retire_item)
            `uvm_field_int(pc, UVM_ALL_ON)
            `uvm_field_int(pc_next, UVM_ALL_ON)
            `uvm_field_int(rd_addr, UVM_ALL_ON)
            `uvm_field_int(rd_wdata, UVM_ALL_ON)
            `uvm_field_int(trap, UVM_ALL_ON | UVM_NOCOMPARE)
            `uvm_field_int(csr_rd, UVM_ALL_ON | UVM_NOCOMPARE)
            `uvm_field_int(csr_addr, UVM_ALL_ON | UVM_NOCOMPARE)
            `uvm_field_int(mem_we, UVM_ALL_ON)
            `uvm_field_int(mem_wmask, UVM_ALL_ON)
            `uvm_field_int(mem_addr, UVM_ALL_ON)
            `uvm_field_int(mem_wdata, UVM_ALL_ON)
            `uvm_field_int(csrw_we, UVM_ALL_ON)
            `uvm_field_int(csrw_cmd, UVM_ALL_ON)
            `uvm_field_int(csrw_addr, UVM_ALL_ON)
            `uvm_field_int(csrw_data, UVM_ALL_ON)
        `uvm_object_utils_end
        function new(string name = "retire_item"); super.new(name); endfunction''')
assert MACROS.count("uvm_field_int") == 15

COV = """    class retire_cov extends uvm_subscriber #(retire_item);
        `uvm_component_utils(retire_cov)
        int unsigned n, rd_hits[32];
        function new(string name, uvm_component parent); super.new(name, parent); endfunction
        function void write(retire_item t);
            n++;
            rd_hits[t.rd_addr]++;
        endfunction
        function void report_phase(uvm_phase phase);
            int unsigned seen = 0;
            foreach (rd_hits[i]) if (rd_hits[i] != 0) seen++;
            `uvm_info("COV", $sformatf("%0d sampled, %0d of 32 registers written, x5 %0d times", n, seen, rd_hits[5]), UVM_NONE)
        endfunction
    endclass

    class env extends uvm_env;"""


def with_cov(text, body=None):
    t = sub(text, "    class env extends uvm_env;", COV if body is None else COV.replace("rd_hits[t.rd_addr]++;", body))
    t = sub(t, "        scoreboard   sb;\n", "        scoreboard   sb;\n        retire_cov   cov;\n")
    t = sub(t, '            sb     = scoreboard::type_id::create("sb", this);\n',
            '            sb     = scoreboard::type_id::create("sb", this);\n            cov    = retire_cov::type_id::create("cov", this);\n')
    return sub(t, "            retire.ap.connect(sb.analysis_export);",
               "            retire.ap.connect(sb.analysis_export);\n            retire.ap.connect(cov.analysis_export);")


NOTRAP = sub(TB, '            else if (t.trap     != m.trap)     f = "trap";\n', "")

CASES = [
    ("as written", TB, FULL),
    ("compare() + do_compare", sub(sub(TB, ITEM, DO_COMPARE), CMP, "            if (!t.compare(m)) " + ERR),
     {k: FULL[k] for k in ("pc", "pc_next", "rd_addr", "rd_wdata")}),
    ("compare() + field macros", sub(MACROS, CMP, "            if (!t.compare(m)) " + ERR),
     {k: v for k, v in FULL.items() if k != "trap"}),
    ("assert ... else", sub(TB, CMP, "            assert (t.pc == m.pc && t.rd_wdata == m.rd_wdata) else " + ERR),
     {"pc": FULL["pc"], "rd_wdata": FULL["rd_wdata"]}),
    ("!==", sub(TB, "(t.pc       != m.pc)", "(t.pc       !== m.pc)"), FULL),
    ("if (all equal) ; else", sub(TB, CMP, "            if (t.pc == m.pc && t.pc_next == m.pc_next && t.trap == m.trap) ;\n            else " + ERR),
     {"pc": FULL["pc"], "pc_next": FULL["pc_next"], "trap": FULL["trap"]}),
    ("error count per field", sub(TB, CMP, "            if (t.pc != m.pc) " + ERR + "\n            if (t.rd_wdata != m.rd_wdata) " + ERR),
     "error counter is increased in more than one place"),
    ("assert without else", sub(TB, CMP, "            assert (t.pc == m.pc);"), "assert without an else branch"),
    ("expected from an expression", sub(TB, "m.pc = pc;", "m.pc = pc + 4;"), "write() does"),
    ("coverage of compared fields", with_cov(TB), dict(FULL, _deliver=True)),
    ("timer value handed to the model", TB, dict(FULL, _observe=3)),
    ("timer value after the model's step", sub(sub(TB, """                scr1_ref_timer(t.rd_wdata);
            scr1_ref_step_all(""", """                ;
            scr1_ref_step_all("""), "csrw_cmd, csrw_addr, csrw_data);\n",
        "csrw_cmd, csrw_addr, csrw_data);\n            if (t.csr_rd) scr1_ref_timer(t.rd_wdata);\n"), "comes after the model's step"),
    ("timer value not a field", sub(TB, "scr1_ref_timer(t.rd_wdata);", "scr1_ref_timer(t.rd_wdata + 1);"),
     "not a field of the DUT's item"),
    ("tolerance |dut - model| > 2", sub(TB, "(t.rd_wdata != m.rd_wdata)",
                                         "((t.rd_wdata > m.rd_wdata ? t.rd_wdata - m.rd_wdata : m.rd_wdata - t.rd_wdata) > 2)"),
     dict(FULL, rd_wdata="abs:2")),
    ("tolerance written with >=", sub(TB, "(t.rd_wdata != m.rd_wdata)",
                                      "((m.rd_wdata >= t.rd_wdata ? m.rd_wdata - t.rd_wdata : t.rd_wdata - m.rd_wdata) >= 4)"),
     dict(FULL, rd_wdata="abs:3")),
    ("difference that wraps", sub(TB, "(t.rd_wdata != m.rd_wdata)", "(t.rd_wdata - m.rd_wdata > 2 || m.rd_wdata - t.rd_wdata > 2)"),
     "not exact equality"),
    ("coverage of a field not compared", with_cov(NOTRAP, "if (t.trap) rd_hits[0]++;"), "reads trap, not compared"),
    ("coverage takes the whole item", with_cov(TB, "q.push_back(t);"), "uses the retire_item as a whole"),
]

fails = 0
with tempfile.TemporaryDirectory() as d:
    for name, text, want in CASES:
        tb = os.path.join(d, "scr1_pkg.sv")
        open(tb, "w").write(text)
        out = os.path.join(d, "o")
        r = subprocess.run([sys.executable, os.path.join(OCV, "uvm", "uvm2board.py"), IF, tb, TOP, "-o", out],
                           capture_output=True, text=True)
        sb = (json.load(open(os.path.join(out, "board_map.json")))["scoreboard"] or {}) if r.returncode == 0 else {}
        if isinstance(want, dict):
            want = dict(want)
            dl = want.pop("_deliver", False)
            nob = want.pop("_observe", None)
            ok = r.returncode == 0 and not sb.get("refused") and sb.get("compare") == want and bool(sb.get("deliver")) == dl \
                and (nob is None or len((sb.get("observe") or {}).get("patterns", [])) == nob)
            got = sb.get("compare") or sb.get("refused") or r.stderr.strip()[-200:]
        else:
            ok = r.returncode == 0 and want in (sb.get("refused") or "")
            got = sb.get("refused") or sb.get("compare") or r.stderr.strip()[-200:]
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")
        fails += not ok
        for f in ("board_ref.c", "board_map.json"):
            if os.path.exists(os.path.join(out, f)):
                os.remove(os.path.join(out, f))
print(f"uvm2board own-agent tests: {'PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
