#!/usr/bin/env python3
"""tbparse.py - the OCV description of a DUT, read from a UVM testbench written the usual way
(no description file): the platform needs to know the DUT's ports, which of them form transfers,
and how a transfer is recognised. All of it is already in the testbench:

  interface   the pins and their widths            (interface <if> ...; logic [N-1:0] sig; ...)
  top         the DUT instance, its clock and reset (<dut> u (.port(vif.sig), .clk(clk), ...);
              reset: the interface signal the top holds at 0 and then sets to 1 (active low) or
              the other way round)
  driver      an input channel: a uvm_driver #(item) whose run_phase, for each item, drives
              vif.<sig> <= t.<field>, raises vif.<valid>, waits for vif.<ready> and lowers valid
  monitor     an output channel: a uvm_monitor whose run_phase samples at @(posedge vif.<clk>)
              when vif.<valid> (and vif.<ready>, the reset qualifier is allowed), sets
              t.<field> = vif.<sig> and writes t to an analysis port

The result has the shape of an OCV descriptor (ocv_gen.py), so the hub is generated from it as
before - but nobody writes it. Platform choices (not the verifier's): every output channel is
lossless (the DUT waits for the board, nothing is lost) and can squash (the compared bits are set
at run time from the scoreboard); buffer depths are fixed defaults.

Anything that does not match these shapes is an error that names the class and the statement:
the hub cannot be built from a guess.

    tbparse.py <tb.sv ...> [--top tb_top] [-o desc.json]
"""
import argparse, json, re, sys

DEPTH_SOURCE, DEPTH_OUTPUT = 4096, 4096


class TbError(Exception):
    pass


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def classes(text):
    out = {}
    for m in re.finditer(r"\bclass\s+(\w+)\s+extends\s+(\w+)\s*(#\s*\(([^;]*?)\))?\s*;(.*?)\bendclass\b", text, re.S):
        out[m.group(1)] = (m.group(2), (m.group(4) or "").strip() or None, m.group(5))
    return out


def task_body(body, name):
    m = re.search(r"\btask\s+(?:automatic\s+)?" + name + r"\s*\([^)]*\)\s*;(.*?)\bendtask\b", body, re.S)
    return m.group(1) if m else None


def const_expr(e, env, what):
    """value of a constant expression: numbers (decimal, sized 'd/'h/'b), parameters/defines in env,
    + - * / % ( ) and the shifts; anything else is an error"""
    def num(m):
        v = m.group(0)
        mm = re.fullmatch(r"(?:\d+)?'([dhbo])([0-9a-fA-F_]+)", v)
        if mm:
            return str(int(mm.group(2).replace("_", ""), {"d": 10, "h": 16, "b": 2, "o": 8}[mm.group(1)]))
        return v.replace("_", "")
    x = re.sub(r"(?:\d+)?'[dhbo][0-9a-fA-F_]+|\b\d[\d_]*\b", num, e.strip())
    for _ in range(8):                               # names (parameters, `defines) -> their values
        y = re.sub(r"`?\b([A-Za-z_]\w*)\b", lambda m: f"({env[m.group(1)]})" if m.group(1) in env else m.group(0), x)
        if y == x:
            break
        x = y
    if not re.fullmatch(r"[\d\s+\-*/%()<>]*", x) or re.search(r"[<>](?![<>])|(?<![<>])[<>]", x.replace("<<", "").replace(">>", "")):
        raise TbError(f"{what}: '{e.strip()}' is not a constant this tool evaluates")
    try:
        return int(eval(x.replace("/", "//"), {"__builtins__": {}}))
    except Exception:
        raise TbError(f"{what}: '{e.strip()}' is not a constant this tool evaluates")


def width_of(decl_range, env=None):
    if not decl_range:
        return 1
    m = re.fullmatch(r"\[(.*):(.*)\]", decl_range.strip(), re.S)
    if not m:
        raise TbError(f"range {decl_range}: not [msb:lsb]")
    env = env or {}
    return abs(const_expr(m.group(1), env, f"range {decl_range}") - const_expr(m.group(2), env, f"range {decl_range}")) + 1


