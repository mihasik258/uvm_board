#!/usr/bin/env python3
"""ocv_gen.py - generate the OCV verification wrapper and PS metadata for one DUT.

    ocv_gen.py <dut.json> [-o <out_dir>] [--uvm] [--dma DW]

Input: a DUT descriptor (JSON, see docs/DESCRIPTOR.md). Outputs, named after the descriptor:
    <name>_ocv.sv         wrapper: DUT + ocv_hub + one endpoint per channel. Its only PS-facing
                          interface is one AXI4-Lite slave, so the platform layer is the same
                          for every DUT.
    <name>_ocv_meta.h     C tables for the PS software (ocv_meta.h types).
    <name>_ocv_meta.json  the same, for scripts.
With --uvm the hub is built for transactions (every source a stream, every monitor lossless) and
the UVM layer is generated too (ocv_uvm_gen.py): <name>_ocv_uvm_pkg.sv, <name>_ocv_uvm_harness.sv.

DUT_ID is the CRC32 of the canonical descriptor; the PS software refuses to run against a
bitstream whose hub reports a different DUT_ID.
"""
import argparse, json, math, os, re, sys, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ocv_uvm_gen  # noqa: E402

IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")
CMP_CODES = {"exact": 0, "ignore": 1, "mask": 2, "abs": 3, "ulp": 4}
FP_WIDTH = {"fp16": 16, "fp32": 32, "fp64": 64}
KIND_CODES = {"source": 1, "sink": 2, "monitor": 3}


class DescError(Exception):
    pass


def need(cond, msg):
    if not cond:
        raise DescError(msg)


def check_keys(obj, where, required, optional):
    need(isinstance(obj, dict), f"{where}: expected an object")
    for k in required:
        need(k in obj, f"{where}: missing '{k}'")
    for k in obj:
        need(k in required or k in optional, f"{where}: unknown key '{k}'")


def ident(v, where):
    need(isinstance(v, str) and IDENT.match(v), f"{where}: '{v}' is not a valid identifier")
    return v


def parse_int(v, where):
    if isinstance(v, bool):
        raise DescError(f"{where}: expected an integer")
    if isinstance(v, int):
        return v
    need(isinstance(v, str), f"{where}: expected an integer")
    try:
        return int(v, 0)
    except ValueError:
        raise DescError(f"{where}: '{v}' is not an integer")


