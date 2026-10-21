"""prototype of the coverage-keeping record filter (docs/COVERAGE.md): keep a record when it gives a new value
of some coverpoint's or cross's projection (the fields it reads, from tools/cov/cov_fields.py), or a new bit of
a bit-wise coverpoint's field. Every projection is prefixed by the instruction name and the trap (which
covergroups sample a record). usage: filt.py fields.json names.txt records.rvfi kept.rvfi"""
import json, re, sys

fields = json.load(open(sys.argv[1]))
SAMPLED = set(open(sys.argv[6]).read().split())
# items with bins in this configuration (the harness's report on no records: "<cg> <name> <pct>", "  <item> <c>/<t> <pct>")
has_bins = set()
cg_type = None
for line in open(sys.argv[5]):
    if not line.startswith(" "):
        cg_type = line.split()[0]
    else:
        item, ct = line.split()[:2]
        if int(ct.split("/")[1]) > 0: has_bins.add((cg_type, item))
names = {}
for line in open(sys.argv[2]):
    w, n = line.rstrip("\n").split(" ", 1)
    names[int(w, 16)] = n

def vclass(v):
    if v == 0: return 0
    if v == 1: return 1
    if v == 0xffffffff: return 2
    if v == 0x80000000: return 3
    return 4 if v >> 31 else 5
def cls3(v, bits):
    return 0 if v == 0 else (1 if v >> (bits - 1) else 2)
def rel(a, b):
    sa = a - (1 << 32) if a >> 31 else a
    sb = b - (1 << 32) if b >> 31 else b
    return (a == b) | ((sa < sb) << 1) | ((a < b) << 2)