def defines(text):
    """`define NAME value (one line, no arguments)"""
    return {n: v.strip() for n, v in re.findall(r"^\s*`define\s+(\w+)[ \t]+([^\n(][^\n]*?)\s*(?://[^\n]*)?$", text, re.M)}


def interfaces(text, overrides=None):
    """name -> {signal: width}; widths from the interface's parameters (defaults, or overrides
    {interface: {param: value}} from its instance) and `defines"""
    out = {}
    dfs = defines(text)
    for m in re.finditer(r"\binterface\s+(\w+)\s*(?:#\s*\(((?:[^()]|\([^()]*\))*)\)\s*)?(?:\(([^)]*)\))?\s*;(.*?)\bendinterface\b", text, re.S):
        env = dict(dfs)
        for p, v in re.findall(r"\bparameter\s+(?:int\s+(?:unsigned\s+)?)?(\w+)\s*=\s*([^,]+?)\s*(?=,|$)", m.group(2) or "", re.S):
            env[p] = v
        env.update((overrides or {}).get(m.group(1), {}))
        sig = {}
        ports = m.group(3) or ""
        for d in re.finditer(r"(?:input|output|inout)?\s*(?:logic|wire|bit)\s*(?:signed\s*)?(\[[^\]]*\])?\s*([\w\s,]+)", ports):
            for n in [x.strip() for x in d.group(2).split(",") if x.strip()]:
                sig[n] = width_of(d.group(1), env)
        for d in re.finditer(r"^\s*(?:logic|wire|bit|reg)\s*(?:signed\s*)?(\[[^\]]*\])?\s*([\w\s,]+);", m.group(4), re.M):
            for n in [x.strip() for x in d.group(2).split(",") if x.strip()]:
                sig[n] = width_of(d.group(1), env)
        out[m.group(1)] = sig
    return out


def find_top(text, top):
    m = re.search(r"\bmodule\s+" + top + r"\b[^;]*;(.*?)\bendmodule\b", text, re.S)
    if not m:
        raise TbError(f"no module {top} (give --top)")
    return m.group(1)


def top_wiring(body, ifs):
    """the DUT instance of the top: module, {port: connected expression}; the interface instances"""
    inst_if = {}
    for ty, name in re.findall(r"^\s*(\w+)\s+(\w+)\s*\([^;]*\)\s*;", body, re.M):
        if ty in ifs:
            inst_if[name] = ty
    for ty, name in re.findall(r"^\s*(\w+)\s+(\w+)\s*;", body, re.M):
        if ty in ifs:
            inst_if[name] = ty
    duts = []
    for m in re.finditer(r"^\s*(\w+)\s+(?:#\s*\((?:[^()]|\([^)]*\))*\)\s*)?(\w+)\s*\(\s*(\..*?)\)\s*;", body, re.M | re.S):
        ty, inst, conns = m.groups()
        if ty in ifs or ty in ("module", "assign"):
            continue
        ports = dict((p, e.strip()) for p, e in re.findall(r"\.(\w+)\s*\(([^()]*)\)", conns))
        duts.append((ty, inst, ports, m.start(), m.end()))
    if len(duts) != 1:
        raise TbError(f"the top must instantiate exactly one DUT with named connections (found {len(duts)})")
    return duts[0], inst_if


def reset_of(body, ports, vifs):
    """the reset port: an interface signal (or top signal) the top sets to a value, then to the other"""
    for port, e in ports.items():
        mm = re.fullmatch(r"(\w+)\.(\w+)", e)
        sig = e if not mm else e
        first = re.search(re.escape(sig) + r"\s*<?=\s*1'b([01])\s*;", body)
        if first:
            later = re.findall(re.escape(sig) + r"\s*<?=\s*1'b([01])\s*;", body)
            if len(set(later)) == 2:
                return port, sig, "low" if first.group(1) == "0" else "high"
    raise TbError("no reset found: the top should set the DUT's reset to its active value, then release it")


def clock_of(body, ports):
    for port, e in ports.items():
        if re.search(r"\balways\s*#\s*[\w.]+\s*" + re.escape(e) + r"\s*=\s*~\s*" + re.escape(e), body):
            return port, e
    raise TbError("no clock found: the top should have 'always #<half period> clk = ~clk;' connected to the DUT")


