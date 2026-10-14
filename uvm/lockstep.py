#!/usr/bin/env python3
"""lockstep.py - a testbench as it is on the board: the DUT in the FPGA advances one clock per clock of
the testbench, the testbench (every agent, monitor, assertion) runs on the processor unchanged.

The DUT module the testbench instantiates is replaced, on the processor, by a bridge with the same name,
parameters and ports. Between two rising edges of its clock (at time 0 and at every falling edge) the
bridge sends the DUT's inputs to the FPGA, where the DUT makes exactly one clock (it is frozen without
an input record), and sets the outputs that clock produced: the testbench samples at the next rising
edge what it would sample from the DUT itself.

Signals inside the DUT that the testbench reads (hierarchical references to the DUT instance, and the
ports of modules it binds into DUT modules) come from the FPGA every clock too ("probes"): the bridge
holds a shadow of that part of the hierarchy - same instance names, the bound module's name - so the
references, the binds, their assertions and coverage work on the FPGA's values. A path that is not in
the FPGA (a simulation-only module of the DUT, or one named with --no-probe) keeps its default value and
is listed.

    lockstep.py --tb <tb files...> --dut <module> --rtl <DUT RTL files...> [--fpga-module M --fpga-inst I]
                [-I dir] [-D define] [--no-probe path ...] -o <out dir>

  --dut          the module the testbench instantiates as the DUT (replaced by the bridge)
  --fpga-module  what the FPGA runs in its place (default --dut): a synthesizable module that --dut
  --fpga-inst    instantiates as <inst> with the same ports (.*), e.g. cv32e40p_core as core_i
Out: <dut>_ocv_ls.sv (FPGA), <dut>_ls.json (the hub's channels, for ocv_gen.py), <dut>_bridge.sv
(processor), report.txt.
"""
import argparse, json, os, re, subprocess, sys, tempfile

REC_MAX = 1024          # bits per record of the UVM layer (OCV_UVM_REC_BITS)
VERILATOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "verilator", "install",
                         "bin", "verilator")


class LsError(Exception):
    pass


# ---------------------------------------------------------------- the DUT, elaborated by Verilator
class Tree:
    """Verilator's JSON tree of the DUT: modules, instances, variables and their widths"""

    def __init__(self, path):
        d = json.load(open(path))
        self.idx = {}
        self._index(d)
        self.mods = {m["name"]: m for m in d["modulesp"] if m.get("type") == "MODULE"}

    def _index(self, n):
        if isinstance(n, dict):
            if n.get("addr"):
                self.idx[n["addr"]] = n
            for v in n.values():
                self._index(v)
        elif isinstance(n, list):
            for v in n:
                self._index(v)

    @staticmethod
    def _members(n, types):
        out = []

        def walk(x, top):
            if isinstance(x, dict):
                if not top and x.get("type") == "MODULE":
                    return
                if x.get("type") in types:
                    out.append(x)
                for k, v in x.items():
                    if k not in ("dtypep",):
                        walk(v, False)
            elif isinstance(x, list):
                for v in x:
                    walk(v, False)
        walk(n, True)
        return out

    def module_of(self, modname):
        if modname not in self.mods:
            raise LsError(f"module {modname} not in the elaborated DUT")
        return self.mods[modname]

    def var(self, mod, name):
        for v in self._members(mod, ("VAR",)):
            if v["name"] == name:
                return v
        return None

    def cell(self, mod, name):
        for c in self._members(mod, ("CELL",)):
            if c["name"] == name:
                return self.idx[c["modp"]]
        return None

    def cells(self, mod):
        return [(c["name"], self.idx[c["modp"]]) for c in self._members(mod, ("CELL",))]

    def dtype(self, a):
        n = self.idx[a]
        while n["type"] in ("REFDTYPE",) or (n["type"] == "TYPEDEF"):
            n = self.idx[n.get("refDTypep") or n["dtypep"]]
        return n

    def width(self, a):
        n = self.dtype(a)
        t = n["type"]
        if t == "BASICDTYPE":
            r = n.get("range")
            if r:
                hi, lo = (int(x) for x in r.split(":"))
                return abs(hi - lo) + 1
            return {"int": 32, "integer": 32, "shortint": 16, "longint": 64, "byte": 8}.get(n.get("keyword"), 1)
        if t == "PACKARRAYDTYPE":
            hi, lo = (int(x) for x in n["declRange"].strip("[]").split(":"))
            return (abs(hi - lo) + 1) * self.width(n["refDTypep"])
        if t == "ENUMDTYPE":
            return self.width(n.get("refDTypep") or n["dtypep"])
        if t in ("STRUCTDTYPE", "UNIONDTYPE"):
            ws = [self.width(m["dtypep"]) for m in n.get("membersp", [])]
            return sum(ws) if t == "STRUCTDTYPE" else max(ws)
        raise LsError(f"width of a {t} not handled")

    def select(self, a, sel):
        """dtype after one select: '[i]' of an array, '.m' of a struct"""
        n = self.dtype(a)
        if sel.startswith("["):
            if n["type"] in ("PACKARRAYDTYPE", "UNPACKARRAYDTYPE"):
                return n["refDTypep"]
            if n["type"] == "BASICDTYPE":
                return None                                   # a bit of a vector
            raise LsError(f"index into a {n['type']}")
        for m in n.get("membersp", []):
            if m["name"] == sel[1:]:
                return m["dtypep"]
        raise LsError(f"no member {sel[1:]}")