# --------------------------------------------------------------------------- validation
def load(path, uvm=False):
    try:
        d = json.load(open(path))
    except json.JSONDecodeError as e:
        raise DescError(f"{path}: invalid JSON: {e}")
    if uvm:
        ocv_uvm_gen.uvm_transform(d, need)
    check_keys(d, "descriptor", ["name", "module", "clock", "channels"],
               ["reset", "parameters", "tie", "export", "description"])
    ident(d["name"], "name")
    ident(d["module"], "module")
    ident(d["clock"], "clock")
    if "reset" in d:
        check_keys(d["reset"], "reset", ["port", "active"], [])
        ident(d["reset"]["port"], "reset.port")
        need(d["reset"]["active"] in ("low", "high"), "reset.active: 'low' or 'high'")
    for k, v in d.get("parameters", {}).items():
        ident(k, f"parameters.{k}")
        need(isinstance(v, (int, str)), f"parameters.{k}: number or SV expression string")
    for k, v in d.get("tie", {}).items():
        ident(k, f"tie.{k}")
        need(isinstance(v, (int, str)), f"tie.{k}: number or SV expression string")
    for i, e in enumerate(d.get("export", [])):
        w = f"export[{i}]"
        check_keys(e, w, ["port", "dir"], ["width"])
        ident(e["port"], f"{w}.port")
        need(e["dir"] in ("in", "out"), f"{w}.dir: 'in' or 'out'")
        need(parse_int(e.get("width", 1), f"{w}.width") >= 1, f"{w}.width must be >= 1")

    chans = d["channels"]
    need(isinstance(chans, list) and chans, "channels: a non-empty list")
    need(len(chans) <= 254, "channels: at most 254")
    names = set()
    used_ports = {d["clock"]} | ({d["reset"]["port"]} if "reset" in d else set())
    used_ports |= set(d.get("tie", {})) | {e["port"] for e in d.get("export", [])}
    for ci, c in enumerate(chans):
        w = f"channels[{ci}]"
        check_keys(c, w, ["name", "kind", "valid", "fields"],
                   ["ready", "depth", "stall", "lossless", "stream", "freeze_when_starved", "squash", "description"])
        ident(c["name"], f"{w}.name")
        need(c["name"] not in names, f"{w}: duplicate channel name '{c['name']}'")
        names.add(c["name"])
        need(c["kind"] in KIND_CODES, f"{w}.kind: one of {sorted(KIND_CODES)}")
        ident(c["valid"], f"{w}.valid")
        if "ready" in c:
            ident(c["ready"], f"{w}.ready")
        need(not (c["kind"] == "monitor" and "ready" in c),
             f"{w}: a monitor only observes; give it the completed-transfer strobe as 'valid'")
        if "stall" in c:
            need(c["kind"] == "monitor", f"{w}.stall: only monitors drive a DUT stall input")
            ident(c["stall"], f"{w}.stall")
        need(isinstance(c.get("lossless", False), bool), f"{w}.lossless: true/false")
        if c.get("lossless"):
            need(c["kind"] == "monitor", f"{w}.lossless: only monitors (sinks with ready are lossless anyway)")
            need("stall" not in c, f"{w}: 'lossless' freezes the DUT clock itself; drop 'stall'")
        for key in ("stream", "freeze_when_starved"):
            need(isinstance(c.get(key, False), bool), f"{w}.{key}: true/false")
            if c.get(key):
                need(c["kind"] == "source", f"{w}.{key}: only sources (a reactive feed the PS writes during the run)")
        if c.get("freeze_when_starved"):
            need("ready" in c, f"{w}.freeze_when_starved: needs the DUT's 'ready' (it means 'waiting for data')")
        need(isinstance(c.get("squash", False), bool), f"{w}.squash: true/false")
        if c.get("squash"):
            need(c["kind"] != "source", f"{w}.squash: only outputs (sinks, monitors) are fused")
            need(c.get("lossless") or (c["kind"] == "sink" and "ready" in c),
                 f"{w}.squash: the channel must be lossless (a lossless monitor or a sink with ready)")
        depth = parse_int(c.get("depth", 1024), f"{w}.depth")
        need(2 <= depth <= (1 << 24) and depth & (depth - 1) == 0, f"{w}.depth: a power of two, 2..2^24")
        c["depth"] = depth
        fields = c["fields"]
        need(isinstance(fields, list) and fields, f"{w}.fields: a non-empty list")
        fnames = set()
        for fi, f in enumerate(fields):
            fw = f"{w}.fields[{fi}]"
            check_keys(f, fw, ["name", "port", "width"], ["signed", "compare", "description", "slice"])
            ident(f["name"], f"{fw}.name")
            need(f["name"] not in fnames, f"{fw}: duplicate field name '{f['name']}'")
            fnames.add(f["name"])
            ident(f["port"], f"{fw}.port")
            f["width"] = parse_int(f["width"], f"{fw}.width")
            need(1 <= f["width"] <= 64, f"{fw}.width: 1..64")
            if "slice" in f:                         # part [msb, lsb] of a wider port
                sl = f["slice"]
                need(isinstance(sl, list) and len(sl) == 2 and all(isinstance(x, int) and x >= 0 for x in sl)
                     and sl[0] >= sl[1] and sl[0] - sl[1] + 1 == f["width"],
                     f"{fw}.slice: [msb, lsb] of the port, msb - lsb + 1 = width")
            need(isinstance(f.get("signed", False), bool), f"{fw}.signed: true/false")
            f["cmp"] = parse_compare(f, fw, c["kind"])
            need(not c.get("squash") or f["cmp"][0] in (CMP_CODES["exact"], CMP_CODES["ignore"]),
                 f"{fw}: squash compares signatures - only 'exact' and 'ignore' fields")
        sliced = {}
        for f in fields:
            if "slice" in f:
                sliced.setdefault(f["port"], []).append(f["slice"])
        for p, parts in sliced.items():          # the parts of a wide port: disjoint, from bit 0 up
            need(all("slice" in f for f in fields if f["port"] == p),
                 f"{w}: port '{p}' has fields with and without a slice")
            bits = sorted((lo, hi) for hi, lo in parts)
            need(bits[0][0] == 0 and all(bits[i][1] + 1 == bits[i + 1][0] for i in range(len(bits) - 1)),
                 f"{w}: the slices of port '{p}' must cover it from bit 0 without gaps or overlaps")
        for p in [c["valid"], c.get("ready"), c.get("stall")] + sorted({f["port"] for f in fields}):
            if p is None:
                continue
            need(p not in used_ports, f"{w}: DUT port '{p}' is connected more than once")
            used_ports.add(p)
        need(len([f for f in fields if "slice" not in f]) == len({f["port"] for f in fields if "slice" not in f}),
             f"{w}: a DUT port is connected more than once")
    return d