def item_fields(cls, item):
    body = cls.get(item, (None, None, ""))[2]
    out = {}
    for w, names in re.findall(r"^\s*(?:rand\s+|randc\s+)?(?:bit|logic)\s*(?:signed\s*)?(\[[^\]]*\])?\s*([\w\s,]+);", body, re.M):
        for n in [x.strip() for x in names.split(",") if x.strip()]:
            out[n] = width_of(w)
    return out


def analyse_driver(name, item, body):
    """-> {fields: {field: sig}, valid, ready} of a valid/ready driver"""
    rp = task_body(body, "run_phase")
    if rp is None:
        raise TbError(f"{name}: no run_phase")
    loop = re.search(r"\bforever\s+begin(.*)\bend\b", rp, re.S)
    if not loop:
        raise TbError(f"{name}: run_phase has no 'forever begin ... end' loop over items")
    lb = loop.group(1)
    g = re.search(r"seq_item_port\.(get_next_item|get)\s*\(\s*(\w+)\s*\)", lb)
    if not g:
        raise TbError(f"{name}: the loop does not take items with seq_item_port.get_next_item(t)")
    t = g.group(2)
    fields, valid, ready = {}, None, None
    for sig, f in re.findall(r"\bvif\.(\w+)\s*<?=\s*" + t + r"\.(\w+)\s*;", lb):
        fields[f] = sig
    sets = re.findall(r"\bvif\.(\w+)\s*<?=\s*1'b([01])\s*;", lb)
    ups = [s for s, v in sets if v == "1"]
    downs = [s for s, v in sets if v == "0"]
    vs = [s for s in ups if s in downs]
    if len(vs) != 1:
        raise TbError(f"{name}: no single valid (a vif signal set to 1 with the item and back to 0 after it)")
    valid = vs[0]
    w = re.search(r"\bwhile\s*\(\s*!\s*vif\.(\w+)\s*\)", lb) or re.search(r"\bwait\s*\(\s*vif\.(\w+)\s*\)", lb) \
        or re.search(r"\biff\s*\(?\s*vif\.(\w+)\s*\)?", lb)
    if not w:
        raise TbError(f"{name}: the transfer does not wait for a ready (do @(posedge vif.clk); while (!vif.ready);)")
    ready = w.group(1)
    extra = re.sub(r"\bvif\.\w+\s*<?=\s*(" + t + r"\.\w+|1'b[01])\s*;", "", lb)
    extra = re.sub(r"seq_item_port\.\w+\s*\([^)]*\)\s*;|\bdo\s+@\s*\(\s*posedge\s+vif\.\w+\s*\)\s*;\s*while\s*\([^;]*\)\s*;|"
                   r"@\s*\(\s*posedge\s+vif\.\w+\s*\)\s*;|\bwait\s*\([^;]*\)\s*;", "", extra)
    if extra.strip():
        raise TbError(f"{name}: the loop does more than drive the item: '{extra.strip()[:80]}'")
    return {"fields": fields, "valid": valid, "ready": ready}


