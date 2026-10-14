#!/usr/bin/env python3
"""prof_report.py - report of an ocv_prof sample file (uvm/vlt/ocv_prof.c) with the symbols of the
same binary: where the CPU time goes, by function (self = the sampled function itself, total = the
function or anything it called), and by group (UVM library, Verilator runtime, allocator, OCV, ...).

    prof_report.py <binary> <samples.txt> [--top N] [--addr2line aarch64-linux-gnu-addr2line]
"""
import argparse, collections, re, subprocess, sys


def symbols(binary, addrs, tool):
    out = {}
    addrs = sorted(addrs)
    for i in range(0, len(addrs), 2000):
        chunk = addrs[i:i + 2000]
        r = subprocess.run([tool, "-f", "-C", "-e", binary] + [hex(a) for a in chunk],
                           capture_output=True, text=True)
        lines = r.stdout.splitlines()
        for j, a in enumerate(chunk):
            out[a] = lines[2 * j] if 2 * j < len(lines) else "??"
    return out


GROUPS = [  # (group, regex on the demangled name), first match wins
    ("allocator", r"mi_|_mi_|malloc|free|operator new|operator delete|_int_|calloc|realloc"),
    ("strings", r"basic_string|char_traits|memcmp|memcpy|memmove|strlen|strcmp|to_string|VL_SFORMAT|sformat"),
    ("verilator scheduler", r"VlCoroutine|VlDynamicTrigger|VlPromise|VlDelay|_eval|timing_resume|VerilatedEvalLoop|VlProcess|VlTrigger"),
    ("verilator runtime", r"^Vl|^VL_|verilated|Verilated"),
    ("uvm factory/registry", r"uvm_factory|uvm_default_factory|registry|create_object|create_by_type|uvm_object_wrapper"),
    ("uvm seeding/naming", r"reseed|get_full_name|get_name|uvm_create_random_seed|uvm_object_string_pool|uvm_oneway_hash"),
    ("uvm sequence/sequencer", r"uvm_sequence|uvm_sequencer|seq_item|uvm_sequence_item"),
    ("uvm tlm/analysis", r"uvm_analysis|uvm_port|uvm_tlm|analysis_imp|uvm_subscriber"),
    ("uvm other", r"uvm_"),
    ("ocv", r"ocv_|Vtb_top_ocv_uvm_pkg"),
    ("randomize", r"randomize|VlRandom|ocv_fast"),
    ("model (dpi)", r"cpu_|rv32_|scr1_ref|spike"),
    ("testbench", r"Vtb_top"),
]


def group(name):
    for g, rx in GROUPS:
        if re.search(rx, name):
            return g
    return "other"


def short(name):
    name = re.sub(r"\(.*", "", name)
    name = name.replace("Vtb_top_", "").replace("__03a__03a", "::")
    return name[:110]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("samples")
    ap.add_argument("--top", type=int, default=25)
    ap.add_argument("--addr2line", default="aarch64-linux-gnu-addr2line")
    a = ap.parse_args()
    stacks, off = [], 0
    for line in open(a.samples):
        if line.startswith("#"):
            m = re.search(r"ref_dump=([0-9a-f]+)", line)
            if m:                                        # position-independent binary: load offset
                nm = subprocess.run([a.addr2line.replace("addr2line", "nm"), a.binary],
                                    capture_output=True, text=True).stdout
                fm = re.search(r"^([0-9a-f]+) t (?:dump|_ZL4dumpv)$", nm, re.M)
                if fm:
                    off = int(m.group(1), 16) - int(fm.group(1), 16)
            continue
        if not line.strip():
            continue
        stacks.append([int(x, 16) - off for x in line.split()])
    n = len(stacks)
    if not n:
        sys.exit("no samples")
    addrs = {x for s in stacks for x in s}
    sym = symbols(a.binary, addrs, a.addr2line)
    self_c, total_c, grp_c = collections.Counter(), collections.Counter(), collections.Counter()
    for s in stacks:
        names = [sym.get(x, "??") for x in s]
        self_c[short(names[0])] += 1
        grp_c[group(names[0])] += 1
        for nm in set(short(x) for x in names):
            total_c[nm] += 1
    print(f"{n} samples")
    print("\nby group (self time):")
    for g, c in grp_c.most_common():
        print(f"  {100.0 * c / n:5.1f}%  {g}")
    print(f"\ntop {a.top} functions, self time:")
    for nm, c in self_c.most_common(a.top):
        print(f"  {100.0 * c / n:5.1f}%  {nm}")
    print(f"\ntop {a.top} functions, total (with callees, where the stack was recovered):")
    for nm, c in total_c.most_common(a.top):
        print(f"  {100.0 * c / n:5.1f}%  {nm}")


if __name__ == "__main__":
    main()
