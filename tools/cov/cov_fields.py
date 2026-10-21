#!/usr/bin/env python3
"""cov_fields.py - what each coverpoint of a testbench's covergroups reads (docs/COVERAGE.md: the projections a
record filter keeps). Input: covergroup sources after the preprocessor (verilator -E -P). Output: per covergroup,
per coverpoint, the access paths of the sampled transaction it reads - in its expression, its iff and its bins'
iff - and per cross its coverpoints.

    tools/cov/cov_fields.py <preprocessed.sv>... [--json out.json]
"""
import json
import re
import sys

PATH = re.compile(r"\b(instr(?:_prev\d?)?)\s*\.\s*([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*(?:\s*\[[^\]]*\])*(?:\s*\(\s*\))?)")


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", " ", t, flags=re.S)
    return re.sub(r"//[^\n]*", " ", t)


def balanced(t, i, op="{", cl="}"):
    """index just past the bracket matching t[i] == op"""
    d = 0
    for j in range(i, len(t)):
        if t[j] == op:
            d += 1
        elif t[j] == cl:
            d -= 1
            if d == 0:
                return j + 1
    return len(t)


def items(body):
    """coverpoint / cross items of a covergroup body: (label, kind, head text, block text)"""
    out = []
    for m in re.finditer(r"(\w+)\s*:\s*(coverpoint|cross)\b", body):
        i = m.end()
        # the head runs to the item's '{' or ';' at depth 0
        d = 0
        j = i
        while j < len(body):
            c = body[j]
            if c == "(":
                d += 1
            elif c == ")":
                d -= 1
            elif d == 0 and c in "{;":
                break
            j += 1
        head = body[i:j]
        block = body[j:balanced(body, j)] if j < len(body) and body[j] == "{" else ""
        out.append((m.group(1), m.group(2), head, block))
    return out


def iff_exprs(t):
    """the parenthesized expression after each 'iff'"""
    out = []
    for m in re.finditer(r"\biff\s*\(", t):
        i = m.end() - 1
        out.append(t[i + 1:balanced(t, i, "(", ")") - 1])
    return out


def norm(p):
    return re.sub(r"\s+", "", p)


def main():
    argv = sys.argv[1:]
    out = None
    if "--json" in argv:
        out = argv[argv.index("--json") + 1]
        del argv[argv.index("--json"):argv.index("--json") + 2]
    files = argv
    res = {}
    for f in files:
        t = strip_comments(open(f).read())
        for m in re.finditer(r"\bcovergroup\s+(\w+)", t):
            end = t.find("endgroup", m.end())
            hdr_end = t.find(";", m.end())
            sample = t[m.end():hdr_end]
            body = t[hdr_end + 1:end]
            cg = {"file": f, "sample": norm(sample), "items": {}}
            for label, kind, head, block in items(body):
                if kind == "coverpoint":
                    paths = sorted({"%s.%s" % (a, norm(b)) for a, b in PATH.findall(head + " " + block)})
                    # sample arguments read directly (raw_hazard, csr_hazard, ...)
                    args = sorted(set(re.findall(r"\b(\w+_hazard)\b", head + block)))
                    bins = re.findall(r"\b(?:wildcard\s+)?(?:bins|ignore_bins|illegal_bins)\s+(\w+)", block)
                    # bit-wise: every bin is BIT<i>_<v> (isacov's ISACOV_CP_BITWISE): bit i was v
                    bitwise = bool(bins) and all(re.fullmatch(r"BIT\d+_[01]", b) for b in bins)
                    # the conditions apart (the coverpoint's iff and its bins' iff): a projection may keep
                    # only whether one holds
                    iffs = [norm(x) for x in iff_exprs(head + " " + block)]
                    ehead = re.split(r"\biff\b", head)[0]
                    epaths = sorted({"%s.%s" % (a, norm(b)) for a, b in PATH.findall(ehead)})
                    cg["items"][label] = {"kind": kind, "expr": norm(head), "paths": paths + args,
                                          "bitwise": bitwise, "expr_paths": epaths + sorted(set(re.findall(r"\b(\w+_hazard)\b", ehead))),
                                          "iffs": iffs}
                else:
                    cps = [c.strip() for c in re.split(r",", head) if c.strip()]
                    cg["items"][label] = {"kind": kind, "of": cps}
            res[m.group(1)] = cg
    if out:
        json.dump(res, open(out, "w"), indent=1)
    allp = {}
    for cg, d in res.items():
        for it in d["items"].values():
            for p in it.get("paths", []):
                allp.setdefault(p, set()).add(cg)
    for p in sorted(allp):
        print("%-45s %d covergroups" % (p, len(allp[p])))


if __name__ == "__main__":
    main()