def analyse_monitor(name, body, reset_sig):
    rp = task_body(body, "run_phase")
    if rp is None:
        raise TbError(f"{name}: no run_phase")
    m = re.search(r"@\s*\(\s*posedge\s+vif\.(\w+)\s*\)\s*;\s*if\s*\((.*?)\)\s*begin(.*?)\bend\b", rp, re.S)
    if not m:
        raise TbError(f"{name}: run_phase is not 'forever begin @(posedge vif.clk); if (<condition>) begin ... end end'")
    cond, b = m.group(2), m.group(3)
    terms = [x.strip() for x in cond.split("&&")]
    sigs = []
    for x in terms:
        mm = re.fullmatch(r"\(?\s*vif\.(\w+)\s*\)?", x)
        if not mm:
            raise TbError(f"{name}: condition term '{x}' is not a vif signal")
        if reset_sig and ("vif." + mm.group(1) == reset_sig or mm.group(1) == reset_sig.split(".")[-1]):
            continue
        sigs.append(mm.group(1))
    if not 1 <= len(sigs) <= 2:
        raise TbError(f"{name}: condition must be a valid (and a ready), got {sigs}")
    w = re.search(r"\b(\w+)\.write\s*\(\s*(\w+)\s*\)", b)
    if not w:
        raise TbError(f"{name}: the sampled item is not written to an analysis port")
    t = w.group(2)
    fields = dict((f, s) for f, s in re.findall(t + r"\.(\w+)\s*=\s*vif\.(\w+)\s*;", b))
    rest = re.sub(t + r"\.\w+\s*=\s*vif\.\w+\s*;|\w+\.write\s*\(\s*\w+\s*\)\s*;|"
                  r"\w+\s+" + t + r"\s*=\s*\w+::type_id::create\s*\([^)]*\)\s*;|" + t + r"\s*=\s*\w+::type_id::create\s*\([^)]*\)\s*;", "", b)
    if rest.strip():
        raise TbError(f"{name}: the sampling does more than copy pins to the item: '{rest.strip()[:80]}'")
    return {"fields": fields, "valid": sigs[0], "ready": sigs[1] if len(sigs) > 1 else None, "ap": w.group(1)}


def signed_signals(text):
    """interface signals declared signed"""
    out = set()
    for m in re.finditer(r"\binterface\b.*?\bendinterface\b", text, re.S):
        for d in re.finditer(r"(?:logic|wire|bit|reg)\s+signed\s*(?:\[[^\]]*\])?\s*([\w\s,]+)[;)]", m.group(0)):
            out |= {x.strip() for x in d.group(1).split(",") if x.strip()}
    return out


