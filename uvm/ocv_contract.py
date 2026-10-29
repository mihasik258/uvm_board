#!/usr/bin/env python3
"""ocv_contract.py - what the board needs of a UVM testbench written by the OCV contract (uvm/ocv_uvm_pkg.sv:
transactions extend ocv_item, drivers ocv_source_driver with drive(), monitors ocv_monitor with sample(), the DUT
reached only through an SV interface), derived from the testbench itself - nobody writes a description file or
the record packing:

  desc.json                 the DUT's description (tbparse.py: the interface's pins, the top's wiring, the
                            transfers drive() and sample() make) - input of the hub generator (ocv_gen.py) and of
                            uvm/build_board.sh; an intermediate file, like an object file
  <dut>_ocv_contract_pkg.sv the record packing of every channel's transaction, from its fields as the hub lays them
                            out: a subclass <item>__ocv with to_rec()/from_rec(), which the factory gives for every
                            <item>::type_id::create; and each item type's channel number (ocv_channel_of)
  <dut>_ocv_stub.sv         the DUT's place in the program for the board's processor: a module with the DUT's ports
                            and nothing inside, so the testbench's top compiles as written (it instantiates the DUT
                            as in simulation); the DUT itself is in the FPGA, and the agents reach it through the
                            hub - no result depends on this module

    uvm/ocv_contract.py <tb.sv ...> [--top tb_top] -o <dir>
"""
import argparse, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tbparse  # noqa: E402

OCV = os.path.dirname(HERE)


def package_of(text, cls):
    """the package a class is declared in"""
    for m in re.finditer(r"\bpackage\s+(\w+)\s*;(.*?)\bendpackage\b", text, re.S):
        if re.search(r"\bclass\s+" + cls + r"\b", m.group(2)):
            return m.group(1)
    raise tbparse.TbError(f"class {cls} is not declared in a package (the packing subclass imports it)")


def against(derived, given):
    """the description a wrapper generator made (a processor core's channels, depths, streams: gen/cpu_wrap.py), with
    the testbench's classes on it: every channel the testbench drives or monitors must be one of the given ones, with
    the same fields and widths; channels it does not use stay as they are (their records never come)"""
    by = {c["name"]: c for c in given["channels"]}
    out = json.loads(json.dumps(given))
    oby = {c["name"]: c for c in out["channels"]}
    for c in derived["channels"]:
        g = by.get(c["name"])
        if g is None:
            raise tbparse.TbError(f"{c['_class']}: channel '{c['name']}' (item {c['_item']}) is not one of the DUT's: "
                                  f"{', '.join(by)}")
        # the item's fields go with the DUT's by the pin they are driven to / sampled from (drive(), sample()) -
        # an item's field may have its own name (the DUT's 'until' is a keyword in SystemVerilog)
        gp = {f.get("port"): f for f in g["fields"]}
        o = oby[c["name"]]
        o["_item"], o["_class"] = c["_item"], c["_class"]
        oport = {f.get("port"): f for f in o["fields"]}
        for f in c["fields"]:
            gf = gp.get(f["port"])
            if gf is None or gf["width"] != f["width"]:
                raise tbparse.TbError(f"{c['_class']}: {c['_item']}.{f['_of']} ({f['_w']} bits, pin {f['port']}) is no field "
                                      f"of the DUT's channel '{c['name']}' ({', '.join(x['name'] + ':' + str(x.get('port')) for x in g['fields'])})")
            oport[f["port"]].update({"_of": f["_of"], "_lo": f["_lo"], "_w": f["_w"]})
        # fields the test does not take or give: not in its item (a monitor may look at part of a record)
        o["_unmapped"] = [f["name"] for f in o["fields"] if "_of" not in f]
    out["channels"] = [c for c in out["channels"]]
    for k in ("_top", "_dut_instance", "_clk_sig"):
        out[k] = derived[k]
    # (the description as given, word for word: its CRC is the hub's DUT_ID)
    return out


