#!/usr/bin/env python3
"""t_tbparse.py - tbparse.py on variants of the verifier-style SCR1 testbench (examples/scr1/uvm_v):
the written one must give the same channels as the old hand-written description (scr1.json); a
driver, monitor or top the hub cannot be built from must be an error that says why."""
import json, os, sys

OCV = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(OCV, "uvm"))
import tbparse  # noqa: E402

V = os.path.join(OCV, "examples", "scr1", "uvm_v")
IF, PKG, TOP = (open(os.path.join(V, f)).read() for f in ("scr1_if.sv", "scr1_pkg.sv", "tb_top.sv"))


def sig(d):
    return sorted((c["kind"], c.get("valid"), c.get("ready"), tuple((f["port"], f["width"]) for f in c["fields"]))
                  for c in d["channels"])


REF = json.load(open(os.path.join(OCV, "examples", "scr1", "scr1.json")))
# the verifier-style testbench also samples which CSR an instruction read (for timer values) ...
next(c for c in REF["channels"] if c["name"] == "retire")["fields"] += [
    {"name": "csr_rd", "port": "rvfi_csr_rd", "width": 1}, {"name": "csr_addr", "port": "rvfi_csr_addr", "width": 12},
    # ... and what it stored and wrote to CSRs (as RVFI's rvfi_mem_* / rvfi_csr_*)
    {"name": "mem_we", "port": "rvfi_mem_we", "width": 1}, {"name": "mem_wmask", "port": "rvfi_mem_wmask", "width": 4},
    {"name": "mem_addr", "port": "rvfi_mem_addr", "width": 32}, {"name": "mem_wdata", "port": "rvfi_mem_wdata", "width": 32},
    {"name": "csrw_we", "port": "rvfi_csrw_we", "width": 1}, {"name": "csrw_cmd", "port": "rvfi_csrw_cmd", "width": 2},
    {"name": "csrw_addr", "port": "rvfi_csrw_addr", "width": 12}, {"name": "csrw_data", "port": "rvfi_csrw_data", "width": 32}]


def sub(text, old, new):
    assert old in text, old
    return text.replace(old, new)


CASES = [
    ("as written", IF, PKG, TOP, None),
    ("driver: no ready", IF, sub(PKG, "do @(posedge vif.clk); while (!vif.prog_ready);", "@(posedge vif.clk);"), TOP,
     "does not wait for a ready"),
    ("driver: drives a computed value", IF, sub(PKG, "vif.prog_data  <= t.data;", "vif.prog_data  <= t.data ^ 1;"), TOP,
     "does more than drive the item"),
    ("driver: no valid", IF, sub(PKG, "                vif.prog_valid <= 1'b0;\n                seq_item_port.item_done();",
                                  "                seq_item_port.item_done();"), TOP, "no single valid"),
    ("monitor: counts", IF, sub(PKG, "                    ap.write(t);", "                    ap.write(t);\n                    n_seen++;"), TOP,
     "does more than copy pins"),
    ("monitor: condition on a variable", IF, sub(PKG, "if (vif.rst_n && vif.rvfi_valid)", "if (vif.rvfi_valid && enabled)"), TOP,
     "is not a vif signal"),
    ("top: no clock generator", IF, PKG, sub(TOP, "always #5 clk = ~clk;", ""), "no clock found"),
    ("top: pin not wired", IF, PKG, sub(TOP, "        .rvfi_trap     (vif.rvfi_trap)", "        .rvfi_trap     ()"),
     "not connected to a DUT port"),
]

fails = 0
for name, i, p, t, want in CASES:
    try:
        d = tbparse.parse([i, p, t], "tb_top")
        got = "ok"
        ok = want is None and sig(d) == sig(REF) and d["reset"] == REF["reset"] and d["clock"] == REF["clock"]
    except tbparse.TbError as e:
        got = str(e)
        ok = want is not None and want in got
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {got}")
    fails += not ok
print(f"tbparse tests: {'PASS' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