def fields_of(pairs, widths, port_of, signed=frozenset()):
    """channel fields from (item field, signal) pairs; a signal wider than 64 bits (the hub's field
    limit) becomes 64-bit parts of the same port ('slice'), named <field>__<k>"""
    out = []
    for f, sig in pairs:
        w = widths[sig]
        if w <= 64:
            out.append({"name": f, "port": port_of(sig), "width": w, "_of": f, "_lo": 0, "_w": w})
            if sig in signed:
                out[-1]["signed"] = True
            continue
        for k in range((w + 63) // 64):
            lo, hi = 64 * k, min(64 * k + 63, w - 1)
            out.append({"name": f"{f}__{k}", "port": port_of(sig), "width": hi - lo + 1, "slice": [hi, lo],
                        "_of": f, "_lo": lo, "_w": w})
    return out


def parse(texts, top):
    text = "\n".join(strip_comments(t) for t in texts)
    ifs = interfaces(text)
    if not ifs:
        raise TbError("no SystemVerilog interface with the DUT's pins")
    tb = find_top(text, top)
    (dut, inst, ports, _, _), vifs = top_wiring(tb, ifs)
    clk_port, clk_sig = clock_of(tb, ports)
    rst_port, rst_sig, rst_act = reset_of(tb, ports, vifs)
    # interface signal -> DUT port
    sig2port = {}
    for port, e in ports.items():
        mm = re.fullmatch(r"(\w+)\.(\w+)", e)
        if mm and mm.group(1) in vifs:
            sig2port[mm.group(2)] = port
    widths = {}
    for i in vifs.values():
        widths.update(ifs[i])
    cls = classes(text)
    sgn = signed_signals(text)
    chans = []

    def port(name, sig):
        if sig not in sig2port:
            raise TbError(f"{name}: vif.{sig} is not connected to a DUT port in {top}")
        return sig2port[sig]

    # signals the testbench itself assigns (drivers, the top: assign / initial): the DUT's inputs
    tb_driven = {x for x in re.findall(r"\b\w+\.(\w+)\s*(?:<=|=)(?!=)", text) if x in widths}
    monitors = []
    for name, (base, tparam, body) in cls.items():
        if base == "uvm_driver" and tparam:
            item = tparam.split(",")[0].strip()
            d = analyse_driver(name, item, body)
            iw = item_fields(cls, item)
            ch = {"name": re.sub(r"_(item|txn|tr|trans|transaction|seq_item)$", "", item), "kind": "source",
                  "depth": DEPTH_SOURCE, "valid": port(name, d["valid"]), "ready": port(name, d["ready"]),
                  "fields": [], "_class": name, "_item": item, "_inmon": [], "_sigs": d}
            for s_ in d["fields"].values():
                if s_ not in widths:
                    raise TbError(f"{name}: vif.{s_} is not a signal of the interface")
            ch["fields"] = fields_of(d["fields"].items(), widths, lambda s_, n=name: port(n, s_), sgn)
            chans.append(ch)
        elif base == "uvm_monitor":
            monitors.append((name, body))
    for name, body in monitors:
        d = analyse_monitor(name, body, rst_sig)
        mm = re.search(r"uvm_analysis_port\s*#\s*\(\s*(\w+)\s*\)", body)
        item = mm.group(1) if mm else None
        sigs = [d["valid"]] + ([d["ready"]] if d["ready"] else [])
        # a monitor on the DUT's inputs: what a driver gives it (on the board: what the driver sent)
        src = [c for c in chans if c["kind"] == "source" and c["_sigs"]["valid"] in sigs]
        if src:
            c = src[0]
            want = set(c["_sigs"]["fields"].items())
            if not set((f, s_) for f, s_ in d["fields"].items()) <= {(f, s_) for f, s_ in want} and \
               not set(d["fields"].values()) <= set(c["_sigs"]["fields"].values()):
                raise TbError(f"{name}: samples the inputs of '{c['name']}' but not as its driver drives them")
            fmap = {f: next(df for df, ds in c["_sigs"]["fields"].items() if ds == s_) for f, s_ in d["fields"].items()}
            c["_inmon"].append({"class": name, "item": item, "ap": d["ap"], "fields": fmap})
            continue
        valid, ready = d["valid"], d["ready"]
        if ready is not None:                       # which of the two the testbench drives is the ready
            drv = [x for x in (valid, ready) if x in tb_driven]
            if len(drv) != 1:
                raise TbError(f"{name}: of vif.{valid} and vif.{ready} exactly one must be driven by the testbench (the ready)")
            ready = drv[0]
            valid = d["valid"] if d["ready"] == ready else d["ready"]
        ch = {"name": re.sub(r"_(item|txn|tr|trans|transaction|seq_item)$", "", item or name),
              "kind": "sink" if ready else "monitor", "depth": DEPTH_OUTPUT, "squash": True,
              "valid": port(name, valid), "fields": [], "_class": name, "_item": item, "_ap": d["ap"]}
        if ready:
            ch["ready"] = port(name, ready)
        else:
            ch["lossless"] = True
        ch["fields"] = fields_of(d["fields"].items(), widths, lambda s_, n=name: port(n, s_), sgn)
        chans.append(ch)
    if not chans:
        raise TbError("no uvm_driver or uvm_monitor found")
    names = [c["name"] for c in chans]
    if len(set(names)) != len(names):
        raise TbError(f"two channels with one name: {names}")
    return {"name": dut, "module": dut, "clock": clk_port,
            "reset": {"port": rst_port, "active": rst_act},
            "description": f"read from the testbench ({top}) by tbparse.py",
            "channels": chans, "_top": top, "_dut_instance": inst, "_clk_sig": clk_sig}


def public(desc):
    """the descriptor without tbparse's notes (keys starting with '_')"""
    if isinstance(desc, dict):
        return {k: public(v) for k, v in desc.items() if not k.startswith("_")}
    if isinstance(desc, list):
        return [public(x) for x in desc]
    return desc


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tb", nargs="+")
    ap.add_argument("--top", default="tb_top")
    ap.add_argument("-o", "--out")
    ap.add_argument("--notes", action="store_true", help="keep tbparse's notes (class names) in the output")
    a = ap.parse_args()
    try:
        d = parse([open(f).read() for f in a.tb], a.top)
    except TbError as e:
        print(f"tbparse: {e}", file=sys.stderr)
        sys.exit(2)
    s = json.dumps(d if a.notes else public(d), indent=2)
    if a.out:
        open(a.out, "w").write(s + "\n")
    else:
        print(s)


if __name__ == "__main__":
    main()
