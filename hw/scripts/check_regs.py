#!/usr/bin/env python3
"""check_regs.py - verify that the two halves of the OCV register contract agree:
hw/rtl/ocv_pkg.sv (hardware) and sw/include/ocv_regs.h (software).

Rule: every localparam in ocv_pkg has a counterpart named "OCV_" + name in the header,
  - *_ID / *_VERSION 32-bit values get a "_VALUE" suffix,
  - bit indices (int unsigned) appear as masks "(1u << n)",
  - everything else as a plain number.
So a register or field added on one side only is reported. Exit 0 = in sync.
"""
import os, re, sys

root = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
sv = open(os.path.join(root, "hw", "rtl", "ocv_pkg.sv")).read()
h  = open(os.path.join(root, "sw", "include", "ocv_regs.h")).read()

def sv_num(tok):
    m = re.fullmatch(r"(\d+)'([hd])([0-9A-Fa-f_]+)", tok)
    if m:
        return int(m.group(3).replace("_", ""), 16 if m.group(2) == "h" else 10)
    return int(tok)

hw = {}  # name -> (value, is_bit_index)
for name, val in re.findall(r"localparam\s+logic\s*\[[^\]]*\]\s+(\w+)\s*=\s*(\d+'[hd][0-9A-Fa-f_]+)", sv):
    hw[name] = (sv_num(val), False)
for name, val in re.findall(r"localparam\s+int\s+unsigned\s+(\w+)\s*=\s*(\d+)", sv):
    hw[name] = (int(val), True)

sw_num = {n: int(v, 0) for n, v in re.findall(r"#define\s+(OCV_\w+)\s+(0x[0-9A-Fa-f]+|\d+)u?\b", h)}
sw_bit = {n: int(b) for n, b in re.findall(r"#define\s+(OCV_\w+)\s+\(1u\s*<<\s*(\d+)\)", h)}

bad = 0
for name, (val, is_bit) in sorted(hw.items()):
    cname = "OCV_" + name + ("_VALUE" if re.search(r"_(ID|VERSION)$", name) and not name.startswith(("HUB_REG", "EP_REG")) else "")
    got = sw_bit.get(cname) if is_bit else sw_num.get(cname)
    if got is None:
        print(f"MISSING in C header: {cname} (for {name})"); bad += 1
    elif got != val:
        print(f"MISMATCH {name}={val:#x} vs {cname}={got:#x}"); bad += 1
print(f"REGS: IN SYNC ({len(hw)} constants)" if not bad else f"REGS: {bad} problem(s)")
sys.exit(1 if bad else 0)