def elaborate(rtl, incs, defines, top, out):
    """Verilator --json-only of the DUT"""
    cmd = [VERILATOR, "--json-only", "-Wno-fatal", "-Wno-lint", "-Wno-style", "--top-module", top, "--Mdir", out]
    cmd += [f"+incdir+{i}" for i in incs] + [f"+define+{d}" for d in defines] + rtl
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise LsError("Verilator could not elaborate the DUT:\n" + "\n".join(
            l for l in (r.stdout + r.stderr).splitlines() if "%Error" in l)[:2000])
    return Tree(os.path.join(out, f"V{top}.tree.json"))


# ---------------------------------------------------------------- what the testbench reads inside the DUT
def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


PATH = r"[A-Za-z_]\w*(?:\s*\[\s*\d+\s*\])*(?:\s*\.\s*[A-Za-z_]\w*(?:\s*\[\s*\d+\s*\])*)*"


def norm(p):
    return re.sub(r"\s+", "", p)


def module_ports(text, mod):
    m = re.search(r"\bmodule\s+" + mod + r"\b\s*(?:import\s+[\w:*,\s]+;\s*)*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?"
                  r"(?:import\s+[\w:*,\s]+;\s*)*\((.*?)\)\s*;", text, re.S)
    if not m:
        return None
    names = []
    for d in m.group(1).split(","):
        w = re.findall(r"[A-Za-z_]\w*", re.sub(r"\[[^\]]*\]", "", d))
        if w:
            names.append(w[-1])
    return names


def references(tb, dut):
    """(instance of the DUT, [(path relative to the DUT, where)], [(bound module, assertion module,
    {port: path relative to the bound module's scope})]) from the testbench sources"""
    text = strip_comments(tb)
    inst = re.findall(r"\b" + dut + r"\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?([A-Za-z_]\w*)\s*\(", text)
    if len(set(inst)) != 1:
        raise LsError(f"{dut} must be instantiated once in the testbench (found {inst or 'none'})")
    inst = inst[0]
    refs = []
    for m in re.finditer(r"\b" + inst + r"\s*\.\s*(" + PATH + ")", text):
        line = text.count("\n", 0, m.start()) + 1
        refs.append((norm(m.group(1)), line))
    binds = []
    for m in re.finditer(r"\bbind\s+(\w+)\s+(\w+)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?(\w+)\s*\((.*?)\)\s*;", text, re.S):
        target, amod, _, conns = m.groups()
        ports = module_ports(text, amod) or []
        given = {}
        for p, e in re.findall(r"\.(\w+)\s*\(\s*(" + PATH + r")?\s*\)", conns):
            given[p] = norm(e) if e else None
        if re.search(r"\.\*", conns):
            for p in ports:
                given.setdefault(p, p)
        binds.append((target, amod, {p: e for p, e in given.items() if e}))
    return inst, refs, binds