def parse_compare(f, where, kind):
    spec = f.get("compare", "exact")
    if kind == "source":
        need("compare" not in f, f"{where}.compare: source fields are stimulus, not compared")
        return (0, 0, 0)
    if isinstance(spec, str):
        need(spec in ("exact", "ignore"), f"{where}.compare: 'exact', 'ignore' or an object")
        return (CMP_CODES[spec], 0, 0)
    need(isinstance(spec, dict) and len(spec) >= 1, f"{where}.compare: bad rule")
    if "mask" in spec:
        check_keys(spec, f"{where}.compare", ["mask"], [])
        m = parse_int(spec["mask"], f"{where}.compare.mask")
        need(0 < m < (1 << f["width"]), f"{where}.compare.mask: must fit the field width")
        return (CMP_CODES["mask"], m, 0)
    if "abs" in spec:
        check_keys(spec, f"{where}.compare", ["abs"], [])
        t = parse_int(spec["abs"], f"{where}.compare.abs")
        need(t >= 0, f"{where}.compare.abs: >= 0")
        return (CMP_CODES["abs"], t, 0)
    if "ulp" in spec:
        check_keys(spec, f"{where}.compare", ["ulp", "fp"], [])
        need(spec["fp"] in FP_WIDTH, f"{where}.compare.fp: one of {sorted(FP_WIDTH)}")
        need(f["width"] == FP_WIDTH[spec["fp"]], f"{where}: {spec['fp']} needs width {FP_WIDTH[spec['fp']]}")
        t = parse_int(spec["ulp"], f"{where}.compare.ulp")
        need(t >= 0, f"{where}.compare.ulp: >= 0")
        return (CMP_CODES["ulp"], t, FP_WIDTH[spec["fp"]])
    raise DescError(f"{where}.compare: unknown rule {spec}")


