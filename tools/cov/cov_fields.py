#!/usr/bin/env python3
"""cov_fields.py - what each coverpoint of a testbench's covergroups reads (docs/COVERAGE.md: the projections a
record filter keeps). Input: covergroup sources after the preprocessor (verilator -E -P). Output: per covergroup,
per coverpoint, the access paths of the sampled transaction it reads - in its expression, its iff and its bins'
iff - and per cross its coverpoints; and which records move isacov's history (the instructions its sample()
dispatches, per branch: a normal record or a trapping ecall/ebreak, and the configuration flag of the branch).

    tools/cov/cov_fields.py <preprocessed.sv>... [--json out.json] [--sv out.svh]

--sv: a SystemVerilog function of the monitor's transaction that prints the value of every coverpoint expression
and condition that reads only it (ocv_cov_fields), for the harness's check mode (examples/cva6/cov: +OCV_CHECK=,
tools/cov/cov_check.py).
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


def history(t):
    """isacov's sample(): per branch ('normal' or 'ecall_or_ebreak') and configuration flag, the instruction names
    it dispatches (case labels) - a record moves the history (instr_prev...) when one of them takes it"""
    m = re.search(r"function\s+void\s+\w+::sample\s*\(.*?\bendfunction\b", t, re.S)
    if not m:
        return None
    out = []
    parts = re.split(r"\bif\s*\(\s*!\s*have_sampled\s*&&\s*", m.group(0))[1:]
    for p in parts:
        c = re.match(r"is_(normal_instr|ecall_or_ebreak)\s*&&\s*cfg\.core_cfg\.(\w+)\s*\)", p)
        if not c:
            continue
        case = re.search(r"\bcase\s*\(\s*instr\.name\s*\)(.*?)\bendcase\b", p, re.S)
        if not case:
            continue
        labels = [x for x in re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*:", case.group(1), re.M)]
        # the covergroup each name samples: "<label>: <instance>.sample(instr);" and "<type> <instance>;"
        sampled = {}
        for lab, inst in re.findall(r"^\s*([A-Z][A-Z0-9_]*)\s*:\s*(\w+)\s*\.\s*sample\b", case.group(1), re.M):
            d = re.search(r"^\s*(\w+)\s+%s\s*;" % inst, t, re.M)
            if d:
                sampled[lab] = d.group(1)
        out.append({"when": "normal" if c.group(1) == "normal_instr" else "ecall_or_ebreak", "flag": c.group(2),
                    "names": labels, "sampled": sampled})
    return out


# an expression the check function can evaluate: only the transaction's fields and methods, constants
FREE = re.compile(r"\binstr\s*\.\s*(?:[\w.\s]|\[\"\w+\"\])*(?:\[[^\]]*\])*(?:\s*\([^()]*(?:\([^()]*\)[^()]*)*\))?|\$bits\s*\([^)]*\)|\d*'[sS]?[hHdDbB][0-9a-fA-F_?xXzZ]+|\b\d+\b")


def checkable(e):
    rest = FREE.sub(" ", e)
    return re.search(r"\binstr\b", e) is not None and not re.search(r"[A-Za-z_$]", rest)


def sv_check(res, hist, path):
    """ocv_cov_fields(instr): one hex value per checkable expression, in the order of the list it returns; an
    expression read only by covergroups isacov's sample() dispatches by name is evaluated only for those names
    ("-" for the others: a method may refuse other instructions, is_branch_taken)"""
    exprs, cgs_of = [], {}
    for cg, d in res.items():
        for label, it in d["items"].items():
            if it["kind"] != "coverpoint":
                continue
            for e in [it["value"]] + it["iffs"]:
                if checkable(e):
                    if e not in exprs:
                        exprs.append(e)
                    cgs_of.setdefault(e, set()).add(cg.split("@")[0])
    names_of = {}                       # covergroup type -> the names that sample it
    for h in hist or []:
        for lab, cg in h["sampled"].items():
            names_of.setdefault(cg, set()).add(lab)
    with open(path, "w") as f:
        f.write("// generated by tools/cov/cov_fields.py: the value of every coverpoint expression and condition that\n"
                "// reads only the monitor's transaction (tools/cov/cov_check.py)\n")
        f.write("function automatic string ocv_cov_fields(uvma_isacov_instr_c instr);\n    string s = \"\";\n")
        for e in exprs:
            if all(cg in names_of for cg in cgs_of[e]):
                names = sorted(set().union(*(names_of[cg] for cg in cgs_of[e])))
                f.write("    s = {s, instr.name inside {%s} ? $sformatf(\" %%0h\", %s) : \" -\"};\n"
                        % (", ".join(names), e))
            else:
                f.write("    s = {s, $sformatf(\" %%0h\", %s)};\n" % e)
        f.write("    return s;\nendfunction\n")
        # the configuration flags of isacov's sample() branches (which records move its history)
        flags = sorted({h["flag"] for h in (hist or [])})
        f.write("function automatic string ocv_cov_cfg(uvma_core_cntrl_cfg_c c);\n    return {\"cfg\"")
        for fl in flags:
            f.write(",\n        $sformatf(\" %s=%%0d\", c.%s)" % (fl, fl))
        f.write("};\nendfunction\n")
    return exprs


def main():
    argv = sys.argv[1:]
    out = sv = None
    if "--json" in argv:
        out = argv[argv.index("--json") + 1]
        del argv[argv.index("--json"):argv.index("--json") + 2]
    if "--sv" in argv:
        sv = argv[argv.index("--sv") + 1]
        del argv[argv.index("--sv"):argv.index("--sv") + 2]
    files = argv
    res = {}
    hist = None
    for f in files:
        t = strip_comments(open(f).read())
        hist = hist or history(t)
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
                                          "iffs": iffs, "value": norm(ehead), "bins": norm(block)}
                else:
                    cps = [c.strip() for c in re.split(r",", head) if c.strip()]
                    cg["items"][label] = {"kind": kind, "of": cps}
            # a name defined again (another package: cg_rtype of isacov and of CVA6's isa_covg): kept apart as
            # name@file - the harness's report names instances by type name only, so both are read for it
            key = m.group(1) if m.group(1) not in res else "%s@%s" % (m.group(1), f.split("/")[-1])
            res[key] = cg
    checked = sv_check(res, hist, sv) if sv else None
    if out:
        json.dump({"covergroups": res, "history": hist, "checked": checked}, open(out, "w"), indent=1)
    allp = {}
    for cg, d in res.items():
        for it in d["items"].values():
            for p in it.get("paths", []):
                allp.setdefault(p, set()).add(cg)
    for p in sorted(allp):
        print("%-45s %d covergroups" % (p, len(allp[p])))


if __name__ == "__main__":
    main()