def _strip_blocks(body):
    """the class body without its covergroups, functions, tasks and constraints: what is left declares its members"""
    for a, b in (("covergroup", "endgroup"), ("function", "endfunction"), ("task", "endtask")):
        body = re.sub(r"\b" + a + r"\b.*?\b" + b + r"\b(\s*:\s*\w+)?", ";", body, flags=re.S)
    body = re.sub(r"\bconstraint\s+\w+\s*\{.*?\}", ";", body, flags=re.S)
    return re.sub(r"`\w+(\s*\([^;]*?\))?", ";", body)


def coverage_specs(desc, text):
    """rule 7 of ocv_uvm_pkg.sv: per item type, what its coverage subscribers read (the DUT's fields), the history
    they keep - "<field>,... <history>", or "all" when a subscriber keeps a state it does not declare. A coverage
    subscriber: a uvm_subscriber #(<item>) with a covergroup, or one that declares ocv_cov_history (a coverage model it
    feeds: core-v-verif's isacov). Fields: those named as <handle>.<field> in it; the item handed on whole (a function
    call, a method of it) - all of them. Its own state: a member that is not an item handle or a covergroup."""
    chans = {c["_item"]: c for c in desc["channels"] if c.get("_item")}
    specs, notes = {}, []
    for m in re.finditer(r"\bclass\s+(\w+)\s+extends\s+uvm_subscriber\s*#\s*\(\s*(\w+)\s*\)\s*;(.*?)\bendclass\b", text, re.S):
        cls, item, body = m.groups()
        if item not in chans:
            continue
        hm = re.search(r"\bocv_cov_history\s*=\s*(\d+)", body)
        if not hm and not re.search(r"\bcovergroup\b", body):
            continue                                    # (a scoreboard, not coverage)
        c = chans[item]
        dut_of = {}                                     # item field -> the DUT's fields (a wide one: its parts)
        for f in c["fields"]:
            if "_of" in f:
                dut_of.setdefault(f["_of"], []).append(f["name"])
        handles = set(re.findall(r"\b" + item + r"\s+(\w+)", body))
        read, whole, bits, full = set(), False, {}, set()
        for h in handles:
            for u in re.finditer(r"\b" + h + r"\b", body):
                after, before = body[u.end():u.end() + 80], body[max(0, u.start() - 40):u.start()]
                if re.search(r"\b" + item + r"\s+$", before):
                    continue                            # (its declaration)
                fm = re.match(r"\s*\.\s*(\w+)\s*(\()?(\s*\[\s*(\d+)\s*(?::\s*(\d+)\s*)?\])?", after)
                if fm:
                    f = fm.group(1)
                    if f in dut_of and not fm.group(2):
                        if fm.group(3) and len(dut_of[f]) == 1:   # a constant part select: those bits alone
                            hi = int(fm.group(4)); lo = int(fm.group(5)) if fm.group(5) else hi
                            bits.setdefault(f, set()).update(range(min(lo, hi), max(lo, hi) + 1))
                        else:
                            full.add(f)
                        read.add(f)
                    elif f not in dut_of:
                        whole = True                    # a method of the item, or a field the DUT has not
                    continue
                if re.match(r"\s*[,)]", after) and not re.search(r"\.\s*sample\s*\(\s*([^()]*,\s*)?$", before):
                    whole = True                        # handed to a function: it may read anything
        state = []
        for st in _strip_blocks(body).split(";"):
            st = " ".join(st.split())
            if not st or re.match(r"(typedef|localparam|parameter|import|static\s+bit\s+done)\b", st):
                continue
            dm = re.match(r"(?:rand\s+|protected\s+|local\s+|static\s+)*([\w:]+)(\s*#\s*\(.*?\))?\s+(\w+)", st)
            if dm and dm.group(1) == item:
                continue                                # an item handle (the one it samples)
            state.append(st)
        hist = int(hm.group(1)) if hm else 0
        if whole:
            read, full = set(dut_of), set(dut_of)
        sp = specs.setdefault(item, {"fields": {}, "hist": 0, "all": False})
        for f in read:                                  # a DUT field: None (all of it) or the bits read
            for d in dut_of[f]:
                if f in full or d in sp["fields"] and sp["fields"][d] is None:
                    sp["fields"][d] = None
                else:
                    sp["fields"][d] = (sp["fields"].get(d) or set()) | bits[f]
        sp["hist"] = max(sp["hist"], hist)
        if state and not hm:
            sp["all"] = True
            notes.append(f"{cls}: a state of its own ({state[0]}) and no ocv_cov_history - on the board it gets every "
                         f"record of '{c['name']}'")
        notes.append(f"{cls}: coverage of '{c['name']}' reads {', '.join(sorted(read)) or 'nothing'}"
                     f"{', history ' + str(hist) if hist else ''}")
    def name(d, b):                                     # "field", or "field[hi:lo]" per run of bits read
        if b is None:
            return [d]
        b, runs = sorted(b), []
        for x in b:
            if runs and x == runs[-1][1] + 1:
                runs[-1][1] = x
            else:
                runs.append([x, x])
        return [f"{d}[{h}:{lo}]" for lo, h in runs]
    out = {}
    for item, sp in specs.items():
        out[item] = "all" if sp["all"] or not sp["fields"] else ",".join(
            n for f in chans[item]["fields"] if f["name"] in sp["fields"] for n in name(f["name"], sp["fields"][f["name"]])) \
            + f" {sp['hist']}"
    return out, notes


