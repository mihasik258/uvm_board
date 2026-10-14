#!/usr/bin/env python3
"""tb_top.py - core-v-verif's uvmt_cv32e40p_tb.sv for a core that runs in the FPGA (uvm_fast/run.sh):
a copy, changed only where the testbench reaches into the core's RTL - with the core in the FPGA those
signals are not in the simulation. Everything else (the env, its agents, the virtual peripherals, the
test, the interfaces and their config_db entries) stays as it is.

  - `bind cv32e40p_core ...`  (interrupt assertions on the core's internal registers) - left out;
  - `uvmt_cv32e40p_debug_assert u_debug_assert` (debug-mode and counter assertions on the core's
                                internals, through debug_cov_assert_if) - left out (the interface stays:
                                the env takes it from config_db);
  - `dut_wrap.<path>` reads    (the ISS step-and-compare synchronisation and the debug coverage/assertion
                                interface's ports, all inside the core) - a constant 0: the debug assertions
                                then see a core that never enters debug mode (none of these tests uses it),
                                the ISS stub nothing to step;
  - an event control on such a signal is dropped from its sensitivity list (`always @(x)` on it alone:
    the statement is left out).
What these checked is checked by OCV instead: every instruction against the reference model (the
interrupts it takes, the CSRs it reads, its stores and register writes).

    tb_top.py <uvmt_cv32e40p_tb.sv> <out.sv>
"""
import re, sys

src, out = sys.argv[1], sys.argv[2]
s = open(src).read()
n0 = len(re.findall(r"dut_wrap\.", s))

# the debug assertions on the core's internals
s, nd = re.subn(r"^\s*uvmt_cv32e40p_debug_assert\s+u_debug_assert\s*\(.*?\);\s*$",
                "  // OCV: debug assertions on the core's internals left out (the core is in the FPGA)", s, flags=re.S | re.M)
assert nd == 1, "u_debug_assert: not found once"

# the bind into the core's internals
s, nb = re.subn(r"^\s*bind\s+cv32e40p_core\b.*?\);\s*$", "  // OCV: bind into cv32e40p_core left out (the core is in the FPGA)",
                s, flags=re.S | re.M)
assert nb == 1, "bind cv32e40p_core: not found once"

PATH = r"dut_wrap\.[A-Za-z_][\w.]*(?:\[[^\]]*\][\w.]*)*"
# `always @(path) -> ev;` and `always @(path) stmt` on such a signal alone: left out
s, na = re.subn(r"^\s*always\s*@\(\s*" + PATH + r"\s*\)\s*->\s*[\w.]+\s*;\s*$",
                "    // OCV: event on the core's tracer left out", s, flags=re.M)
# `path or ...` / `... or path` in a sensitivity list
s = re.sub(PATH + r"\s+or\s+", "", s)
s = re.sub(r"\s+or\s+" + PATH, "", s)
# {path, 8'h00} (mtvec): a 32-bit zero
s = re.sub(r"\{\s*" + PATH + r"\s*,\s*8'h00\s*\}", "32'h0", s)
# any other read: a constant 0 (comments as they are)
def code_only(line):
    i = line.find("//")
    return line if i < 0 else re.sub(PATH, "'0", line[:i]) + line[i:]
s = "\n".join(re.sub(PATH, "'0", l) if "//" not in l else code_only(l) for l in s.split("\n"))

left = len(re.findall(r"dut_wrap\.", re.sub(r"//.*", "", s)))
assert left == 0, f"{left} references to dut_wrap internals left"
hdr = (f"// MADE by examples/cv32e40p/uvm_fast/tb_top.py from {src.split('/core-v-verif/')[-1]}: the core is in\n"
       f"// the FPGA - {n0} reads of its internals made 0, the bind into cv32e40p_core and u_debug_assert left\n"
       f"// out (see tb_top.py)\n")
open(out, "w").write(hdr + s)
print(f"tb_top: {n0} reads of dut_wrap internals -> 0 ({na} event controls dropped), bind into cv32e40p_core and "
      "u_debug_assert left out")
