"""cov_proj.py - the record filter's view of a testbench's covergroups (docs/COVERAGE.md, 2.3): the components of
an RVFI record (refinements of the fields isacov's monitor gives the covergroups), the projections the filter keeps
(per coverpoint and cross: the components it reads), the bit-wise fields, the records that move isacov's history,
and Spike's instruction names from its own table (tools/cov/spike_table.cpp). Used by the filter's prototype
(cov_filter_proto.py), its table for the model (cov_filter_gen.py) and the check (cov_check.py).

    tab = load(fields.json, bins.rep, cfg, spike.tab)    cfg: the harness's "cfg <flag>=<v>..." line (+OCV_CHECK=)
"""
import json
import re

# a record: (insn, pc, trap, rs1, rs1_rdata, rs2, rs2_rdata, rd, rd_wdata, mem_addr, intr, mcause, mstatus, mie, mip)


class Spike:
    """Spike's name of a word, as its disassembler searches (disasm.cc: lookup); memoized per word"""
    def __init__(self, path):
        self.chain = {}
        for line in open(path):
            b, m, k, n = line.rstrip("\n").split(" ", 3)
            self.chain.setdefault(int(b), []).append((int(m, 16), int(k, 16), n))
        self.memo = {}

    def name(self, w):
        n = self.memo.get(w)
        if n is None:
            n = "unknown"
            for b in ((w & 0x7f) % 255, (w & 0xe003) % 255, 255):
                hit = next((x[2] for x in self.chain.get(b, ()) if w & x[1] == x[0]), None)
                if hit is not None:
                    n = hit
                    break
            self.memo[w] = n
        return n


def vclass(v):
    """the values the covergroups tell apart (0, 1, all ones, the sign bit alone: literals of their bins), the sign"""
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
    """the immediates as isacov's monitor keeps them (immi, imms, immb, immu, immj: Spike's i_imm, s_imm,
    sb_imm >> 1, u_imm >> 12, uj_imm >> 1 in fields of 12, 12, 12, 20, 20 bits); 0 for a compressed word"""
    if w & 3 != 3: return (0, 0, 0, 0, 0)
    i = w >> 20
    s = ((w >> 25) << 5) | ((w >> 7) & 31)
    b = (((w >> 31) & 1) << 11) | (((w >> 7) & 1) << 10) | (((w >> 25) & 63) << 4) | ((w >> 8) & 15)
    u = w >> 12
    j = (((w >> 31) & 1) << 19) | (((w >> 12) & 255) << 11) | (((w >> 20) & 1) << 10) | ((w >> 21) & 1023)
    return (i, s, b, u, j)


# the components, in the model's order (models/cpu/ocv_cov_filter.c: comps); a tuple-valued one is packed there
COMPS = ["M", "MA", "T", "R1", "R2", "RD", "W", "RDA", "R1A", "R2A", "CSR", "R1F", "CW", "EQ_RD_R1", "EQ_RD_R2",
         "EQ_RDA_R1A", "EQ_RDA_R2A", "C1", "C2", "CD", "V2LOW", "REL", "IMMC", "IMM5", "INTR", "MCAUSE", "MSTATUS",
         "MIE", "MIP", "INSN6_0", "INSN14_12", "INSN31_25", "NR1", "NR2", "NRD", "HZ"]


def comps(r, name):
    """a record's components (HZ: with the previous record's, set by the caller)"""
    w = r[0]
    c = w & 3 != 3
    im = imms(w)
    return {
        "M": name, "MA": r[9] & 3, "T": r[2],
        "R1": w if c else r[3], "R2": w if c else r[5], "RD": w if c else (w >> 7) & 31, "W": w,
        "RDA": r[7], "R1A": r[3], "R2A": r[5],
        # the CSR fields: the monitor sets them for SYSTEM instructions only; the compressed fields: for compressed only
        "CSR": w >> 20 if w & 0x7f == 0x73 else 0, "R1F": (w >> 15) & 31 if w & 0x7f == 0x73 else 0,
        "CW": w if c else 0,
        "EQ_RD_R1": w if c else ((w >> 7) & 31) == r[3], "EQ_RD_R2": w if c else ((w >> 7) & 31) == r[5],
        "EQ_RDA_R1A": r[7] == r[3], "EQ_RDA_R2A": r[7] == r[5],
        "C1": vclass(r[4]), "C2": vclass(r[6]), "CD": vclass(r[8]), "V2LOW": r[6] & 31, "REL": rel(r[4], r[6]),
        "IMMC": tuple(cls3(v, n) for v, n in zip(im, (12, 12, 12, 20, 20))), "IMM5": (w >> 20) & 31,
        "INTR": r[10], "MCAUSE": r[11], "MSTATUS": r[12], "MIE": r[13], "MIP": r[14],
        "INSN6_0": w & 0x7f, "INSN14_12": (w >> 12) & 7, "INSN31_25": w >> 25,
        # the register numbers the monitor compares (is_raw_hazard): Spike's rvc_rs1 = rvc_rd = bits 11:7,
        # rvc_rs2 = bits 6:2 for a compressed word
        "NR1": (w >> 7) & 31 if c else (w >> 15) & 31, "NR2": (w >> 2) & 31 if c else (w >> 20) & 31,
        "NRD": (w >> 7) & 31,
    }


def hazards(c, p):
    """HZ: the equalities is_raw_hazard reads (the previous record's rd against rs1, rs2 and zero)"""
    prd = p["NRD"] if p else -1
    c["HZ"] = (prd == c["NR1"], prd == c["NR2"], prd == 0)