def packing_pkg(desc, meta, text, cov=None):
    """the package with the packing subclasses and the channel numbers"""
    name = desc["name"]
    pkgs = sorted({package_of(text, c["_item"]) for c in desc["channels"] if c.get("_item")})
    o = [f"// {name}_ocv_contract_pkg.sv - generated by uvm/ocv_contract.py from the testbench ({desc['_top']}): the record",
         "// packing of each channel's transaction (the hub's layout, ocv_gen.py) and its channel number. Do not edit.",
         "`include \"uvm_macros.svh\"",
         f"package {name}_ocv_contract_pkg;",
         "    import uvm_pkg::*;",
         "    import ocv_uvm_pkg::*;"]
    o += [f"    import {p}::*;" for p in pkgs]
    o.append("")
    for k, (c, mc) in enumerate(zip(desc["channels"], meta["channels"])):
        if not c.get("_item"):
            continue
        item = c["_item"]
        lsb = {f["name"]: f["lsb"] for f in mc["fields"]}
        o += [f"    // channel {k} '{c['name']}' ({c['kind']}): {mc['rec_words']} record word(s)",
              f"    class {item}__ocv extends {item};",
              f"        `uvm_object_utils({item}__ocv)",
              f"        function new(string name = \"{item}\"); super.new(name); endfunction",
              "        virtual function ocv_rec_t to_rec();",
              "            ocv_rec_t r = '0;"]
        def part(f):                    # the item's field, or its 64-bit part (a field wider than the hub's limit)
            return f["_of"] if f["_lo"] == 0 and f["width"] == f["_w"] else f"{f['_of']}[{f['_lo']} +: {f['width']}]"
        for f in c["fields"]:
            if "_of" in f:
                o.append(f"            r[{lsb[f['name']]} +: {f['width']}] = {part(f)};")
        o += ["            return r;", "        endfunction",
              "        virtual function void from_rec(ocv_rec_t r);"]
        for f in c["fields"]:
            if "_of" in f:
                o.append(f"            {part(f)} = r[{lsb[f['name']]} +: {f['width']}];")
        o += ["        endfunction", "    endclass", ""]
    o += ["    // the channels, at static initialisation; the factory overrides once UVM is up (ocv_hook: the first",
          "    // agent's build_phase installs them)",
          "    class ocv_contract_install extends ocv_hook;",
          "        static bit done = register();",
          "        static function bit register();",
          "            ocv_contract_install h = new();"]
    for k, c in enumerate(desc["channels"]):
        if c.get("_item"):
            o.append(f"            ocv_channel_of[\"{c['_item']}\"] = {k};")
    for item, sp in sorted((cov or {}).items()):        # rule 7: what the coverage subscribers need on the board
        o.append(f"            ocv_cov_spec[\"{item}\"] = \"{sp}\";")
    o += ["            ocv_hooks.push_back(h);", "            return 1;", "        endfunction",
          "        virtual function void install();"]
    for c in desc["channels"]:
        if c.get("_item"):
            o.append(f"            {c['_item']}::type_id::set_type_override({c['_item']}__ocv::get_type());")
    o += ["        endfunction", "    endclass", "endpackage", ""]
    return "\n".join(o)


