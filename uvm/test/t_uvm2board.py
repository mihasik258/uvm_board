#!/usr/bin/env python3
"""t_uvm2board.py - uvm2board.py on variants of the SCR1 scoreboard: each must either be translated
with exactly the comparison the scoreboard makes, or be left as it is with a reason - never
translated while something it does would be lost on the board."""
import json, os, re, subprocess, sys, tempfile

OCV = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EX = os.path.join(OCV, "examples", "scr1")
TB = open(os.path.join(EX, "uvm", "scr1_tb_pkg.sv")).read()
TOP = os.path.join(EX, "uvm", "tb_top.sv")
FULL = {"pc": "0xffffffff", "pc_next": "0xffffffff", "rd_addr": "0x1f", "rd_wdata": "0xffffffff", "trap": "0x1"}

CMP = '''            if      (t.pc       != m.pc)       f = "pc";
            else if (t.pc_next  != m.pc_next)  f = "pc_next";
            else if (t.rd_addr  != m.rd_addr)  f = "rd_addr";
            else if (t.rd_wdata != m.rd_wdata) f = "rd_wdata";
            else if (t.trap     != m.trap)     f = "trap";'''
assert CMP in TB


def sub(old, new):
    assert old in TB, old
    return TB.replace(old, new)


CASES = [
    ("as written", TB, FULL),
    ("subset (no trap)", sub('            else if (t.trap     != m.trap)     f = "trap";\n', ""),
     {k: v for k, v in FULL.items() if k != "trap"}),
    ("masked field", sub("(t.rd_wdata != m.rd_wdata)", "((t.rd_wdata & 'hFFFF) != (m.rd_wdata & 'hFFFF))"),
     dict(FULL, rd_wdata="0xffff")),
    ("one condition with ||", sub(CMP, '            if (t.pc != m.pc || t.pc_next != m.pc_next) f = "pc";'),
     {"pc": "0xffffffff", "pc_next": "0xffffffff"}),
    ("extra statement", sub("            n++;\n", "            n++;\n            hist[t.rd_addr]++;\n"), "write() does 'hist[t.rd_addr]++'"),
    ("per-transaction log", sub("            n++;\n", "            n++;\n            `uvm_info(\"SB\", t.convert2string(), UVM_HIGH)\n"),
     "write() does '@M:uvm_info'"),
    ("tolerance", sub("(t.rd_wdata != m.rd_wdata)", "(t.rd_wdata - m.rd_wdata > 1)"), "not exact equality"),
    ("generated mismatch()", sub(CMP, "            f = t.mismatch(m);"), "mismatch() of a generated item"),
    ("loop in write()", sub("            n++;\n", "            n++;\n            for (int i = 0; i < 2; i++) n++;\n"), "'for' in write()"),
    ("second subscriber", sub("            retire.ap.connect(sb.analysis_export);",
                              "            retire.ap.connect(sb.analysis_export);\n            retire.ap.connect(cov.analysis_export);")
     .replace("        scr1_scoreboard    sb;", "        scr1_scoreboard    sb;\n        scr1_cov           cov;"),
     "also feeds 'cov'"),
    ("model called conditionally", sub("            scr1_ref_step(pc,", "            if (n < 5) scr1_ref_step(pc,"), "called conditionally"),
]

fails = 0
with tempfile.TemporaryDirectory() as d:
    for name, text, want in CASES:
        tb = os.path.join(d, "tb.sv")
        open(tb, "w").write(text)
        out = os.path.join(d, "o")
        r = subprocess.run([sys.executable, os.path.join(OCV, "uvm", "uvm2board.py"), os.path.join(EX, "scr1.json"),
                            tb, TOP, "-o", out], capture_output=True, text=True)
        sb = json.load(open(os.path.join(out, "board_map.json")))["scoreboard"] or {}
        if isinstance(want, dict):
            ok = r.returncode == 0 and not sb.get("refused") and sb.get("compare") == want \
                 and os.path.exists(os.path.join(out, "board_ref.c"))
            got = sb.get("compare") or sb.get("refused")
        else:
            ok = r.returncode == 0 and want in (sb.get("refused") or "") and "_board extends scr1_scoreboard" \
                 not in open(os.path.join(out, "board_overlay.sv")).read()
            got = sb.get("refused") or sb.get("compare")
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")
        fails += not ok
        if os.path.exists(os.path.join(out, "board_ref.c")):
            os.remove(os.path.join(out, "board_ref.c"))
print(f"uvm2board tests: {'PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