# --------------------------------------------------------------------------- layout
def layout(d, dma_dw=0):
    """Pack fields LSB-first; records are rounded up to 32-bit words. dma_dw: output channels get the
    DMA ring (ocv_dma_wr) with an AXI master of that data width; their register half is 128 bytes."""
    slot_aw = 8
    for i, c in enumerate(d["channels"]):
        lsb = 0
        for f in c["fields"]:
            f["lsb"] = lsb
            lsb += f["width"]
        c["rec_bits"] = lsb
        c["rec_w"] = max(32, (lsb + 31) // 32 * 32)
        c["rec_words"] = c["rec_w"] // 32
        # a squashed output stores {crc32, crc32c, count, last record}: 3 more words
        c["store_w"] = c["rec_w"] + (96 if c.get("squash") else 0)
        c["log2_depth"] = int(math.log2(c["depth"]))
        c["slot"] = i + 1
        c["dma"] = bool(dma_dw) and c["kind"] != "source"
        b = c["log2_depth"] + math.ceil(math.log2(c["store_w"] // 32)) + 2
        c["ep_aw"] = max(b, 7 if c["dma"] else 6) + 1
        slot_aw = max(slot_aw, c["ep_aw"])
    d["slot_aw"] = slot_aw
    d["dma_dw"] = dma_dw
    d["sel_w"] = max(1, math.ceil(math.log2(len(d["channels"]) + 1)))
    d["addr_w"] = slot_aw + d["sel_w"]
    canon = json.dumps(d["_raw"], sort_keys=True, separators=(",", ":"))
    d["dut_id"] = zlib.crc32(canon.encode()) & 0xFFFFFFFF


# --------------------------------------------------------------------------- SystemVerilog
def throttle_seed(slot):
    """Distinct non-zero LFSR seed per endpoint, so channels do not pause in lock-step."""
    return ((0xACE1 * (slot + 1)) ^ (slot << 9)) & 0xFFFF or 0xACE1


def sv_value(v):
    return str(v) if isinstance(v, int) else v


def gen_sv(d, src_name):
    n = len(d["channels"])
    L = []
    a = L.append
    a(f"// GENERATED by ocv_gen.py from {src_name} - do not edit; regenerate instead.")
    a(f"//")
    a(f"// {d['name']}_ocv: verification wrapper for DUT '{d['module']}'.")
    a(f"// PS side: one AXI4-Lite slave ({d['addr_w']}-bit address), hub in slot 0, channels in slots:")
    for c in d["channels"]:
        a(f"//   slot {c['slot']}: {c['name']:<12} {c['kind']:<8} {c['rec_bits']:>4} bits -> "
          f"{c['rec_words']} word(s) x {c['depth']} records")
    a(f"// DUT_ID = 0x{d['dut_id']:08X}")
    if d.get("dma_dw"):
        a(f"// DMA: output channels empty into rings in PS memory over the AXI4 master m_axi "
          f"({d['dma_dw']}-bit data, write only).")
    a(f"module {d['name']}_ocv (")
    a(f"    input  logic          clk,")
    a(f"    input  logic          rst_n,")
    aw = d["addr_w"]
    for p, dr, w in [("awaddr", "input", aw), ("awprot", "input", 3), ("awvalid", "input", 1),
                     ("awready", "output", 1), ("wdata", "input", 32), ("wstrb", "input", 4),
                     ("wvalid", "input", 1), ("wready", "output", 1), ("bresp", "output", 2),
                     ("bvalid", "output", 1), ("bready", "input", 1), ("araddr", "input", aw),
                     ("arprot", "input", 3), ("arvalid", "input", 1), ("arready", "output", 1),
                     ("rdata", "output", 32), ("rresp", "output", 2), ("rvalid", "output", 1),
                     ("rready", "input", 1)]:
        rng = f"[{w-1}:0]" if w > 1 else ""
        a(f"    {dr:<6} logic {rng:<8} s_axi_{p},")
    dma_chs = [c for c in d["channels"] if c.get("dma")]
    if dma_chs:
        dw, idw = d["dma_dw"], max(1, math.ceil(math.log2(len(dma_chs))))
        for p, dr, w in [("awid", "output", idw), ("awaddr", "output", 64), ("awlen", "output", 8),
                         ("awsize", "output", 3), ("awburst", "output", 2), ("awcache", "output", 4),
                         ("awprot", "output", 3), ("awlock", "output", 1), ("awqos", "output", 4),
                         ("awvalid", "output", 1), ("awready", "input", 1),
                         ("wdata", "output", dw), ("wstrb", "output", dw // 8), ("wlast", "output", 1),
                         ("wvalid", "output", 1), ("wready", "input", 1),
                         ("bid", "input", idw), ("bresp", "input", 2), ("bvalid", "input", 1),
                         ("bready", "output", 1),
                         ("arid", "output", idw), ("araddr", "output", 64), ("arlen", "output", 8),
                         ("arsize", "output", 3), ("arburst", "output", 2), ("arcache", "output", 4),
                         ("arprot", "output", 3), ("arlock", "output", 1), ("arqos", "output", 4),
                         ("arvalid", "output", 1), ("arready", "input", 1),
                         ("rid", "input", idw), ("rdata", "input", dw), ("rresp", "input", 2),
                         ("rlast", "input", 1), ("rvalid", "input", 1), ("rready", "output", 1)]:
            rng = f"[{w-1}:0]" if w > 1 else ""
            a(f"    {dr:<6} logic {rng:<8} m_axi_{p},")
    exports = d.get("export", [])
    for e in exports:
        w = parse_int(e.get("width", 1), "width")
        rng = f"[{w-1}:0]" if w > 1 else ""
        a(f"    {'input ' if e['dir'] == 'in' else 'output'} logic {rng:<8} {e['port']},")
    L[-1] = L[-1].rstrip(",")
    a(");")
    a(f"    localparam int unsigned N_EP    = {n};")
    a(f"    localparam int unsigned SLOT_AW = {d['slot_aw']};")
    a("")
    a("    // ---------------- hub ----------------")
    a("    logic                   dut_rst;")
    a("    logic [N_EP-1:0]        ep_wr, ep_rd;")
    a("    logic [SLOT_AW-1:0]     ep_waddr, ep_raddr, ep_rd_addr_q;")
    a("    logic [31:0]            ep_wdata;")
    a("    logic [3:0]             ep_wstrb;")
    a("    logic [N_EP-1:0][31:0]  ep_rdata;")
    a("")
    a(f"    ocv_hub #(.N_EP(N_EP), .SLOT_AW(SLOT_AW), .DUT_ID(32'h{d['dut_id']:08X})) i_hub (")
    a("        .clk, .rst_n,")
    a("        .s_axi_awaddr, .s_axi_awprot, .s_axi_awvalid, .s_axi_awready,")
    a("        .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,")
    a("        .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,")
    a("        .s_axi_araddr, .s_axi_arprot, .s_axi_arvalid, .s_axi_arready,")
    a("        .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,")
    a("        .ep_wr, .ep_waddr, .ep_wdata, .ep_wstrb, .ep_rd, .ep_raddr, .ep_rd_addr_q, .ep_rdata,")
    a("        .dut_rst_o (dut_rst)")
    a("    );")
    lossless = [c for c in d["channels"] if c.get("lossless")]
    starved = [c for c in d["channels"] if c.get("freeze_when_starved")]
    gated = bool(lossless or starved)
    a("")
    if gated:
        why = " or ".join((["a lossless monitor's buffer is full"] if lossless else [])
                          + (["it waits for a reactive record"] if starved else []))
        a(f"    // ---------------- DUT clock: frozen while {why} ----------------")
        a("    logic dut_ce, dut_clk;")
        holds = [f"ch_{c['name']}_stall" for c in lossless] + [f"ch_{c['name']}_starve" for c in starved]
        a(f"    assign dut_ce = ~({' | '.join(holds)});")
        a("    ocv_clock_gate i_dut_clk (.clk, .en (dut_ce), .gclk (dut_clk));")
    else:
        a("    // ---------------- DUT clock: never frozen ----------------")
        a("    logic dut_ce;")
        a("    assign dut_ce = 1'b1;")
    if dma_chs:
        n, dw = len(dma_chs), d["dma_dw"]
        idw = max(1, math.ceil(math.log2(n)))
        a("")
        a(f"    // ---------------- DMA: {n} output channel(s) share the AXI4 master ----------------")
        a(f"    logic [{n-1}:0][63:0]  dma_awaddr;")
        a(f"    logic [{n-1}:0][7:0]   dma_awlen;")
        a(f"    logic [{n-1}:0][2:0]   dma_awsize;")
        a(f"    logic [{n-1}:0][1:0]   dma_awburst, dma_bresp;")
        a(f"    logic [{n-1}:0][3:0]   dma_awcache;")
        a(f"    logic [{n-1}:0]        dma_awvalid, dma_awready, dma_wlast, dma_wvalid, dma_wready, dma_bvalid, dma_bready;")
        a(f"    logic [{n-1}:0][{dw-1}:0] dma_wdata;")
        a(f"    logic [{n-1}:0][{dw//8-1}:0] dma_wstrb;")
        a(f"    ocv_axi_wr_arb #(.N({n}), .DW({dw}), .AW(64), .IDW({idw})) i_dma_arb (")
        a("        .clk, .rst_n,")
        a("        .s_awaddr (dma_awaddr), .s_awlen (dma_awlen), .s_awsize (dma_awsize), .s_awburst (dma_awburst),")
        a("        .s_awcache (dma_awcache), .s_awvalid (dma_awvalid), .s_awready (dma_awready),")
        a("        .s_wdata (dma_wdata), .s_wstrb (dma_wstrb), .s_wlast (dma_wlast), .s_wvalid (dma_wvalid),")
        a("        .s_wready (dma_wready), .s_bresp (dma_bresp), .s_bvalid (dma_bvalid), .s_bready (dma_bready),")
        a("        .m_axi_awid, .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst, .m_axi_awcache,")
        a("        .m_axi_awvalid, .m_axi_awready, .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid,")
        a("        .m_axi_wready, .m_axi_bid, .m_axi_bresp, .m_axi_bvalid, .m_axi_bready")
        a("    );")
        a("    assign m_axi_awprot = 3'b000;  assign m_axi_awlock = 1'b0;  assign m_axi_awqos = 4'h0;")
        a("    // write only: the read channels are idle")
        a("    assign m_axi_arid = '0;   assign m_axi_araddr = '0;  assign m_axi_arlen = '0;   assign m_axi_arsize = '0;")
        a("    assign m_axi_arburst = '0; assign m_axi_arcache = '0; assign m_axi_arprot = '0;  assign m_axi_arlock = 1'b0;")
        a("    assign m_axi_arqos = '0;  assign m_axi_arvalid = 1'b0; assign m_axi_rready = 1'b1;")
        a("    logic unused_axi_r;")
        a("    assign unused_axi_r = ^{m_axi_arready, m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast, m_axi_rvalid};")
    for c in d["channels"]:
        k = c["slot"] - 1
        cn = f"ch_{c['name']}"
        a("")
        a(f"    // ---------------- channel '{c['name']}': {c['kind']}, slot {c['slot']} ----------------")
        a(f"    logic                   {cn}_valid, {cn}_ready;")
        a(f"    logic {'[' + str(c['rec_w']-1) + ':0]':<17} {cn}_rec;")
        bus = (f".bus_wr (ep_wr[{k}]), .bus_waddr ({c['ep_aw']}'(ep_waddr)), .bus_wdata (ep_wdata), "
               f".bus_wstrb (ep_wstrb),\n        .bus_rd (ep_rd[{k}]), .bus_raddr ({c['ep_aw']}'(ep_raddr)), "
               f".bus_rd_addr_q ({c['ep_aw']}'(ep_rd_addr_q)), .bus_rdata (ep_rdata[{k}])")
        if c["kind"] == "source":
            st, fz = int(bool(c.get("stream"))), int(bool(c.get("freeze_when_starved")))
            a(f"    logic                   {cn}_starve;")
            a(f"    ocv_source #(.REC_W({c['rec_w']}), .LOG2_DEPTH({c['log2_depth']}), "
              f".THROTTLE_SEED(16'h{throttle_seed(c['slot']):04X}), .STREAM(1'b{st}), .FREEZE_STARVED(1'b{fz})) i_{cn} (")
            a(f"        .clk, .rst_n, .clear_i (dut_rst), .dut_ce_i (dut_ce), .starve_o ({cn}_starve),")
            a(f"        .rec_valid_o ({cn}_valid), .rec_ready_i ({cn}_ready), .rec_data_o ({cn}_rec),")
            a(f"        {bus}")
            a(f"    );")
            if "ready" not in c:
                a(f"    assign {cn}_ready = 1'b1;   // DUT input has no ready: it takes every record")
        else:
            bp = "1'b1" if c["kind"] == "sink" and "ready" in c else "1'b0"
            a(f"    logic                   {cn}_stall;")
            for f in c["fields"]:
                rng = f"[{f['width']-1}:0]" if f["width"] > 1 else ""
                a(f"    logic {rng:<17} {cn}_f_{f['name']};")
            for port in sorted({f["port"] for f in c["fields"] if "slice" in f}):   # a wide port, cut
                top = max(f["slice"][0] for f in c["fields"] if f["port"] == port)
                a(f"    logic {'[' + str(top) + ':0]':<17} {cn}_p_{port};")
                for f in c["fields"]:
                    if f["port"] == port:
                        a(f"    assign {cn}_f_{f['name']} = {cn}_p_{port}[{f['slice'][0]}:{f['slice'][1]}];")
            pad = c["rec_w"] - c["rec_bits"]
            parts = ([f"{pad}'b0"] if pad else []) + [f"{cn}_f_{f['name']}" for f in reversed(c["fields"])]
            a(f"    assign {cn}_rec = {{{', '.join(parts)}}};")
            ll = "1'b1" if c.get("lossless") else "1'b0"
            sq = ""
            if c.get("squash"):
                mask = 0
                for f in c["fields"]:
                    if f["cmp"][0] == CMP_CODES["exact"]:
                        mask |= ((1 << f["width"]) - 1) << f["lsb"]
                sq = (f", .SQUASH(1'b1), .IN_W({c['rec_w']}), "
                      f".MASK({c['rec_w']}'h{mask:0{c['rec_w'] // 4}X})")
            dma = ""
            if c.get("dma"):
                dma = f", .DMA(1'b1), .DMA_DW({d['dma_dw']}), .DMA_AW(64)"
            else:
                a("    /* verilator lint_off PINCONNECTEMPTY */   // no DMA: the AXI master pins are idle")
            a(f"    ocv_sink #(.REC_W({c['store_w']}), .LOG2_DEPTH({c['log2_depth']}), .BACKPRESSURE({bp}), "
              f".LOSSLESS({ll}), .THROTTLE_SEED(16'h{throttle_seed(c['slot']):04X}){sq}{dma}) i_{cn} (")
            a(f"        .clk, .rst_n, .clear_i (dut_rst), .dut_ce_i (dut_ce), .stall_o ({cn}_stall),")
            a(f"        .rec_valid_i ({cn}_valid), .rec_ready_o ({cn}_ready), .rec_data_i ({cn}_rec),")
            if c.get("dma"):
                j = dma_chs.index(c)
                a(f"        {bus},")
                a(f"        .m_axi_awaddr (dma_awaddr[{j}]), .m_axi_awlen (dma_awlen[{j}]), "
                  f".m_axi_awsize (dma_awsize[{j}]), .m_axi_awburst (dma_awburst[{j}]),")
                a(f"        .m_axi_awcache (dma_awcache[{j}]), .m_axi_awvalid (dma_awvalid[{j}]), "
                  f".m_axi_awready (dma_awready[{j}]),")
                a(f"        .m_axi_wdata (dma_wdata[{j}]), .m_axi_wstrb (dma_wstrb[{j}]), .m_axi_wlast (dma_wlast[{j}]), "
                  f".m_axi_wvalid (dma_wvalid[{j}]), .m_axi_wready (dma_wready[{j}]),")
                a(f"        .m_axi_bresp (dma_bresp[{j}]), .m_axi_bvalid (dma_bvalid[{j}]), .m_axi_bready (dma_bready[{j}])")
            else:
                a(f"        {bus},")
                a(f"        .m_axi_awaddr (), .m_axi_awlen (), .m_axi_awsize (), .m_axi_awburst (), .m_axi_awcache (),")
                a(f"        .m_axi_awvalid (), .m_axi_awready (1'b0), .m_axi_wdata (), .m_axi_wstrb (), .m_axi_wlast (),")
                a(f"        .m_axi_wvalid (), .m_axi_wready (1'b0), .m_axi_bresp (2'b00), .m_axi_bvalid (1'b0), .m_axi_bready ()")
            a(f"    );")
            if not c.get("dma"):
                a("    /* verilator lint_on PINCONNECTEMPTY */")
    # ---------------- DUT ----------------
    a("")
    a("    // ---------------- DUT ----------------")
    conns = [(d["clock"], "dut_clk" if gated else "clk")]
    if "reset" in d:
        expr = "rst_n & ~dut_rst" if d["reset"]["active"] == "low" else "~rst_n | dut_rst"
        conns.append((d["reset"]["port"], expr))
    for c in d["channels"]:
        cn = f"ch_{c['name']}"
        conns.append((c["valid"], f"{cn}_valid"))
        if "ready" in c:
            conns.append((c["ready"], f"{cn}_ready"))
        if "stall" in c:
            conns.append((c["stall"], f"{cn}_stall"))
        wide = {}
        for f in c["fields"]:
            if c["kind"] == "source":
                hi = f["lsb"] + f["width"] - 1
                sl = f"[{f['lsb']}]" if f["width"] == 1 else f"[{hi}:{f['lsb']}]"
                if "slice" in f:
                    wide.setdefault(f["port"], []).append((f["slice"][0], f"{cn}_rec{sl}"))
                else:
                    conns.append((f["port"], f"{cn}_rec{sl}"))
            elif "slice" in f:
                wide[f["port"]] = None
            else:
                conns.append((f["port"], f"{cn}_f_{f['name']}"))
        for port, parts in wide.items():         # a port wider than a field: its parts, msb first
            if parts is None:
                conns.append((port, f"{cn}_p_{port}"))
            else:
                conns.append((port, "{" + ", ".join(e for _, e in sorted(parts, reverse=True)) + "}"))
    for p, v in d.get("tie", {}).items():
        conns.append((p, sv_value(v)))
    for e in d.get("export", []):
        conns.append((e["port"], e["port"]))
    params = d.get("parameters", {})
    if params:
        a(f"    {d['module']} #(")
        pl = [f"        .{k} ({sv_value(v)})" for k, v in params.items()]
        a(",\n".join(pl))
        a(f"    ) i_dut (")
    else:
        a(f"    {d['module']} i_dut (")
    width = max(len(p) for p, _ in conns)
    a(",\n".join(f"        .{p:<{width}} ({v})" for p, v in conns))
    a("    );")
    a("")
    unused = []
    for c in d["channels"]:
        cn = f"ch_{c['name']}"
        if c["kind"] == "source" and c["rec_w"] > c["rec_bits"]:
            hi, lo = c["rec_w"] - 1, c["rec_bits"]
            unused.append(f"{cn}_rec[{hi}:{lo}]" if hi > lo else f"{cn}_rec[{hi}]")
        if c["kind"] == "sink" and "ready" not in c or c["kind"] == "monitor":
            unused.append(f"{cn}_ready")
        if c["kind"] == "sink" or (c["kind"] == "monitor" and "stall" not in c and not c.get("lossless")):
            unused.append(f"{cn}_stall")
        if c["kind"] == "source" and not c.get("freeze_when_starved"):
            unused.append(f"{cn}_starve")
    if unused:
        a("    // Outputs of endpoints this DUT does not use.")
        a("    logic unused_ok;")
        a(f"    assign unused_ok = ^{{{', '.join(unused)}}};")
        a("")
    a(f"endmodule : {d['name']}_ocv")
    return "\n".join(L) + "\n"


# --------------------------------------------------------------------------- C / JSON metadata
def gen_c(d, src_name):
    nm = d["name"]
    L = [f"/* GENERATED by ocv_gen.py from {src_name} - do not edit; regenerate instead. */",
         f"#ifndef {nm.upper()}_OCV_META_H", f"#define {nm.upper()}_OCV_META_H", "",
         '#include "ocv_meta.h"', "",
         f"#define {nm.upper()}_OCV_DUT_ID 0x{d['dut_id']:08X}u",
         f"#define {nm.upper()}_OCV_ADDR_W {d['addr_w']}   /* the hub window: 2^ADDR_W bytes */",
         "#ifndef OCV_ADDR_W", f"#define OCV_ADDR_W {nm.upper()}_OCV_ADDR_W", "#endif", ""]
    for c in d["channels"]:
        L.append(f"static const ocv_field_t {nm}_{c['name']}_fields[] = {{")
        for f in c["fields"]:
            cmp, arg, fp = f["cmp"]
            L.append(f'    {{ "{f["name"]}", {f["lsb"]}, {f["width"]}, {int(f.get("signed", False))}, '
                     f'{cmp}, {fp}, 0x{arg:X}ull }},')
        L.append("};")
    L.append(f"static const ocv_channel_t {nm}_channels[] = {{")
    for c in d["channels"]:
        L.append(f'    {{ "{c["name"]}", {KIND_CODES[c["kind"]]}, {c["slot"]}, {c["rec_words"]}, {c["depth"]}, '
                 f'{len(c["fields"])}, {nm}_{c["name"]}_fields, {int(bool(c.get("lossless")))}, '
                 f'{int(bool(c.get("stream")))}, {int(bool(c.get("freeze_when_starved")))}, '
                 f'{int(bool(c.get("squash")))} }},')
    L.append("};")
    L.append(f'static const ocv_dut_t {nm}_dut = {{ "{nm}", {nm.upper()}_OCV_DUT_ID, '
             f'{len(d["channels"])}, {nm}_channels }};')
    L += ["", f"#endif /* {nm.upper()}_OCV_META_H */", ""]
    return "\n".join(L)


def gen_json(d):
    return json.dumps({
        "name": d["name"], "module": d["module"], "dut_id": f"0x{d['dut_id']:08X}",
        "addr_w": d["addr_w"], "slot_aw": d["slot_aw"],
        "dma_dw": d.get("dma_dw", 0), "dma_channels": sum(1 for c in d["channels"] if c.get("dma")),
        "channels": [{
            "name": c["name"], "kind": c["kind"], "slot": c["slot"], "rec_words": c["rec_words"],
            "depth": c["depth"], "lossless": bool(c.get("lossless")),
            "stream": bool(c.get("stream")), "freeze_when_starved": bool(c.get("freeze_when_starved")),
            "squash": bool(c.get("squash")),
            "fields": [{"name": f["name"], "lsb": f["lsb"], "width": f["width"],
                        "signed": bool(f.get("signed", False)),
                        "compare": f.get("compare", "exact") if c["kind"] != "source" else None}
                       for f in c["fields"]]}
            for c in d["channels"]]}, indent=2) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("descriptor")
    ap.add_argument("-o", "--out", default=".")
    ap.add_argument("--uvm", action="store_true", help="hub for transactions + the UVM layer")
    ap.add_argument("--dma", type=int, default=0, metavar="DW",
                    help="output channels empty into rings in PS memory over an AXI4 master of DW bits "
                         "(64, 128, 256, 512); the software uses them when it can map a DMA buffer")
    a = ap.parse_args()
    try:
        d = load(a.descriptor, a.uvm)
        raw = json.load(open(a.descriptor))
        if a.uvm:
            ocv_uvm_gen.uvm_transform(raw, need)
        d["_raw"] = raw
        if a.dma not in (0, 64, 128, 256, 512):
            raise DescError("--dma: data width 64, 128, 256 or 512")
        layout(d, a.dma)
    except (DescError, OSError) as e:
        print(f"ocv_gen: error: {e}", file=sys.stderr)
        sys.exit(2)
    os.makedirs(a.out, exist_ok=True)
    src = os.path.basename(a.descriptor)
    outs = {f"{d['name']}_ocv.sv": gen_sv(d, src),
            f"{d['name']}_ocv_meta.h": gen_c(d, src),
            f"{d['name']}_ocv_meta.json": gen_json(d)}
    if a.uvm:
        outs[f"{d['name']}_ocv_uvm_pkg.sv"] = ocv_uvm_gen.gen_uvm_pkg(d, src)
        outs[f"{d['name']}_ocv_uvm_harness.sv"] = ocv_uvm_gen.gen_uvm_harness(d, src, sv_value)
    for fn, text in outs.items():
        with open(os.path.join(a.out, fn), "w") as fh:
            fh.write(text)
    print(f"ocv_gen: {d['name']}: {len(d['channels'])} channel(s), DUT_ID 0x{d['dut_id']:08X}, "
          f"AXI-Lite address width {d['addr_w']} -> {', '.join(outs)}")


if __name__ == "__main__":
    main()