def stub(desc, text):
    """the DUT's ports as an empty module: the testbench's inputs to it, the rest outputs"""
    tb = tbparse.find_top(text, desc["_top"])
    ifs = tbparse.interfaces(text)
    (dut, inst, ports, _, _), vifs = tbparse.top_wiring(tb, ifs)
    widths = {}
    for i in vifs.values():
        widths.update(ifs[i])
    tb_driven = {x for x in re.findall(r"\b\w+\.(\w+)\s*(?:<=|=)(?!=)", text) if x in widths}
    decl = []
    for port, e in ports.items():
        mm = re.fullmatch(r"(\w+)\.(\w+)", e)
        sig = mm.group(2) if mm and mm.group(1) in vifs else None
        w = widths.get(sig, 1) if sig else 1
        d = "input " if (sig is None or sig in tb_driven or port in (desc["clock"], desc["reset"]["port"])) else "output"
        decl.append(f"    {d} logic {'[' + str(w - 1) + ':0] ' if w > 1 else ''}{port}")
    return "\n".join([f"// {dut}_ocv_stub.sv - generated by uvm/ocv_contract.py: the DUT's place in the board build of the",
                      "// testbench - its ports, nothing inside; the DUT itself is in the FPGA, reached through the hub. Do not edit.",
                      f"module {dut} (", ",\n".join(decl), ");", "endmodule", ""])


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tb", nargs="+")
    ap.add_argument("--top", default="tb_top")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--gen-flags", default="", help="ocv_gen.py options of the FPGA image (e.g. --dma 128)")
    ap.add_argument("--desc", help="the DUT's description made by its wrapper's generator (a processor core: "
                    "gen/cpu_wrap.py's <name>.json) - the testbench is checked against it instead of describing the DUT")
    a = ap.parse_args()
    texts = [open(f).read() for f in a.tb]
    text = "\n".join(tbparse.strip_comments(t) for t in texts)
    try:
        desc = tbparse.parse(texts, a.top)
        if a.desc:
            desc = against(desc, json.load(open(a.desc)))
    except tbparse.TbError as e:
        print(f"ocv_contract: {e}", file=sys.stderr)
        sys.exit(2)
    os.makedirs(a.out, exist_ok=True)
    dj = os.path.join(a.out, "desc.json")
    open(dj, "w").write(json.dumps(tbparse.public(desc), indent=2) + "\n")
    # the hub's record layout (field lsb, words) is the generator's: take it from its output
    g = os.path.join(a.out, "layout")
    subprocess.run([sys.executable, os.path.join(OCV, "gen", "ocv_gen.py")] + a.gen_flags.split() + [dj, "-o", g],
                   check=True, stdout=subprocess.DEVNULL)
    meta = json.load(open(os.path.join(g, f"{desc['name']}_ocv_meta.json")))
    name = desc["name"]
    try:
        cov, notes = coverage_specs(desc, text)
        for n in notes:
            print(f"ocv_contract: {n}")
        open(os.path.join(a.out, f"{name}_ocv_contract_pkg.sv"), "w").write(packing_pkg(desc, meta, text, cov))
        open(os.path.join(a.out, f"{name}_ocv_stub.sv"), "w").write(stub(desc, text))
    except tbparse.TbError as e:
        print(f"ocv_contract: {e}", file=sys.stderr)
        sys.exit(2)
    print(f"ocv_contract: {name}: {len(desc['channels'])} channel(s) "
          f"({', '.join(c['name'] + ' ' + c['kind'] + ('' if c.get('_item') else ' (unused)') for c in desc['channels'])}) -> {a.out}")


if __name__ == "__main__":
    main()