# ---------------------------------------------------------------- probes
def split_path(p):
    """'a.b[2].c' -> ['a', 'b', '[2]', '.c'] relative steps: instance names first, then the variable and
    its selects"""
    return re.findall(r"\[\d+\]|\.?[A-Za-z_]\w*", p)


class Probe:
    def __init__(self, path, inst_path, var, sels, width):
        self.path, self.inst_path, self.var, self.sels, self.width = path, inst_path, var, sels, width
        self.port = "p_" + re.sub(r"\W+", "_", path).strip("_")


def resolve(tree, root_mod, path):
    """a path below root_mod -> Probe; None if it is not there (a simulation-only part)"""
    steps = split_path(path)
    mod, insts = root_mod, []
    i = 0
    while i < len(steps):
        s = steps[i].lstrip(".")
        sub = tree.cell(mod, s)
        if sub is None:
            break
        mod, insts = sub, insts + [s]
        i += 1
    if i == len(steps):
        return "instance"
    v = tree.var(mod, steps[i].lstrip("."))
    if v is None:
        return None
    a, sels = v["dtypep"], steps[i + 1:]
    for s in sels:
        a2 = tree.select(a, s)
        if a2 is None:                       # a bit select of a vector: the whole vector is probed
            sels = sels[:sels.index(s)]
            break
        a = a2
    w = tree.width(a)
    var = steps[i].lstrip(".")
    return Probe(".".join(insts + [var]) + "".join(sels), insts, var, sels, w)


# ---------------------------------------------------------------- generation
def fields(sigs):
    """[(name, port, width)] -> channel fields (<= 64 bits each: wider ports in slices)"""
    out = []
    for name, port, w in sigs:
        if w <= 64:
            out.append({"name": name, "port": port, "width": w})
        else:
            for lo in range(0, w, 64):
                hi = min(w, lo + 64) - 1
                out.append({"name": f"{name}_{lo}", "port": port, "width": hi - lo + 1, "slice": [hi, lo]})
    return out


def chunks(sigs, limit=REC_MAX):
    """split signals into records of at most `limit` bits (a signal is never split across records)"""
    out, cur, bits = [], [], 0
    for s in sigs:
        if s[2] > limit:
            raise LsError(f"{s[0]}: {s[2]} bits, more than one record ({limit})")
        if bits + s[2] > limit:
            out.append(cur)
            cur, bits = [], 0
        cur.append(s)
        bits += s[2]
    if cur:
        out.append(cur)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--tb", nargs="+", required=True)
    ap.add_argument("--dut", required=True)
    ap.add_argument("--rtl", nargs="+", required=True)
    ap.add_argument("--fpga-module")
    ap.add_argument("--fpga-inst")
    ap.add_argument("-I", action="append", default=[], dest="incs")
    ap.add_argument("-D", action="append", default=[], dest="defines")
    ap.add_argument("--no-probe", nargs="*", default=[])
    ap.add_argument("--clock", action="append", default=[], metavar="PATH=EXPR",
                    help="a clock inside the DUT the testbench reads: built on the processor from EXPR (ports of the "
                         "DUT and probes, e.g. 'core_i.clk=clk_i & core_i.sleep_unit_i.clock_en'), not sampled")
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    try:
        run(a)
    except LsError as e:
        print(f"lockstep: {e}", file=sys.stderr)
        sys.exit(2)