def imms(w):
    """the immediates as Spike's i_imm/s_imm/sb_imm/u_imm/uj_imm give them (0 for a compressed word)"""
    if w & 3 != 3: return (0, 0, 0, 0, 0)
    i = w >> 20
    s = ((w >> 25) << 5) | ((w >> 7) & 31)
    b = (((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11) | (((w >> 25) & 63) << 5) | (((w >> 8) & 15) << 1)
    u = w >> 12
    j = (((w >> 31) & 1) << 20) | (((w >> 12) & 255) << 12) | (((w >> 20) & 1) << 11) | (((w >> 21) & 1023) << 1)
    return (i, s, b, u, j)

# a record's components: r = (insn, pc, trap, rs1, a, rs2, b, rd, d, maddr, intr), p = the previous record
def comps(r):
    w = r[0]
    c = w & 3 != 3
    im = imms(w)
    return {
        "M": names[w], "MA": r[9] & 3, "T": r[2],
        "R1": w if c else r[3], "R2": w if c else r[5], "RD": w if c else (w >> 7) & 31, "W": w,
        "RDA": r[7], "R1A": r[3], "R2A": r[5],
        # the CSR fields: the monitor sets them for SYSTEM instructions only; the compressed fields: for compressed only
        "CSR": w >> 20 if w & 0x7f == 0x73 else 0, "R1F": (w >> 15) & 31 if w & 0x7f == 0x73 else 0,
        "CW": w if c else 0,
        "EQ_RD_R1": w if c else ((w >> 7) & 31) == r[3], "EQ_RD_R2": w if c else ((w >> 7) & 31) == r[5],
        "EQ_RDA_R1A": r[7] == r[3], "EQ_RDA_R2A": r[7] == r[5],
        "C1": vclass(r[4]), "C2": vclass(r[6]), "CD": vclass(r[8]), "V2LOW": r[6] & 31, "REL": rel(r[4], r[6]),
        "IMMC": tuple(cls3(v, n) for v, n in zip(im, (12, 12, 13, 20, 21))), "IMM5": (w >> 20) & 31,
        "INTR": r[10], "MCAUSE": r[11], "MSTATUS": r[12], "MIE": r[13], "MIP": r[14],
        "INSN6_0": w & 0x7f, "INSN14_12": (w >> 12) & 7, "INSN31_25": w >> 25,
    }

def comp_of(path):
    """the components that determine a field the covergroups read (a refinement of it)"""
    pre = ""
    m = re.match(r"instr_(prev\d?)\.(.*)", path)
    if m:
        pre, path = m.group(1) + ".", "instr." + m.group(2)
    t = {
        "instr.name": ["M"], "instr.group": ["M", "MA"], "instr.csr": ["M", "CSR"],
        "instr.is_csr_write": ["M", "CSR", "R1F"], "instr.is_csr_write()": ["M", "CSR", "R1F"],
        "instr.rs1": ["M", "R1"], "instr.rs2": ["M", "R2"], "instr.rd": ["M", "RD"], "instr.rs2[4:0]": ["M", "R2"],
        "instr.c_rs1": ["CW"], "instr.c_rs2": ["CW"], "instr.c_rd": ["CW"], "instr.c_rdrs1": ["CW"],
        "instr.c_imm_value_type": ["CW"], "instr.get_field_imm()": ["CW"],
        "instr.rs1_value": ["C1"], "instr.rs1_value_type": ["M", "C1"], "instr.rvfi.rs1_rdata": ["C1"],
        "instr.rs2_value": ["C2"], "instr.rs2_value_type": ["M", "C2"], "instr.rvfi.rs2_rdata": ["C2"],
        "instr.rd_value": ["CD"], "instr.rd_value_type": ["M", "CD"], "instr.rvfi.rd1_wdata": ["CD"],
        "instr.rs2_value[4:0]": ["V2LOW"], "instr.get_instr_value_type": [], "instr.is_branch_taken()": ["M", "REL"],
        "instr.immi": ["M", "IMMC"], "instr.imms": ["M", "IMMC"], "instr.immb": ["M", "IMMC"], "instr.immu": ["M", "IMMC"],
        "instr.immj": ["M", "IMMC"], "instr.immi[4:0]": ["M", "IMM5"],
        "instr.immi_value_type": ["M", "IMMC"], "instr.imms_value_type": ["M", "IMMC"], "instr.immb_value_type": ["M", "IMMC"],
        "instr.immu_value_type": ["M", "IMMC"], "instr.immj_value_type": ["M", "IMMC"],
        "instr.trap": ["T"], "instr.cause": ["T"], "instr.rvfi.trap[8:3]": ["T"], "instr.rvfi.trap[11:9]": ["T"],
        "instr.rvfi.trap[13:12]": ["T"], "instr.rvfi.trap[1]": ["T"], "instr.rvfi.trap[0]": ["T"],
        "instr.trap[8:3]": ["T"], "instr.trap[11:9]": ["T"], "instr.trap[13:12]": ["T"], "instr.trap[1]": ["T"], "instr.trap[0]": ["T"],
        "instr.rvfi.mem_addr[1:0]": ["MA"], "instr.rvfi.mem_addr[0]": ["MA"],
        "instr.rvfi.insn[6:0]": ["INSN6_0"], "instr.rvfi.insn[14:12]": ["INSN14_12"], "instr.rvfi.insn[31:25]": ["INSN31_25"],
        "instr.rvfi.rd1_addr": ["RDA"], "instr.rvfi.rs1_addr": ["R1A"], "instr.rvfi.rs2_addr": ["R2A"],
        "instr.rvfi.intr": ["INTR"], 'instr.rvfi.name_csrs["mcause"]': ["MCAUSE"],
        'instr.rvfi.name_csrs["mstatus"]': ["MSTATUS"], 'instr.rvfi.name_csrs["mie"]': ["MIE"],
        'instr.rvfi.name_csrs["mip"]': ["MIP"],
        "instr.rs1_valid": ["M"], "instr.rs2_valid": ["M"], "instr.rd_valid": ["M"],
    }
    p = re.sub(r"\s+", "", path)
    if p not in t:
        return None
    return [pre + x for x in t[p]]

# the hazard functions compare fields only for equality (is_raw_hazard: prev.rd == rs1/rs2, prev.rd != 0)
HAZ = {"raw_hazard": ["M", "prev.M", "HZ"], "csr_hazard": ["prev.M", "prev.CSR", "prev.R1F"]}
BITF = {"(instr.immb)iff(1)": 2, "(instr.immi)iff(1)": 0, "(instr.immj)iff(1)": 4, "(instr.imms)iff(1)": 1,
        "(instr.immu)iff(1)": 3, "(instr.rd_value)iff(1)": "d", "(instr.rs1_value)iff(1)": "a",
        "(instr.rs2_value)iff(1)": "b", "(instr.rvfi.rd1_wdata)iff(1)": "d", "(instr.rvfi.rs1_rdata)iff(1)": "a",
        "(instr.rvfi.rs2_rdata)iff(1)": "b", "(instr.rs1)iff(1)": "r1", "(instr.get_field_imm())iff(1)": None}

# an iff that only compares two fields: whether they are equal (the fields themselves exact for a 32-bit
# instruction; a compressed one is its whole word)
EQ = {"instr.rd==instr.rs1": ["EQ_RD_R1"], "instr.rd==instr.rs2": ["EQ_RD_R2"],
      "instr.c_rd==instr.c_rs1": ["CW"], "instr.c_rdrs1==instr.rs2": ["CW"],
      "instr.rvfi.rd1_addr==instr.rvfi.rs1_addr": ["EQ_RDA_R1A"], "instr.rvfi.rd1_addr==instr.rvfi.rs2_addr": ["EQ_RDA_R2A"]}
projs, bitf, unsup = set(), set(), []
for cg, d in fields.items():
    cps = {}
    for label, it in d["items"].items():
        if it["kind"] != "coverpoint":
            continue
        if (cg, label) not in has_bins:
            cps[label] = None
            continue
        if it.get("bitwise") and BITF.get(it["expr"]) is not None:
            bitf.add(BITF[it["expr"]])
            cps[label] = None
            continue
        cs = []
        paths = it["expr_paths"]
        for cond in it["iffs"]:
            m = re.fullmatch(r"(instr[\w.\[\]:]*)==(instr[\w.\[\]:]*)", cond)
            if m and m.group(1) + "==" + m.group(2) in EQ:
                cs += EQ[m.group(1) + "==" + m.group(2)]
            else:
                paths = paths + ["%s.%s" % (a, re.sub(r"\s+", "", b)) for a, b in re.findall(
                    r"\b(instr(?:_prev\d?)?)\s*\.\s*([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*(?:\s*\[[^\]]*\])*(?:\s*\(\s*\))?)", cond)]
        for p in paths:
            c = HAZ.get(p) or comp_of(p)
            if c is None:
                unsup.append((cg, label, p))
                c = ["W"]
            cs += c
        if it.get("bitwise"):          # get_field_imm(): the whole word
            cs = ["CW"]
        cps[label] = tuple(sorted(set(cs)))
        projs.add(cps[label])
    for label, it in d["items"].items():
        if it["kind"] == "cross" and (cg, label) in has_bins:
            u = set()
            for c in it["of"]:
                if cps.get(c): u |= set(cps[c])
            projs.add(tuple(sorted(u)))
print("projections:", len(projs), "bit fields:", sorted(map(str, bitf)), "unsupported:", unsup, file=sys.stderr)

why = {}
growth = {}
ring = []
last_out = 0
ctx = 0
seen = set()
vec_seen = set()
masks = {}
kept = 0
n = 0
out = open(sys.argv[4], "w")
prev = None
pc_ = None
for line in open(sys.argv[3]):
    f = [int(x, 16) for x in line.split()]
    n += 1
    c = comps(f)
    pcomp = pc_ or {}
    prd = pcomp.get("RD", -1)
    c["HZ"] = (prd == c["R1"], prd == c["R2"], prd == 0)
    key0 = (c["M"], c["T"], f[10])
    keep = f[10] != 0                                   # an interrupt's first record: always
    # level 1: the whole vector of components (this and the previous record)
    vec = (tuple(sorted(c.items())), tuple(sorted(pcomp.items())) if pcomp else None)
    if vec not in vec_seen:
        vec_seen.add(vec)
        for pr in projs:
            v = (key0, pr, tuple(pcomp.get(x[5:]) if x.startswith("prev.") else c.get(x) for x in pr))
            if v not in seen:
                seen.add(v)
                if not keep: why[pr] = why.get(pr, 0) + 1
                keep = True
    # bit-wise fields: a bit not seen 1 / 0 before (per name and trap)
    im = imms(f[0])
    vals = {"a": f[4], "b": f[6], "d": f[8], "r1": f[3], 0: im[0], 1: im[1], 2: im[2], 3: im[3], 4: im[4]}
    for bf in bitf:
        v = vals[bf]
        k = (key0, bf)
        s1, s0 = masks.get(k, (0, 0))
        if (v & ~s1) or (~v & 0xffffffff & ~s0):
            masks[k] = (s1 | v, s0 | (~v & 0xffffffff))
            if not keep: why["bit " + str(bf)] = why.get("bit " + str(bf), 0) + 1
            keep = True
    if keep:
        kept += 1
        # the context: the records back to the third normal one before (isacov's history: prev, prev2, prev3),
        # those not already written
        start = len(ring)
        nn = 0
        while start > 0 and nn < 3:
            start -= 1
            if ring[start][1]: nn += 1
        for idx, (ln, _, i) in enumerate(ring[start:]):
            if i > last_out:
                out.write(ln.rstrip("\n") + " 1\n")
                ctx += 1
        out.write(line)
        last_out = n
    # isacov's history (prev, prev2, prev3) moves on an instruction it sampled: normal, and a name its sample()
    # dispatches (a case label; Spike's names it does not know are UNKNOWN)
    normal = ((f[2] & 1) == 0 or (((f[2] >> 9) & 7) == 4 and ((f[2] >> 1) & 1) == 0)) and \
        c["M"].upper().replace(".", "_") in SAMPLED
    ring.append((line, normal, n))
    if len(ring) > 64: ring.pop(0)
    if n in (100000, 1000000, 3000000): growth[n] = kept
    if normal:
        prev = f
        pc_ = dict(c)
for k, v in sorted(why.items(), key=lambda x: -x[1])[:15]: print("%8d  %s" % (v, k), file=sys.stderr)
print("growth", growth, file=sys.stderr)
print("records", n, "kept", kept, "context", ctx, "vectors", len(vec_seen), "projection values", len(seen), file=sys.stderr)
