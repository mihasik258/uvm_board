#!/usr/bin/env python3
"""cov_filter_proto.py - prototype of the coverage-keeping record filter (docs/COVERAGE.md, 2.3), the reference the
model's filter (models/cpu/ocv_cov_filter.c) is compared with: keep a record when it gives a new value of some
coverpoint's or cross's projection (the components it reads: tools/cov/cov_proj.py), or a new bit of a bit-wise
coverpoint's field. Every projection is prefixed by the instruction name, the trap and the interrupt flag (which
covergroups sample a record). Before a kept record: the records back to the third one before that moved isacov's
history, as context records (the models take them, no covergroup samples them: the harness's context flag).

    cov_filter_proto.py <fields.json> <bins.rep> <cfg> <spike.tab> <records.rvfi> <kept.rvfi>
      fields.json, bins.rep: examples/cva6/cov/cov.sh build, cov.sh run on no records
      cfg: a check file of the harness (cov.sh check: its first line), spike.tab: tools/cov/spike_table.cpp
"""
import sys

import cov_proj as cp


def main():
    fields, bins, cfg, spike, records, kept_file = sys.argv[1:7]
    tab = cp.Table(fields, bins, cfg, spike)
    print("projections:", len(tab.projs), "bit fields:", [str(b) for b in tab.bitf], "unsupported:", tab.unsup,
          file=sys.stderr)
    used = sorted({x for pr in tab.projs for x in pr if not x.startswith("prev.")} | {"M", "T", "INTR"})
    used_prev = sorted({x[5:] for pr in tab.projs for x in pr if x.startswith("prev.")})
    why, growth, ring, seen, vec_seen, masks = {}, {}, [], set(), set(), {}
    last_out = ctx = kept = n = 0
    out = open(kept_file, "w")
    pc_ = None
    for line in open(records):
        f = cp.record(line)
        n += 1
        name = tab.spike.name(f[0])
        c = cp.comps(f, name)
        pcomp = pc_ or {}
        cp.hazards(c, pc_)
        key0 = (c["M"], c["T"], f[10])
        keep = f[10] != 0                                   # an interrupt's first record: always
        # level 1: the vector of the components the projections read (this and the previous record)
        vec = (tuple(c[x] for x in used), tuple(pcomp[x] for x in used_prev) if pcomp else None)
        if vec not in vec_seen:
            vec_seen.add(vec)
            for pr in tab.projs:
                v = (key0, pr, tuple(pcomp.get(x[5:]) if x.startswith("prev.") else c.get(x) for x in pr))
                if v not in seen:
                    seen.add(v)
                    if not keep: why[pr] = why.get(pr, 0) + 1
                    keep = True
        # bit-wise fields: a bit not seen 1 / 0 before (per name, trap and interrupt)
        im = cp.imms(f[0])
        vals = {"a": f[4], "b": f[6], "d": f[8], "r1": f[3], 0: im[0], 1: im[1], 2: im[2], 3: im[3], 4: im[4]}
        for bf in tab.bitf:
            v = vals[bf]
            k = (key0, bf)
            s1, s0 = masks.get(k, (0, 0))
            if (v & ~s1) or (~v & 0xffffffff & ~s0):
                masks[k] = (s1 | v, s0 | (~v & 0xffffffff))
                if not keep: why["bit " + str(bf)] = why.get("bit " + str(bf), 0) + 1
                keep = True
        moves = tab.moves_history(f, name)
        if keep:
            kept += 1
            # the context: the records back to the third one before that moved the history (isacov's prev,
            # prev2, prev3), those not already written
            start = len(ring)
            nn = 0
            while start > 0 and nn < 3:
                start -= 1
                if ring[start][1]: nn += 1
            for ln, _, i in ring[start:]:
                if i > last_out:
                    out.write(ln.rstrip("\n") + " 1\n")
                    ctx += 1
            out.write(line)
            last_out = n
        ring.append((line, moves, n))
        if len(ring) > 64: ring.pop(0)
        if n in (100000, 1000000, 3000000): growth[n] = kept
        if moves:
            pc_ = c
    for k, v in sorted(why.items(), key=lambda x: -x[1])[:15]: print("%8d  %s" % (v, k), file=sys.stderr)
    print("growth", growth, file=sys.stderr)
    print("records", n, "kept", kept, "context", ctx, "vectors", len(vec_seen), "projection values", len(seen),
          file=sys.stderr)


if __name__ == "__main__":
    main()