def run(a):
    tb = "\n".join(open(f, errors="replace").read() for f in a.tb)
    tree = elaborate(a.rtl, a.incs, a.defines, a.dut, os.path.join(a.out, "json"))
    dut_mod = tree.module_of(a.dut)
    ports = [v for v in Tree._members(dut_mod, ("VAR",)) if v.get("varType") == "PORT"]
    clock = [p["name"] for p in ports if re.fullmatch(r"clk\w*|clock\w*", p["name"]) and p["direction"] == "INPUT"]
    if len(clock) != 1:
        raise LsError(f"{a.dut}: one clock input expected (found {clock})")
    clock = clock[0]
    ins = [(p["name"], p["name"], tree.width(p["dtypep"])) for p in ports if p["direction"] == "INPUT" and p["name"] != clock]
    outs = [(p["name"], p["name"], tree.width(p["dtypep"])) for p in ports if p["direction"] == "OUTPUT"]
    params = [v for v in Tree._members(dut_mod, ("VAR",)) if v.get("varType") == "GPARAM"]

    # probes: below the DUT (refs) and in the scopes of bound modules
    inst, refs, binds = references(tb, a.dut)
    fmod = tree.module_of(a.fpga_module) if a.fpga_module else dut_mod
    probes, shadow_only, missing, report = {}, {}, [], []
    clocks = {}                                     # path -> expression on the processor
    for spec in a.clock:
        p, _, e = spec.partition("=")
        clocks[norm(p)] = e.strip() or clock

    def want(path, why):
        if path in clocks or re.fullmatch(r"(?:\w+\.)*\w*clk\w*", path):
            if path not in clocks:
                clocks[path] = clock
                report.append(f"{path} ({why}): a clock - taken as the DUT's {clock} (give --clock to build it otherwise)")
            pr = resolve(tree, dut_mod, path)
            if pr not in (None, "instance"):
                shadow_only.setdefault(pr.path, pr)
            return
        pr = resolve(tree, dut_mod, path)
        if pr is None:
            raise LsError(f"{path} ({why}): not a signal of {a.dut}")
        if pr == "instance":                     # a scope (e.g. a macro's prefix); its signals are used elsewhere
            report.append(f"{path} ({why}): an instance, not a signal - references through it are not seen here")
            return
        if any(path == n or path.startswith(n + ".") or path.startswith(n + "[") for n in a.no_probe):
            missing.append((path, f"{why}; left out (--no-probe)"))
            shadow_only.setdefault(pr.path, pr)
            return
        if a.fpga_inst and not path.startswith(a.fpga_inst + "."):
            missing.append((path, f"{why}; not in the FPGA's {a.fpga_module} (simulation-only part of {a.dut})"))
            shadow_only.setdefault(pr.path, pr)
            return
        probes.setdefault(pr.path, pr)

    for path, line in refs:
        if "." not in path and "[" not in path and any(path == p[0] for p in ins + outs):
            continue                                            # a port: the bridge has it anyway
        want(path, f"testbench line {line}")
    bound = []                                                   # (scope path, module name)
    for target, amod, conns in binds:
        scopes = []

        def find(mod, pre):
            for n, sub in tree.cells(mod):
                if sub["name"].split("__")[0] == target or sub.get("origName") == target:
                    scopes.append(pre + [n])
                find(sub, pre + [n])
        find(dut_mod, [])
        if not scopes:
            report.append(f"bind {target} {amod}: into the testbench's own {target}, not the DUT - as it is")
            continue
        for sc in scopes:
            bound.append((".".join(sc), target))
            for p, e in conns.items():
                want(".".join(sc) + "." + e, f"bind {target} {amod}.{p}")

    for p, e in clocks.items():
        for ref in re.findall(PATH, e):
            if "." in ref:
                want(norm(ref), f"clock {p}")
    probes = sorted(probes.values(), key=lambda p: p.path)
    psigs = [(pr.port, pr.port, pr.width) for pr in probes]
    in_recs, out_recs = chunks(ins), chunks(outs + psigs)

    # ---- FPGA side
    fm = a.fpga_module or a.dut
    fi = a.fpga_inst or "u_dut"
    L = [f"// GENERATED by lockstep.py: {a.dut} one clock per input record (the testbench's clock), outputs",
         f"// and probes of that clock out. The DUT is frozen while no input record is there.",
         f"module {a.dut}_ocv_ls (",
         "    input  logic clk, rst_n,"]
    for k, rec in enumerate(in_recs):
        L.append(f"    input  logic pi{k}_valid, output logic pi{k}_ready,")
    for k, rec in enumerate(out_recs):
        L.append(f"    output logic po{k}_valid,")
    for n, p, w in ins:
        L.append(f"    input  logic [{w - 1}:0] {p},")
    for n, p, w in outs + psigs:
        L.append(f"    output logic [{w - 1}:0] {p},")
    L[-1] = L[-1].rstrip(",")
    L.append(");")
    for k in range(len(in_recs)):
        L.append(f"    assign pi{k}_ready = 1'b1;              // one record per clock")
    allv = " & ".join(f"pi{k}_valid" for k in range(len(in_recs)))
    for k in range(len(out_recs)):
        L.append(f"    assign po{k}_valid = {allv};   // the clock that ran")
    conn = ", ".join([f".{clock}(clk)"] + [f".{p}({p})" for n, p, w in ins if not p.startswith("rst")] +
                     [f".{p}({p} & rst_n)" for n, p, w in ins if p.startswith("rst")] + [f".{p}({p})" for n, p, w in outs])
    L.append(f"    {fm} {fi} ({conn});   // its parameters' defaults")
    for pr in probes:
        rel = pr.path[len(fi) + 1:] if a.fpga_inst else pr.path
        L.append(f"    assign {pr.port} = {fi}.{rel};")
    L.append(f"endmodule : {a.dut}_ocv_ls")
    open(os.path.join(a.out, f"{a.dut}_ocv_ls.sv"), "w").write("\n".join(L) + "\n")

    # ---- the hub's channels
    chans = []
    for k, rec in enumerate(in_recs):
        chans.append({"name": f"pins_in{k}", "kind": "source", "valid": f"pi{k}_valid", "ready": f"pi{k}_ready",
                      "stream": True, "freeze_when_starved": True, "depth": 64, "fields": fields(rec)})
    for k, rec in enumerate(out_recs):
        chans.append({"name": f"pins_out{k}", "kind": "monitor", "valid": f"po{k}_valid", "lossless": True,
                      "depth": 1024, "fields": fields(rec)})
    desc = {"name": f"{a.dut}_ls", "module": f"{a.dut}_ocv_ls", "clock": "clk",
            "reset": {"port": "rst_n", "active": "low"},
            "description": f"{a.dut} in lockstep with its testbench (lockstep.py)", "channels": chans}
    json.dump(desc, open(os.path.join(a.out, f"{a.dut}_ls.json"), "w"), indent=2)

    # ---- processor side: the bridge
    B = [f"// GENERATED by lockstep.py: {a.dut} on the processor - the DUT is in the FPGA, one clock per clock",
         f"// of {clock}; outputs and the DUT's inner signals the testbench reads come from there (lockstep.py).",
         "`ifndef OCV_LS_REC_BITS", f"`define OCV_LS_REC_BITS {REC_MAX}", "`endif"]
    # shadow modules: one per instance path prefix
    tree_sh = {}
    for pr in probes + [p for k, p in sorted(shadow_only.items()) if k not in {x.path for x in probes}]:
        node = tree_sh
        for s in pr.inst_path:
            node = node.setdefault(s, {})
        node.setdefault("__vars__", []).append(pr)
    bound_names = {sc: t for sc, t in bound}

    def shadow_name(path):
        return bound_names.get(path) or f"{a.dut}_sh_" + re.sub(r"\W+", "_", path)

    def emit(node, path):
        subs = [(k, v) for k, v in node.items() if k != "__vars__"]
        for k, v in subs:
            emit(v, (path + "." if path else "") + k)
        if not path:
            return
        S = [f"module {shadow_name(path)};   // shadow of {a.dut}.{path}"]
        decl = {}
        for pr in node.get("__vars__", []):
            decl.setdefault(pr.var, []).append(pr)
        for var, prs in decl.items():
            idx = [pr for pr in prs if pr.sels and pr.sels[0].startswith("[")]
            mem = [pr for pr in prs if pr.sels and pr.sels[0].startswith(".")]
            if idx:
                n = max(int(pr.sels[0][1:-1]) for pr in idx) + 1
                S.append(f"    logic [{idx[0].width - 1}:0] {var} [0:{n - 1}];")
            elif mem:
                S.append("    struct packed { " + " ".join(f"logic [{pr.width - 1}:0] {pr.sels[0][1:]};" for pr in mem)
                         + f" }} {var};")
            else:
                S.append(f"    logic [{prs[0].width - 1}:0] {var};")
        for k, v in subs:
            S.append(f"    {shadow_name((path + '.' if path else '') + k)} {k} ();")
        S.append(f"endmodule")
        B.extend(S)
    emit(tree_sh, "")
    pdecl = ",\n".join(f"    parameter {v['name']} = 0" for v in params)
    B.append(f"module {a.dut} {('#(' + chr(10) + pdecl + chr(10) + ')') if params else ''} (")
    for p in ports:
        B.append(f"    {'input' if p['direction'] == 'INPUT' else 'output'} logic [{tree.width(p['dtypep']) - 1}:0] {p['name']},")
    B[-1] = B[-1].rstrip(",")
    B.append(");")
    for k, v in tree_sh.items():
        if k != "__vars__":
            B.append(f"    {shadow_name(k)} {k} ();")
    for p, e in sorted(clocks.items()):
        B.append(f"    assign {p} = {e};   // a clock inside the DUT, built here (lockstep.py --clock)")
    B += ["    typedef bit [`OCV_LS_REC_BITS-1:0] rec_t;",
          "    import \"DPI-C\" function int     ocv_dpi_open(string base);",
          "    import \"DPI-C\" function int     ocv_dpi_go(int squash);",
          "    import \"DPI-C\" function int     ocv_dpi_send(int ch, input rec_t rec);",
          "    import \"DPI-C\" function longint ocv_dpi_service(output int moved);",
          "    import \"DPI-C\" function int     ocv_dpi_recv(int ch, output rec_t rec);",
          "    bit opened = 0;",
          "    int trace = 0;                                     // +OCV_LS_TRACE=N: the records of the first N clocks",
          "    longint n_steps = 0;",
          "    // one clock of the DUT: send the inputs the testbench drives now, take that clock's outputs",
          "    task automatic step();",
          "        rec_t r;",
          "        int moved;",
          "        if (!opened) begin",
          "            string base = \"\";",
          "            void'($value$plusargs(\"OCV_BASE=%s\", base));",
          "            if (!ocv_dpi_open(base) || !ocv_dpi_go(1)) $fatal(1, \"lockstep: cannot open the DUT in the FPGA\");",
          "            opened = 1;",
          "            void'($value$plusargs(\"OCV_LS_TRACE=%d\", trace));",
          "        end"]
    ch = 0
    for k, rec in enumerate(in_recs):
        B.append("        r = '0;")
        lsb = 0
        for n, p, w in rec:
            B.append(f"        r[{lsb} +: {w}] = {p};")
            lsb += w
        B.append(f"        if (n_steps < trace) $display(\"OCV-LS %0d @%0t in{k}  %h\", n_steps, $time, r[{lsb - 1}:0]);")
        B.append(f"        while (!ocv_dpi_send({ch}, r)) void'(ocv_dpi_service(moved));")
        ch += 1
    for k, rec in enumerate(out_recs):
        B.append(f"        while (!ocv_dpi_recv({ch}, r)) void'(ocv_dpi_service(moved));")
        bits = sum(w for _, _, w in rec)
        B.append(f"        if (n_steps < trace) $display(\"OCV-LS %0d @%0t out{k} %h\", n_steps, $time, r[{bits - 1}:0]);")
        lsb = 0
        for n, p, w in rec:
            pr = next((x for x in probes if x.port == p), None)
            tgt = p if pr is None else pr.path
            B.append(f"        {tgt} = r[{lsb} +: {w}];")
            lsb += w
        ch += 1
    B += ["        n_steps++;",
          "    endtask",
          f"    initial begin #0 step(); end                        // the clock before the first rising edge",
          f"    always @(negedge {clock}) step();                   // and every one after it",
          f"endmodule : {a.dut}"]
    open(os.path.join(a.out, f"{a.dut}_bridge.sv"), "w").write("\n".join(B) + "\n")

    R = [f"lockstep: {a.dut} (instance {inst} in the testbench); FPGA: {fm}{(' as ' + fi) if a.fpga_inst else ''}",
         f"  inputs {sum(w for _, _, w in ins)} bits in {len(in_recs)} record(s), outputs {sum(w for _, _, w in outs)} bits"
         f" + {len(probes)} probes {sum(p.width for p in probes)} bits in {len(out_recs)} record(s) per clock"]
    for pr in probes:
        R.append(f"  probe {pr.path} [{pr.width}]")
    for p, why in missing:
        R.append(f"  NOT FROM THE FPGA: {p} ({why})")
    R += [f"  {x}" for x in report]
    open(os.path.join(a.out, "report.txt"), "w").write("\n".join(R) + "\n")
    print("\n".join(R[:2]) + f"\n  {len(missing)} path(s) not from the FPGA (report.txt)")


if __name__ == "__main__":
    main()