# the components that determine a field the covergroups read (a refinement of it: tools/cov/cov_check.py)
FIELD = {
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

# the hazard arguments of cg_sequential (is_raw_hazard: prev.rd == rs1/rs2, prev.rd != 0, the valid flags by name;
# is_csr_hazard: the previous instruction's CSR write)
HAZ = {"raw_hazard": ["M", "prev.M", "HZ"], "csr_hazard": ["prev.M", "prev.CSR", "prev.R1F"]}

# bit-wise coverpoints (isacov's ISACOV_CP_BITWISE) by expression: the value whose bits the filter tracks
BITF = {"(instr.immb)iff(1)": 2, "(instr.immi)iff(1)": 0, "(instr.immj)iff(1)": 4, "(instr.imms)iff(1)": 1,
        "(instr.immu)iff(1)": 3, "(instr.rd_value)iff(1)": "d", "(instr.rs1_value)iff(1)": "a",
        "(instr.rs2_value)iff(1)": "b", "(instr.rvfi.rd1_wdata)iff(1)": "d", "(instr.rvfi.rs1_rdata)iff(1)": "a",
        "(instr.rvfi.rs2_rdata)iff(1)": "b", "(instr.rs1)iff(1)": "r1", "(instr.get_field_imm())iff(1)": None}

# an iff that only compares two fields: whether they are equal (the fields themselves exact for a 32-bit
# instruction; a compressed one is its whole word)
EQ = {"instr.rd==instr.rs1": ["EQ_RD_R1"], "instr.rd==instr.rs2": ["EQ_RD_R2"],
      "instr.c_rd==instr.c_rs1": ["CW"], "instr.c_rdrs1==instr.rs2": ["CW"],
      "instr.rvfi.rd1_addr==instr.rvfi.rs1_addr": ["EQ_RDA_R1A"], "instr.rvfi.rd1_addr==instr.rvfi.rs2_addr": ["EQ_RDA_R2A"]}

PATH = re.compile(r"\b(instr(?:_prev\d?)?)\s*\.\s*([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*(?:\s*\[[^\]]*\])*(?:\s*\(\s*\))?)")


def comp_of(path):
    """the components that determine a field (instr_prev.x: the previous record's), None: not known"""
    pre = ""
    m = re.match(r"instr_(prev\d?)\.(.*)", path)
    if m:
        pre, path = m.group(1) + ".", "instr." + m.group(2)
    p = re.sub(r"\s+", "", path)
    if p not in FIELD:
        return None
    return [pre + x for x in FIELD[p]]


def bins_rep(path):
    """the items with bins in this configuration: the harness's report on no records"""
    has, cg = set(), None
    for line in open(path):
        if not line.startswith(" "):
            cg = line.split()[0]
        else:
            item, ct = line.split()[:2]
            if int(ct.split("/")[1]) > 0:
                has.add((cg, item))
    return has


def cfg_flags(path):
    """the configuration flags of the harness's check file (first line "cfg <flag>=<v>...")"""
    first = open(path).readline().split()
    assert first and first[0] == "cfg", path + ": no cfg line"
    return {k: int(v) for k, v in (x.split("=") for x in first[1:])}


class Table:
    def __init__(self, fields, bins, cfg, spike):
        d = json.load(open(fields))
        self.cgs = d["covergroups"]
        self.has_bins = bins_rep(bins)
        self.cfg = cfg_flags(cfg)
        self.spike = Spike(spike)
        # isacov's history: the names (Spike's spelling) each kind of record moves it with, in this configuration
        self.hist = {"normal": set(), "ecall_or_ebreak": set()}
        for h in d["history"]:
            if self.cfg.get(h["flag"]):
                self.hist[h["when"]] |= {n.lower().replace("_", ".") for n in h["names"]}
        self.projections()

    def projections(self):
        """per coverpoint (with bins) the components it reads; per cross the union of its coverpoints'; the
        bit-wise fields; item_proj: (covergroup, item) -> its projection (cov_check.py)"""
        projs, bitf, unsup, self.item_proj = set(), set(), [], {}
        for cg_key, d in self.cgs.items():
            cg = cg_key.split("@")[0]               # (a name defined twice: cov_fields.py)
            cps = {}
            for label, it in d["items"].items():
                if it["kind"] != "coverpoint":
                    continue
                if (cg, label) not in self.has_bins:
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
                        paths = paths + ["%s.%s" % (a, re.sub(r"\s+", "", b)) for a, b in PATH.findall(cond)]
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
                self.item_proj[(cg, label)] = cps[label]
            for label, it in d["items"].items():
                if it["kind"] == "cross" and (cg, label) in self.has_bins:
                    u = set()
                    for c in it["of"]:
                        if cps.get(c): u |= set(cps[c])
                    projs.add(tuple(sorted(u)))
                    self.item_proj[(cg, label)] = tuple(sorted(u))
        self.projs = sorted(projs)
        self.bitf = sorted(bitf, key=str)
        self.unsup = unsup

    def moves_history(self, r, name):
        """isacov's sample() dispatches the record (and moves instr_prev...): a normal record (no trap) of a name its
        normal branches take, or a trapping ecall/ebreak (cause 3, 8, 11: the monitor's cause is trap >> 1)"""
        t = r[2]
        return ((t & 1) == 0 and name in self.hist["normal"]) or \
            ((t >> 1) in (3, 8, 11) and name in self.hist["ecall_or_ebreak"])


def record(line):
    return [int(x, 16) for x in line.split()]
