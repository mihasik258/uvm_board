#!/usr/bin/env python3
"""cov_check.py - the record filter's fields against what isacov's monitor and coverage model made of every record
(docs/COVERAGE.md, 2.3): the harness's check file (examples/cva6/cov/cov.sh check: +OCV_CHECK=) has, per record,
whether isacov's history moved, raw_hazard and csr_hazard as its model computed them, and the value of every
coverpoint expression and condition that reads only the transaction (tools/cov/cov_fields.py --sv). Checked on
every record:
  - history: the filter's rule (cov_proj.Table.moves_history) gives the model's;
  - hazards: the filter's components (with the filter's previous record) determine raw_hazard and csr_hazard;
  - each expression: the name, trap and interrupt flag with the components the filter keeps for it determine its
    value (a functional dependency); where the components are coarser than a raw value (a value class), they
    determine which of the literals and ranges of its coverpoint's bins the value is in; a bit-wise coverpoint's
    value equals the one whose bits the filter tracks.

    cov_check.py <fields.json> <bins.rep> <check file> <spike.tab> <records.rvfi>
Exit status 0: every check holds.
"""
import json
import re
import sys

import cov_proj as cp


def literal(s):
    """a SystemVerilog integer literal (32'h8000_0000, 'd5, 7), None: not one"""
    s = s.replace("_", "")
    m = re.fullmatch(r"(?:\d*)'[sS]?([hHdDbB])([0-9a-fA-F]+)", s)
    if m:
        return int(m.group(2), {"h": 16, "d": 10, "b": 2}[m.group(1).lower()])
    return int(s) if re.fullmatch(r"\d+", s) else None


def bin_sets(bins):
    """the literals and ranges of a coverpoint's bins: [(lo, hi)]"""
    out = []
    for body in re.findall(r"=\{([^{}]*)\}", bins):
        for part in body.split(","):
            m = re.fullmatch(r"\[([^:\]]+):([^\]]+)\]", part)
            if m:
                lo, hi = literal(m.group(1)), literal(m.group(2))
                if lo is not None and hi is not None:
                    out.append((lo, hi))
            elif literal(part) is not None:
                out.append((literal(part), literal(part)))
    return sorted(set(out))


def expr_comps(e):
    """the components determining an expression (None: a field the filter has no refinement of)"""
    m = re.fullmatch(r"\(?(instr[\w.\[\]:]*)==(instr[\w.\[\]:]*)\)?", e)
    if m and m.group(1) + "==" + m.group(2) in cp.EQ:
        return cp.EQ[m.group(1) + "==" + m.group(2)]
    cs = []
    for a, b in cp.PATH.findall(e):
        c = cp.comp_of("%s.%s" % (a, re.sub(r"\s+", "", b)))
        if c is None:
            # a field read through a method or CSR item: its leading path (instr.rvfi.name_csrs["x"].wdata[3])
            c = cp.comp_of(re.sub(r"\.wdata(\[\d+\])?$", "", "%s.%s" % (a, re.sub(r"\s+", "", b))))
        if c is None:
            return None
        cs += c
    return sorted(set(cs))


def main():
    fields, bins, chk, spike, records = sys.argv[1:6]
    tab = cp.Table(fields, bins, chk, spike)
    checked = json.load(open(fields))["checked"]
    # per expression: its components, the bins of the coverpoints reading it as their value, bit-wise source
    roles = []
    for e in checked:
        cs = expr_comps(e)
        sets, bit, value = set(), None, False
        for cg, d in tab.cgs.items():
            for label, it in d["items"].items():
                if it["kind"] != "coverpoint" or (cg.split("@")[0], label) not in tab.has_bins:
                    continue
                if it["value"] == e and it.get("bitwise") and cp.BITF.get(it["expr"]) is not None:
                    bit = cp.BITF[it["expr"]]   # (bit-wise by a projection - get_field_imm(): its value below)
                elif it["value"] == e:
                    value = True
                    sets |= set(bin_sets(it["bins"]))
                elif e in it["iffs"]:
                    value = True
        if value and cs is None:
            sys.exit("cov_check: %s: read by a coverpoint, no refinement of it in the filter (cov_proj.FIELD)" % e)
        # a value only bit-wise coverpoints read: its bits (the filter's masks), not its value
        roles.append((e, cs if value else None, sorted(sets), bit))
    fd = [dict() for _ in checked]          # key -> value (or membership)
    bad = [0] * len(checked)
    example = [None] * len(checked)
    hist_bad = hz_bad = 0
    hz = {}
    n = 0
    pc_ = None
    fc = open(chk)
    fc.readline()
    for line in open(records):
        f = cp.record(line)
        if len(f) > 15 and f[15]:
            continue                        # (context records: the check runs on all records, none of these)
        row = fc.readline().split()
        moved, raw, csr, vals = int(row[0]), int(row[1]), int(row[2]), row[3:]
        n += 1
        name = tab.spike.name(f[0])
        c = cp.comps(f, name)
        cp.hazards(c, pc_)
        p = pc_ or {}
        key0 = (name, f[2], f[10])
        moves = tab.moves_history(f, name)
        if moves != bool(moved):
            hist_bad += 1
            if hist_bad <= 5: print("history: record %d (%s): filter %d, isacov %d" % (n - 1, name, moves, moved))
        for k, v in ((("raw", name, p.get("M"), c["HZ"]), raw), (("csr", p.get("M"), p.get("CSR"), p.get("R1F")), csr)):
            if hz.setdefault(k, v) != v:
                hz_bad += 1
                if hz_bad <= 5: print("hazard %s: record %d: %s and %s" % (k, n - 1, hz[k], v))
        im = cp.imms(f[0])
        src = {"a": f[4], "b": f[6], "d": f[8], "r1": f[3], 0: im[0], 1: im[1], 2: im[2], 3: im[3], 4: im[4]}
        for j, (e, cs, sets, bit) in enumerate(roles):
            if vals[j] == "-":
                continue                    # (no covergroup reading it samples this record)
            v = int(vals[j], 16)
            if bit is not None and src[bit] != v:
                bad[j] += 1
                example[j] = example[j] or "record %d: bit-wise value %x, filter's %x" % (n - 1, v, src[bit])
            if cs is None:
                continue
            k = (key0, tuple(c[x] for x in cs))
            if sets:                        # a value class: which literals / ranges of the bins it is in
                v = tuple(lo <= v <= hi for lo, hi in sets)
            if fd[j].setdefault(k, v) != v:
                bad[j] += 1
                example[j] = example[j] or "record %d: %s gives %s and %s" % (n - 1, k, fd[j][k], v)
        if moves:
            pc_ = c
    ok = hist_bad == 0 and hz_bad == 0 and not any(bad)
    unchecked = [e for e, cs, sets, bit in roles if cs is None and bit is None]
    print("records %d, expressions %d: %d values, %d bit-wise, %d read by no coverpoint with bins: %s"
          % (n, len(roles), sum(cs is not None for e, cs, s, b in roles), sum(b is not None for e, cs, s, b in roles),
             len(unchecked), unchecked))
    print("history: %d differ; hazards: %d differ" % (hist_bad, hz_bad))
    for j, (e, cs, sets, bit) in enumerate(roles):
        if bad[j]:
            print("DIFFER %s (%s, bins %s): %d - %s" % (e, cs, sets, bad[j], example[j]))
    print("cov_check: %s" % ("every field determined" if ok else "FAILED"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
