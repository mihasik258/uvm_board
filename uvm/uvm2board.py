#!/usr/bin/env python3
"""uvm2board.py - translate a UVM testbench written on OCV agents into its fast board form, without
editing the verifier's files: a generated *overlay* replaces, through the UVM factory, the parts that
would make the processor of the board handle every DUT event.

    uvm2board.py <descriptor.json> <tb.sv ...> -o <dir> [--config map.json]

What it looks for (and writes into <dir>/board_map.json, which can be edited and given back with
--config to override the guesses):

  scoreboard   a uvm_subscriber of the item of a squashed output channel whose write() steps a
               reference model through a DPI function, fills an expected item from its outputs and
               ends the test on a field value. It becomes engine A: the same DPI model as a C
               reference function (<dir>/board_ref.c, OCV_UVM_CHECKER) checked where the records leave
               the FPGA, squashed windows (+OCV_SQUASH=N); the subclass <name>_board only copies the
               engine's counters into the scoreboard's own fields (count, errors, done), so the test
               that waits on them is unchanged.
  sequences    a uvm_sequence of a source item whose body sends items in a loop (start_item ...
               finish_item): the subclass <name>_board sends the same records as one block item.

Output: board_overlay.sv (package <dut>_board_pkg and module <top>_board, the board build's top: the
testbench's top plus the overlay; it installs the overrides itself, +OCV_ASIS=1 leaves them out), board_ref.c,
board_map.json. (Not +uvm_set_type_override: UVM built without its DPI - Verilator - never sees the command line.) Anything not recognised is reported, and the
testbench then runs on the board unchanged (correct, but with UVM's cost per event).
"""
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tbparse  # noqa: E402


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def classes(text):
    """name -> (base, type parameter or None, body) for every class in the text"""
    out = {}
    for m in re.finditer(r"\bclass\s+(\w+)\s+extends\s+(\w+)\s*(#\s*\(([^;]*?)\))?\s*;(.*?)\bendclass\b", text, re.S):
        out[m.group(1)] = (m.group(2), (m.group(4) or "").strip() or None, m.group(5))
    return out


def func_body(body, name):
    m = re.search(r"\b(function|task)\b[^;]*?\b" + name + r"\s*\(([^)]*)\)\s*;(.*?)\bend(function|task)\b", body, re.S)
    return (m.group(2), m.group(3)) if m else (None, None)


def dpi_imports(text):
    """DPI function name -> list of (direction, name) of its arguments"""
    out = {}
    for m in re.finditer(r'import\s+"DPI-C"\s+(?:context\s+|pure\s+)?function\s+\w+\s+(\w+)\s*\(([^)]*)\)\s*;', text):
        args = []
        for a in [x.strip() for x in m.group(2).split(",") if x.strip()]:
            d = "output" if re.match(r"output\b", a) else "inout" if re.match(r"inout\b", a) else "input"
            args.append((d, re.findall(r"(\w+)\s*$", a)[0]))
        out[m.group(1)] = args
    return out


def localparams(text):
    out = {}
    for m in re.finditer(r"localparam\s+(?:int\s+unsigned\s+|int\s+|logic\s*\[[^\]]*\]\s*|bit\s*\[[^\]]*\]\s*)?(\w+)\s*=\s*([^;]+);", text):
        out[m.group(1)] = m.group(2).strip()
    return out


def sv_int(v, params):
    v = params.get(v, v).replace("_", "")
    m = re.fullmatch(r"(\d+)?'([hdb])([0-9a-fA-F]+)", v)
    if m:
        return int(m.group(3), {"h": 16, "d": 10, "b": 2}[m.group(2)])
    return int(v, 0)


class Refuse(Exception):
    """the scoreboard is not (safely) translatable: it stays as it is, checked in UVM per transaction"""


def balanced(t, i):
    """index after the parenthesis group starting at t[i] == '('"""
    depth = 0
    for j in range(i, len(t)):
        if t[j] == "(":
            depth += 1
        elif t[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
    raise Refuse("unbalanced parentheses")


def macros_out(t):
    """`uvm_error(...) etc. -> @M:name; (one token, so statements split cleanly)"""
    out, i = "", 0
    while True:
        m = re.compile(r"`(\w+)\s*").search(t, i)
        if not m:
            return out + t[i:]
        out += t[i:m.start()] + f"@M:{m.group(1)};"   # a macro call needs no ";" of its own
        i = m.end()
        if i < len(t) and t[i] == "(":
            i = balanced(t, i)


def statements(t):
    """flatten a procedural body into (conditions, statement); a condition is (positive?, text).
    Loops, case, fork and the like raise Refuse: their meaning is not one of the shapes below."""
    out, pos = [], [0]

    def ws():
        while pos[0] < len(t) and t[pos[0]].isspace():
            pos[0] += 1

    def word(w):
        ws()
        return re.match(r"\b" + w + r"\b", t[pos[0]:]) is not None

    def one(conds):
        ws()
        if pos[0] >= len(t):
            return
        if word("begin"):
            pos[0] += 5
            while not word("end"):
                if pos[0] >= len(t):
                    raise Refuse("begin without end")
                one(conds)
            pos[0] += 3
            return
        if word("if"):
            pos[0] += 2; ws()
            if t[pos[0]] != "(":
                raise Refuse("if without a condition")
            j = balanced(t, pos[0]); cond = t[pos[0] + 1:j - 1].strip(); pos[0] = j
            one(conds + [(True, cond)])
            if word("else"):
                pos[0] += 4
                one(conds + [(False, cond)])
            return
        if word("assert"):                      # assert (c) else s  ==  if (!(c)) s
            pos[0] += 6; ws()
            if t[pos[0]] != "(":
                raise Refuse("assert without a condition")
            j = balanced(t, pos[0]); cond = t[pos[0] + 1:j - 1].strip(); pos[0] = j
            ws()
            if t[pos[0]] == ";":
                raise Refuse(f"assert without an else branch ('{cond}'): its failure is not counted by the scoreboard")
            if not word("else"):
                raise Refuse(f"assert ({cond}) with a pass action")
            pos[0] += 4
            one(conds + [(False, cond)])
            return
        m = re.match(r"\s*\b(for|foreach|while|do|repeat|forever|case|casez|casex|fork|wait|return)\b", t[pos[0]:])
        if m:
            raise Refuse(f"'{m.group(1)}' in write()")
        j, depth = pos[0], 0
        while j < len(t):
            if t[j] == "(":
                depth += 1
            elif t[j] == ")":
                depth -= 1
            elif t[j] == ";" and depth == 0:
                break
            j += 1
        out.append((conds, t[pos[0]:j].strip()))
        pos[0] = j + 1

    while pos[0] < len(t):
        one([])
        ws()
    return [(c, st) for c, st in out if st]


SIDE = r"\(?\s*(\w+)\.(\w+)\s*(?:&\s*([\w']+)\s*)?\)?"


def tol_term(x, dut, exp, params):
    """'(t.f > m.f ? t.f - m.f : m.f - t.f) > K' (either side first, > or >=) -> (f, K): a mismatch when
    the absolute difference exceeds K. Other ways to write it ('t.f - m.f > K || ...') wrap around
    on unsigned fields, so they are not taken as a tolerance."""
    F = r"(\w+)\.(\w+)"
    m = re.fullmatch(r"\(?\s*\(?\s*" + F + r"\s*(>=?)\s*" + F + r"\s*\)?\s*\?\s*" + F + r"\s*-\s*" + F +
                     r"\s*:\s*" + F + r"\s*-\s*" + F + r"\s*\)?\s*(>=?)\s*([\w']+)", x)
    if not m:
        return None
    g = m.groups()
    a, b = (g[0], g[1]), (g[3], g[4])
    if {a[0], b[0]} != {dut, exp} or a[1] != b[1] or (g[5], g[6]) != a or (g[7], g[8]) != b \
            or (g[9], g[10]) != b or (g[11], g[12]) != a:
        raise Refuse(f"'{x}' is not the absolute difference of one field")
    k = sv_int(g[14], params) - (1 if g[13] == ">=" else 0)
    if k < 0:
        raise Refuse(f"'{x}': a negative tolerance")
    return a[1], k


def compare_terms(cond, dut, exp, params):
    """'t.a != m.a || (t.b & 'hFF) != (m.b & 'hFF)' -> {a: None, b: 0xFF}; None if it is not such a
    condition (Refuse if it compares DUT fields in another way: a tolerance, another field)"""
    terms = [x.strip() for x in re.split(r"\|\|", cond)]
    out = {}
    for x in terms:
        while x.startswith("(") and balanced(x, 0) == len(x):
            x = x[1:-1].strip()
        m = re.fullmatch(SIDE + r"\s*!==?\s*" + SIDE, x)
        if not m:
            tt = tol_term(x, dut, exp, params)
            if tt:
                out[tt[0]] = ("abs", tt[1])
                continue
            if re.search(r"\b" + dut + r"\.\w+", x) and re.search(r"\b" + exp + r"\.\w+", x):
                raise Refuse(f"comparison '{x}' is not exact equality of the same field")
            return None
        o1, f1, k1, o2, f2, k2 = m.groups()
        if {o1, o2} != {dut, exp}:
            return None
        if f1 != f2:
            raise Refuse(f"'{x}' compares different fields")
        if (k1 is None) != (k2 is None) or (k1 and sv_int(k1, params) != sv_int(k2, params)):
            raise Refuse(f"'{x}': the two sides are masked differently")
        out[f1] = sv_int(k1, params) if k1 else None
    return out


def eq_terms(cond, dut, exp, params):
    """'t.a == m.a && (t.b & 'hFF) == (m.b & 'hFF)' -> {a: None, b: 0xFF} (the condition that all match;
    a mismatch is its else branch); None if it is not such a condition"""
    out = {}
    for x in [y.strip() for y in re.split(r"&&", cond)]:
        while x.startswith("(") and balanced(x, 0) == len(x):
            x = x[1:-1].strip()
        m = re.fullmatch(SIDE + r"\s*===?\s*" + SIDE, x)
        if not m:
            if re.search(r"\b" + dut + r"\.\w+", x) and re.search(r"\b" + exp + r"\.\w+", x):
                raise Refuse(f"comparison '{x}' is not exact equality of the same field")
            return None
        o1, f1, k1, o2, f2, k2 = m.groups()
        if {o1, o2} != {dut, exp}:
            return None
        if f1 != f2:
            raise Refuse(f"'{x}' compares different fields")
        if (k1 is None) != (k2 is None) or (k1 and sv_int(k1, params) != sv_int(k2, params)):
            raise Refuse(f"'{x}': the two sides are masked differently")
        out[f1] = sv_int(k1, params) if k1 else None
    return out or None


def cmp_of(cond, dut, exp, params):
    """the fields an equality test compares: 'a != b || ...' (true on a mismatch) or 'a == b && ...'
    (true when all match) - by the operator it uses; None if it is neither"""
    if re.search(r"!==?", cond) or "?" in cond:
        return compare_terms(cond, dut, exp, params)
    if re.search(r"(?<![!<>=])===?(?!=)", cond):
        return eq_terms(cond, dut, exp, params)
    if re.search(r"\b" + dut + r"\.\w+", cond) and re.search(r"\b" + exp + r"\.\w+", cond):
        raise Refuse(f"comparison '{cond}' is not exact equality of the same field")
    return None


def item_fields(cls, item):
    """field name -> width of an item class (bit/logic [N-1:0] name;)"""
    body = cls.get(item, (None, None, ""))[2]
    out = {}
    for w, names in re.findall(r"^\s*(?:rand\s+)?(?:bit|logic)\s*(?:\[\s*(\d+)\s*:\s*0\s*\])?\s*([\w\s,]+);", body, re.M):
        for n in [x.strip() for x in names.split(",") if x.strip()]:
            out[n] = int(w) + 1 if w else 1
    return out


def item_compare(cls, item, params):
    """the fields an item's own compare() checks: do_compare written as 'a == o.a && ...', or
    `uvm_field_* macros (without UVM_NOCOMPARE). Refuse if it is neither."""
    base, _, body = cls.get(item, (None, None, None))
    if body is None:
        raise Refuse(f"compare() of {item}: its class is not in the testbench (generated from the descriptor) - compare the fields in the scoreboard")
    _, dc = func_body(body, "do_compare")
    if dc is not None:
        m = re.search(r"\$cast\s*\(\s*(\w+)\s*,\s*rhs\s*\)", dc)
        r = re.search(r"\breturn\b(.*?);", dc, re.S)
        if not m or not r:
            raise Refuse(f"{item}::do_compare is not 'return ... a == o.a && ...'")
        o, out = m.group(1), {}
        for x in [y.strip() for y in r.group(1).split("&&")]:
            while x.startswith("(") and balanced(x, 0) == len(x):
                x = x[1:-1].strip()
            if re.match(r"\$cast|super\.do_compare", x):
                continue
            mm = re.fullmatch(r"\(?\s*(?:this\.)?(\w+)\s*(?:&\s*([\w']+)\s*)?\)?\s*==\s*\(?\s*" + o + r"\.(\w+)\s*(?:&\s*([\w']+)\s*)?\)?", x)
            if not mm or mm.group(1) != mm.group(3) or (mm.group(2) or "") != (mm.group(4) or ""):
                raise Refuse(f"{item}::do_compare: '{x}' is not exact equality of a field")
            out[mm.group(1)] = sv_int(mm.group(2), params) if mm.group(2) else None
        return out
    flds = re.findall(r"`uvm_field_\w+\s*\(\s*(\w+)\s*,([^)]*)\)", body)
    if flds:
        return {f: None for f, fl in flds if "UVM_NOCOMPARE" not in fl}
    raise Refuse(f"{item}: no do_compare and no `uvm_field macros - compare() would compare nothing")


def find_scoreboard(cls, dpi, params, item2ch, squashed, gen_widths):
    """the scoreboard of a squashed channel, read statement by statement. Anything in write() that is
    not one of these is a reason to leave the scoreboard as it is (it would be lost on the board):
      declarations; one call of a DPI reference model; exp.f = <its output>; counters (x++);
      the comparison - exp/dut fields with != (optionally both masked), a string set to the field's
      name, or !dut.compare(exp); in the branch of a mismatch: an error counter and `uvm_error/info/
      warning or $display; the end: if (dut.f == <value>) <flag> = 1;"""
    found = None
    for name, (base, tparam, body) in cls.items():
        if base != "uvm_subscriber" or not tparam:
            continue
        ch = item2ch.get(tparam)
        if ch is None or ch not in squashed:
            continue
        args, wbody = func_body(body, "write")
        if wbody is None:
            continue
        try:
            found = analyse_write(name, ch, tparam, args, wbody, cls, dpi, params, gen_widths.get(ch, {}))
        except Refuse as e:
            return {"class": name, "channel": ch, "refused": str(e)}
        if found:
            return found
    return None


def cubes(values, width):
    """a set of values as few (mask, value) cubes as Quine-McCluskey merging gives - each cube holds
    only members of the set"""
    cur = {(((1 << width) - 1), v) for v in values}
    while True:
        new, used = set(), set()
        lst = sorted(cur)
        for i in range(len(lst)):
            for j in range(i + 1, len(lst)):
                (m1, v1), (m2, v2) = lst[i], lst[j]
                d = v1 ^ v2
                if m1 == m2 and d and not (d & (d - 1)) and d & m1:
                    new.add((m1 & ~d, v1 & ~d)); used |= {lst[i], lst[j]}
        if not new:
            break
        cur = (cur - used) | new
    out, left = [], set(values)                   # greedy cover by the cubes
    while left:
        best = max(cur, key=lambda c: len([v for v in left if v & c[0] == c[1]]))
        out.append(best)
        left = {v for v in left if v & best[0] != best[1]}
    return out


def rec_layout(ch):
    """field -> (lsb, width) in a channel's record, as ocv_gen.py lays it out (LSB first, in order);
    None if a field is a slice of a wider port (the generic accessors handle those)"""
    lay, lsb = {}, 0
    for f in ch["fields"]:
        if "slice" in f:
            return None
        lay[f["name"]] = (lsb, f["width"])
        lsb += f["width"]
    return lay


def c_get(lay, name, nwords, rec="dut"):
    """C expression: the field read out of a record with constant shifts and masks"""
    lsb, w = lay[name]
    k, o = lsb >> 5, lsb & 31
    mask = (1 << w) - 1
    if o + w <= 32:
        return f"(({rec}[{k}] >> {o}) & 0x{mask:X}u)"
    hi = f" | ((uint64_t){rec}[{k + 1}] << 32)" if k + 1 < nwords else ""
    return f"((((uint64_t){rec}[{k}]{hi}) >> {o}) & 0x{mask:X}ull)"


def c_pack(lay, vals, nwords, rec="exp"):
    """C statements: every word of a record built at once from the field values (vals: field -> C
    expression of at most 32 bits); bits no field covers are 0"""
    words = [[] for _ in range(nwords)]
    for name, e in vals.items():
        lsb, w = lay[name]
        k, o = lsb >> 5, lsb & 31
        m = f"((uint32_t)({e}) & 0x{((1 << w) - 1):X}u)"
        words[k].append(f"({m} << {o})" if o else m)
        if o + w > 32:
            words[k + 1].append(f"({m} >> {32 - o})")
    return [f"    {rec}[{k}] = {' | '.join(t) if t else '0'};" for k, t in enumerate(words)]


def obs_condition(cond, dut, widths, params):
    """a condition on the DUT's item alone, '||' of '&&' terms: t.f (1 bit), !t.f, t.f == V,
    (t.f & M) == V, t.f inside {V, ...}. -> (C expression over ocv_get_raw(dut, F(f)), list of
    patterns {field: (mask, value)} whose union contains every record the condition holds for)"""
    alts_c, pats = [], []
    for conj in [c.strip() for c in re.split(r"\|\|", cond)]:
        while conj.startswith("(") and balanced(conj, 0) == len(conj):
            conj = conj[1:-1].strip()
        cterms, choices = [], [{}]
        for x in [y.strip() for y in re.split(r"&&", conj)]:
            while x.startswith("(") and balanced(x, 0) == len(x):
                x = x[1:-1].strip()
            F = lambda f: f"ocv_get_raw(dut, F({f}))"
            m = re.fullmatch(r"(!\s*)?" + dut + r"\.(\w+)", x)
            if m:
                f = m.group(2)
                if widths.get(f) != 1:
                    raise Refuse(f"'{x}': only a 1-bit field can be a condition by itself")
                v = 0 if m.group(1) else 1
                cterms.append(f"{F(f)} == {v}u")
                choices = [dict(c, **{f: (1, v)}) for c in choices]
                continue
            m = re.fullmatch(r"\(?\s*" + dut + r"\.(\w+)\s*(?:&\s*([\w']+)\s*)?\)?\s*==\s*([\w']+)", x)
            if m:
                f, k, v = m.group(1), m.group(2), sv_int(m.group(3), params)
                mask = sv_int(k, params) if k else (1 << widths[f]) - 1
                cterms.append(f"({F(f)} & 0x{mask:X}ull) == 0x{v & mask:X}ull")
                choices = [dict(c, **{f: (mask, v & mask)}) for c in choices]
                continue
            m = re.fullmatch(dut + r"\.(\w+)\s+inside\s*\{([^}]*)\}", x)
            if m:
                f = m.group(1)
                vals = [sv_int(v.strip(), params) for v in m.group(2).split(",") if v.strip()]
                if any(re.search(r"\[|:", v) for v in m.group(2).split(",")):
                    raise Refuse(f"'{x}': ranges in inside are not supported")
                cterms.append("(" + " || ".join(f"{F(f)} == 0x{v:X}ull" for v in vals) + ")")
                choices = [dict(c, **{f: cb}) for c in choices for cb in cubes(vals, widths[f])]
                continue
            raise Refuse(f"'{x}': not a condition the FPGA can tell (t.f, !t.f, t.f == V, (t.f & M) == V, t.f inside {{...}})")
        alts_c.append("(" + " && ".join(cterms) + ")")
        pats += choices
    return " || ".join(alts_c), pats


def merge_patterns(pats, fields, n):
    """at most n patterns: merge the pair that loosens least (a pattern may match more records than the
    condition - that only closes windows early, the condition itself is checked in C)"""
    pats = [dict(p) for p in pats]
    while len(pats) > n:
        best = None
        for i in range(len(pats)):
            for j in range(i + 1, len(pats)):
                mg, cost = {}, 0
                for f in set(pats[i]) & set(pats[j]):
                    (m1, v1), (m2, v2) = pats[i][f], pats[j][f]
                    m = m1 & m2 & ~(v1 ^ v2)
                    mg[f] = (m, v1 & m)
                    cost += bin(m1 | m2).count("1") - bin(m).count("1")
                cost += sum(bin(pats[k][f][0]).count("1") for k in (i, j) for f in set(pats[k]) - set(mg))
                if best is None or cost < best[0]:
                    best = (cost, i, j, mg)
        _, i, j, mg = best
        pats = [p for k, p in enumerate(pats) if k not in (i, j)] + [mg]
    return pats


def analyse_write(name, ch, item, args, wbody, cls, dpi, params, gen_widths):
    dut = re.findall(r"(\w+)\s*$", args.strip())[0]
    st = statements(macros_out(wbody))
    allcalls = [(c, x) for c, x in st if re.fullmatch(r"(\w+)\s*\((.*)\)", x, re.S) and re.match(r"(\w+)", x).group(1) in dpi]
    # the model: a DPI function with outputs; observations: input-only DPI calls that hand the model a
    # value of the DUT's item (a timer read) under a condition on that item
    calls = [(c, x) for c, x in allcalls if any(d == "output" for d, _ in dpi[re.match(r"(\w+)", x).group(1)])]
    obs = [(c, x) for c, x in allcalls if (c, x) not in calls]
    if not calls:
        return None
    if len(calls) > 1:
        raise Refuse("more than one DPI call with outputs (models) in write()")
    if st.index(calls[0]) < max([st.index(o) for o in obs], default=-1):
        raise Refuse("a DPI call that gives the model a DUT value comes after the model's step")
    c0, call = calls[0]
    if c0:
        raise Refuse("the DPI reference model is called conditionally")
    fn, actual = re.fullmatch(r"(\w+)\s*\((.*)\)", call, re.S).groups()
    actual = [x.strip() for x in actual.split(",")] if actual.strip() else []
    if len(actual) != len(dpi[fn]):
        raise Refuse(f"{fn}: argument count")
    outs = {actual[i] for i in range(len(actual)) if dpi[fn][i][0] == "output"}
    if any(dpi[fn][i][0] != "output" for i in range(len(actual))):
        raise Refuse(f"{fn} takes inputs - the model would need the DUT's values")
    widths = item_fields(cls, item) or gen_widths     # an item generated by ocv_gen.py: its fields
    exp = None
    fields, cmp, strvars, count, errors, end = {}, {}, set(), None, None, None
    observe = None
    decl = re.compile(r"(?:(?:automatic|static)\s+)?(int\s+unsigned|int|integer|bit|logic|byte|shortint|longint|string|"
                      + re.escape(item) + r")(?:\s*\[[^\]]*\])?\s+(.+)$", re.S)

    def is_mismatch(conds):
        """the statement runs only on a mismatch"""
        for pos, cnd in conds:
            if not pos:                                   # the else of "all equal" / compare()
                if exp and ((re.search(r"(?<![!<>=])===?(?!=)", cnd) and not re.search(r"!==?", cnd) and
                             eq_terms(cnd, dut, exp, params)) or
                            re.fullmatch(dut + r"\.compare\s*\(\s*" + exp + r"\s*\)", cnd.strip())):
                    return True
                continue
            if (re.search(r"!==?", cnd) or "?" in cnd) and compare_terms(cnd, dut, exp or "\0", params):
                return True
            mm = re.fullmatch(r"(\w+)\s*!=\s*\"\"", cnd.strip())
            if mm and mm.group(1) in strvars:
                return True
            if re.fullmatch(r"!\s*" + dut + r"\.compare\s*\(\s*" + (exp or "\0") + r"\s*\)", cnd.strip()):
                return True
        return False

    for conds, x in st:
        for pos, cnd in conds:                               # compare conditions add to the comparison
            r = cmp_of(cnd, dut, exp, params) if exp else None
            if r:
                cmp.update(r)
            elif exp and (re.fullmatch(r"!\s*" + dut + r"\.compare\s*\(\s*" + exp + r"\s*\)", cnd.strip()) or
                          re.fullmatch(dut + r"\.compare\s*\(\s*" + exp + r"\s*\)", cnd.strip())):
                cmp.update(item_compare(cls, item, params))
        m = decl.fullmatch(x)
        if m and not conds:
            ty = m.group(1)
            for v in [y.strip() for y in m.group(2).split(",")]:
                mv = re.fullmatch(r"(\w+)(?:\s*=\s*(.+))?", v, re.S)
                if not mv:
                    raise Refuse(f"'{x}': declaration not understood")
                var, init = mv.group(1), (mv.group(2) or "").strip()
                if ty == item:
                    if not re.fullmatch(re.escape(item) + r"::type_id::create\s*\(.*\)", init, re.S):
                        raise Refuse(f"'{x}': the expected item must be created with ::type_id::create")
                    exp = var
                elif init and not re.fullmatch(r"[\w']+|\"\"", init):
                    raise Refuse(f"'{x}': initialised with an expression")
                if ty == "string":
                    strvars.add(var)
            continue
        if (conds, x) == calls[0]:
            continue
        if (conds, x) in obs:                    # the model takes a DUT value: an observation
            ofn, oargs = re.fullmatch(r"(\w+)\s*\((.*)\)", x, re.S).groups()
            oargs = [a_.strip() for a_ in oargs.split(",")] if oargs.strip() else []
            ofs = []
            for a_ in oargs:
                mo = re.fullmatch(dut + r"\.(\w+)", a_)
                if not mo:
                    raise Refuse(f"'{x}': passes '{a_}', not a field of the DUT's item")
                ofs.append(mo.group(1))
            if not conds or any(not p_ for p_, _ in conds) or len(conds) > 1:
                raise Refuse(f"'{x}': a DUT value handed to the model needs exactly one 'if' on the DUT's item")
            if observe is not None:
                raise Refuse("more than one DPI call handing DUT values to the model")
            cexpr, pats = obs_condition(conds[0][1], dut, widths, params)
            observe = {"dpi": ofn, "fields": ofs, "cond_c": cexpr,
                       "patterns": [{f: [hex(m_), hex(v_)] for f, (m_, v_) in p_.items()}
                                    for p_ in merge_patterns(pats, widths, 4)]}
            continue
        m = re.fullmatch(r"(\w+)\.(\w+)\s*=\s*(\w+)", x)
        if m and m.group(1) == exp and m.group(3) in outs and not conds:
            fields[m.group(2)] = actual.index(m.group(3))
            continue
        m = re.fullmatch(r"(\w+)\s*=\s*\"(\w+)\"", x)
        if m and m.group(1) in strvars and is_mismatch(conds):
            continue
        m = re.fullmatch(r"(\w+)\s*=\s*" + dut + r"\.mismatch\s*\(\s*(\w+)\s*\)", x)
        if m:
            raise Refuse(f"'{x}': mismatch() of a generated item applies the descriptor's rules - compare the fields in the scoreboard")
        m = re.fullmatch(r"(\w+)\s*(\+\+|\+=\s*1)", x)
        if m:
            if is_mismatch(conds):
                if errors is not None:
                    raise Refuse(f"the error counter is increased in more than one place: the board counts one "
                                 "error per wrong record, this scoreboard more")
                errors = m.group(1)
            elif not conds:
                count = m.group(1)
            else:
                raise Refuse(f"'{x}' counts under a condition that is not a mismatch")
            continue
        m = re.fullmatch(r"@M:(uvm_error|uvm_warning|uvm_info|uvm_fatal)|\$display\s*\(.*\)|\$error\s*\(.*\)", x, re.S)
        if m and is_mismatch(conds):
            continue
        m = re.fullmatch(r"(\w+)\s*=\s*1('b1)?", x)
        if m and len(conds) == 1 and conds[0][0]:
            e = re.fullmatch(r"\(?\s*" + dut + r"\.(\w+)\s*==\s*([\w']+)\s*\)?", conds[0][1].strip())
            if e:
                end = {"field": e.group(1), "value": sv_int(e.group(2), params), "flag": m.group(1)}
                continue
        raise Refuse(f"write() does '{x}'" + (f" (under 'if ({conds[-1][1]})')" if conds else "") +
                     " - not something the board form can keep")
    if not cmp:
        raise Refuse("no comparison of the DUT's item with the expected one found")
    if errors is None:
        raise Refuse("no error counter in the mismatch branch")
    for f in cmp:
        if f not in widths:
            raise Refuse(f"compared field '{f}' is not a field of {item}")
        if cmp[f] is None:
            cmp[f] = (1 << widths[f]) - 1
    return {"class": name, "channel": ch, "dpi": fn, "dpi_args": [d for d, _ in dpi[fn]],
            "fields": fields, "compare": {f: (f"abs:{v[1]}" if isinstance(v, tuple) else hex(v)) for f, v in cmp.items()},
            "end": end, "count": count, "errors": errors, "observe": observe}


def check_subscribers(cls, agents, sb, item=None):
    """every analysis connection of the squashed channel's monitor goes to the scoreboard, or (item
    given: the verifier's own agents) to subscribers that read only compared fields of the item -
    they then get the checked records (with squash the model's, equal to the DUT's in compared bits).
    Anything else would silently get no transactions or wrong ones on the board. Returns 1 if
    records must be delivered to such subscribers."""
    extra = 0
    for name, (base, tparam, body) in cls.items():
        types = dict((v, ty) for ty, v in re.findall(r"^\s*(\w+)\s+(\w+)\s*;", body, re.M))
        for src, dst in re.findall(r"\b(\w+)(?:\.\w+)*\.ap\.connect\s*\(\s*(\w+)\.\w+\s*\)", body):
            if types.get(src) not in agents or types.get(dst) == sb["class"]:
                continue
            sub = types.get(dst)
            if item is None or sub not in cls:
                raise Refuse(f"{name}: the '{sb['channel']}' monitor also feeds '{dst}' ({sub or '?'}) - "
                             "it would get no transactions on the board")
            fns = re.findall(r"\bfunction\s+(?:automatic\s+)?void\s+\w+\s*\(\s*(?:input\s+)?" + re.escape(item) +
                             r"\s+(\w+)\s*\)\s*;(.*?)\bendfunction\b", cls[sub][2], re.S)
            if not fns:
                raise Refuse(f"{sub}: no write method taking {item} found")
            for v, fb in fns:
                fb = re.sub(r"\"[^\"]*\"", '""', fb)
                used = set(re.findall(r"\b" + v + r"\s*\.\s*(\w+)\b(?!\s*\()", fb))
                if re.search(r"\b" + v + r"\b(?!\s*\.)", fb) or re.search(r"\b" + v + r"\s*\.\s*\w+\s*\(", fb):
                    raise Refuse(f"{sub}: uses the {item} as a whole (passes it on, calls its methods) - on the "
                                 "board it would get the model's record, which may differ in fields not compared")
                notcmp = sorted(used - set(sb["compare"]))
                if notcmp:
                    raise Refuse(f"{sub}: reads {', '.join(notcmp)}, not compared by {sb['class']} - on the board "
                                 "it would see the model's value there, not the DUT's")
            extra = 1
    return extra


def find_sequences(cls, item2ch, sources):
    out = []
    for name, (base, tparam, body) in cls.items():
        if base != "uvm_sequence" or not tparam:
            continue
        if item2ch.get(tparam) not in sources:
            continue
        _, b = func_body(body, "body")
        if b is None or "start_item" not in b or "finish_item" not in b:
            continue
        # the records must not depend on the DUT: no responses, no arbitration games. randomize() is
        # fine - the same constraints, drawn before the block is sent instead of item by item
        if re.search(r"\b(get_response|lock|grab|p_sequencer|m_sequencer)\b", b):
            continue
        out.append({"class": name, "item": tparam, "body": b})
    return out


def block_body(seq, own_items=False):
    """own_items: the verifier's item classes (not ocv_item): the block is <item>_ocv_blk, records
    packed by pack_<item>()"""
    b = seq["body"]
    var = re.search(r"start_item\s*\(\s*(\w+)\s*\)", b).group(1)
    add = f"ocv_blk.blk.push_back(pack_{seq['item']}({var}));" if own_items else f"ocv_blk.add_record({var});"
    b = re.sub(r"\bstart_item\s*\(\s*" + var + r"\s*\)\s*;", "", b)
    b = re.sub(r"\bfinish_item\s*\(\s*" + var + r"\s*\)\s*;", add, b)
    # the item made for every record only carries its fields into the block (add_record copies
    # them): made once, before the loop - the factory call per record was most of the time
    hoist = ""
    mk = re.search(r"\b" + re.escape(seq["item"]) + r"\s+" + var + r"\s*=\s*" + re.escape(seq["item"]) +
                   r"::type_id::create\s*\(([^;]*)\)\s*;", b)
    uses = re.findall(r"\b" + var + r"\b(?!\s*\.\s*(?:\w+\s*=|randomize\b))", re.sub(r"\"[^\"]*\"", "\"\"", b))
    if mk and len(uses) == 2:                 # the declaration and the copy into the block only
                                              # (field assignments and randomize() reuse it safely)
        hoist = f"        {seq['item']} {var} = {seq['item']}::type_id::create({mk.group(1)});\n"
        b = b[:mk.start()] + b[mk.end():]
    blk_t = f"{seq['item']}_ocv_blk" if own_items else seq["item"]
    return (f"        {blk_t} ocv_blk = {blk_t}::type_id::create(\"ocv_blk\");\n{hoist}"
            f"{b}\n        start_item(ocv_blk);\n        finish_item(ocv_blk);   // every record in one item\n")


def item_not_kept(text, item):
    """1 if no function taking an <item> argument (the subscribers' write methods) keeps the object:
    it only reads it as v.<member> - then a monitor can give every record in one reused object"""
    found = False
    for m in re.finditer(r"\bfunction\s+(?:automatic\s+)?void\s+\w+\s*\(\s*(?:input\s+)?" + re.escape(item) +
                         r"\s+(\w+)\s*\)\s*;(.*?)\bendfunction\b", text, re.S):
        v, body = m.group(1), re.sub(r"\"[^\"]*\"", "\"\"", m.group(2))
        found = True
        if re.search(r"\b" + v + r"\b(?!\s*\.)", body):          # passed on, stored, compared as a handle
            return False
    return found


def own_agents(d):
    """the board form of the verifier's own agents (no description file): per channel, functions that
    pack the item into the hub's record and back (fields in order from bit 0, as ocv_gen.py lays the
    record out); a source's driver sends records to the FPGA (a block item - <item>_ocv_blk, made by
    the block sequences - as all its records); an output's monitor writes what the FPGA gives"""
    L = []
    for k, c in enumerate(d["channels"]):
        item, cl = c["_item"], c["_class"]
        lsb, pk, up = 0, [], []
        for f in c["fields"]:
            src = f"t.{f['_of']}" + (f"[{f['_lo']} +: {f['width']}]" if f["_w"] > 64 else "")
            pk.append(f"        r[{lsb} +: {f['width']}] = {src};")
            up.append(f"        {src} = r[{lsb} +: {f['width']}];")
            lsb += f["width"]
        L += [f"    // channel {k} '{c['name']}': {item} <-> the hub's record",
              f"    function automatic ocv_rec_t pack_{item}({item} t);", "        ocv_rec_t r = '0;"] + pk + \
             ["        return r;", "    endfunction",
              f"    function automatic void unpack_{item}({item} t, ocv_rec_t r);"] + up + ["    endfunction", ""]
        if c["kind"] == "source":
            L += [f"    class {item}_ocv_blk extends {item};          // many records in one pass",
                  f"        `uvm_object_utils({item}_ocv_blk)",
                  f"        ocv_rec_t blk[$];",
                  f"        function new(string name = \"{item}_ocv_blk\"); super.new(name); endfunction",
                  f"    endclass", "",
                  f"    // {cl} on the board: the items go to the FPGA as records (the DUT is there)",
                  f"    class {cl}_board extends {cl};",
                  f"        `uvm_component_utils({cl}_board)",
                  f"        function new(string name, uvm_component parent); super.new(name, parent); endfunction",
                  f"        function void build_phase(uvm_phase phase); super.build_phase(phase); ocv_board::open(); endfunction",
                  f"        task send(ocv_rec_t r);",
                  f"            while (!ocv_dpi_send({k}, r)) ocv_board::wait_progress();   // ring full",
                  f"            ocv_sent++;"] + ([f"            ocv_in_{k}.push_back(r);           // for the input monitor"] if c["_inmon"] else []) + [
                  f"        endtask",
                  f"        task run_phase(uvm_phase phase);",
                  f"            {item} t;",
                  f"            {item}_ocv_blk b;",
                  f"            ocv_board::start();",
                  f"            forever begin",
                  f"                seq_item_port.get_next_item(t);",
                  f"                if ($cast(b, t)) foreach (b.blk[i]) send(b.blk[i]);",
                  f"                else send(pack_{item}(t));",
                  f"                seq_item_port.item_done();",
                  f"            end",
                  f"        endtask",
                  f"        function void report_phase(uvm_phase phase); super.report_phase(phase); ocv_board::close(); endfunction",
                  f"    endclass", ""]
            if c["_inmon"]:
                L.insert(L.index(f"    class {item}_ocv_blk extends {item};          // many records in one pass"),
                         f"    ocv_rec_t ocv_in_{k}[$];   // records of '{c['name']}' sent to the FPGA, for its input monitor")
            parts, lsb = {}, 0                       # item field -> its parts in the record
            for f in c["fields"]:
                parts.setdefault(f["_of"], []).append((lsb, f["width"], f["_lo"], f["_w"])); lsb += f["width"]
            for im in c["_inmon"]:
                L += [f"    // {im['class']} on the board: the records the driver sent (the DUT takes them in this order)",
                      f"    class {im['class']}_board extends {im['class']};",
                      f"        `uvm_component_utils({im['class']}_board)",
                      f"        function new(string name, uvm_component parent); super.new(name, parent); endfunction",
                      f"        task run_phase(uvm_phase phase);"] + ([f"            {im['item']} t;"] if im.get("_reuse") else []) + [
                      f"            forever begin",
                      f"                ocv_rec_t r;",
                      f"                wait (ocv_in_{k}.size() > 0);",
                      f"                r = ocv_in_{k}.pop_front();",
                      f"                begin"] + ([
                      f"                    if (t == null) t = {im['item']}::type_id::create(\"t\");   // one object: no subscriber keeps it"]
                      if im.get("_reuse") else [
                      f"                    {im['item']} t = {im['item']}::type_id::create(\"t\");"]) + \
                     [f"                    t.{mf}" + (f"[{lo} +: {w}]" if fw > 64 else "") + f" = r[{rl} +: {w}];"
                      for mf, df in im["fields"].items() for rl, w, lo, fw in parts[df]] + \
                     [f"                    {im['ap']}.write(t);",
                      f"                end",
                      f"            end",
                      f"        endtask",
                      f"    endclass", ""]
        else:
            L += [f"    // {cl} on the board: what the FPGA gives (records the engine does not check itself)",
                  f"    class {cl}_board extends {cl};",
                  f"        `uvm_component_utils({cl}_board)",
                  f"        function new(string name, uvm_component parent); super.new(name, parent); endfunction",
                  f"        function void build_phase(uvm_phase phase); super.build_phase(phase); ocv_board::open(); endfunction",
                  f"        task run_phase(uvm_phase phase);",
                  f"            ocv_rec_t r;"] + ([f"            {item} t;"] if c.get("_reuse") else []) + [
                  f"            ocv_board::start();",
                  f"            forever begin",
                  f"                if (!ocv_dpi_recv({k}, r)) begin ocv_board::wait_progress(); continue; end",
                  f"                begin"] + ([
                  f"                    if (t == null) t = {item}::type_id::create(\"t\");   // one object: no subscriber keeps it",
                  f"                    unpack_{item}(t, r);"] if c.get("_reuse") else [
                  f"                    {item} t = {item}::type_id::create(\"t\");",
                  f"                    unpack_{item}(t, r);"]) + [
                  f"                    {c['_ap']}.write(t);",
                  f"                end",
                  f"            end",
                  f"        endtask",
                  f"        function void report_phase(uvm_phase phase); super.report_phase(phase); ocv_board::close(); endfunction",
                  f"    endclass", ""]
    return L


def board_top(text, top, d, install):
    """the verifier's top without the DUT (it is in the FPGA) and without its clock generator (time
    follows the DUT's clocks on the board): everything else - the interface instance and its config DB
    entry, run_test - as written"""
    m = re.search(r"\bmodule\s+" + top + r"\b[^;]*;(.*?)\bendmodule\b", text, re.S)
    body = m.group(1)
    dm = re.search(r"\b" + d["module"] + r"\s+(?:#\s*\((?:[^()]|\([^)]*\))*\)\s*)?" + d["_dut_instance"] +
                   r"\s*\(.*?\)\s*;", body, re.S)
    if not dm:
        raise SystemExit(f"uvm2board: the DUT instance {d['_dut_instance']} not found in {top}")
    body = body[:dm.start()] + f"    // {d['module']} {d['_dut_instance']}: in the FPGA" + body[dm.end():]
    clk = re.escape(d["_clk_sig"])
    body, n = re.subn(r"\balways\s*#\s*[\w.]+\s*" + clk + r"\s*=\s*~\s*" + clk + r"\s*;",
                      "// clock: the DUT's, in the FPGA", body)
    if n != 1:
        raise SystemExit(f"uvm2board: the clock generator of {d['_clk_sig']} not found in {top}")
    imports = list(re.finditer(r"^\s*import\s+[\w:*,\s]+;\s*$", body, re.M))
    cut = imports[-1].end() if imports else 0                 # the overrides after the top's imports
    body = body[:cut] + "\n" + install + "\n" + body[cut:]
    return [f"// {top} for the board: the same, without the DUT and its clock", f"module {top}_board;",
            body.rstrip(), f"endmodule : {top}_board"]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+", help="[descriptor.json] tb.sv ... (without a descriptor: read from the testbench)")
    ap.add_argument("-o", "--out", required=True)
    ap.add_argument("--config")
    ap.add_argument("--top", default="tb_top", help="the testbench's top module (wrapped by <top>_board)")
    a = ap.parse_args()
    own = not a.files[0].endswith(".json")      # the verifier's own agents, no description file
    a.tb = a.files if own else a.files[1:]
    os.makedirs(a.out, exist_ok=True)
    if own:
        try:
            d = tbparse.parse([open(f).read() for f in a.tb], a.top)
        except tbparse.TbError as e:
            sys.exit(f"uvm2board: {e}")
        json.dump(tbparse.public(d), open(os.path.join(a.out, "desc.json"), "w"), indent=2)
        item2ch = {c["_item"]: c["name"] for c in d["channels"]}
    else:
        d = json.load(open(a.files[0]))
        item2ch = {f"{d['name']}_{c['name']}_item": c["name"] for c in d["channels"]}
    ch2item = {v: k for k, v in item2ch.items()}
    nm = d["name"]
    squashed = {c["name"] for c in d["channels"] if c.get("squash")}
    sources = {c["name"] for c in d["channels"] if c["kind"] == "source"}
    text = "\n".join(strip_comments(open(f).read()) for f in a.tb)
    pkgs = re.findall(r"\bpackage\s+(\w+)\s*;", text)
    cls, dpi, params = classes(text), dpi_imports(text), localparams(text)
    if a.config:
        mp = json.load(open(a.config))
    else:
        gen_widths = {c["name"]: {f["name"]: f["width"] for f in c["fields"]} for c in d["channels"]}
        mp = {"scoreboard": find_scoreboard(cls, dpi, params, item2ch, squashed, gen_widths),
              "sequences": [{"class": s["class"], "item": s["item"]} for s in find_sequences(cls, item2ch, sources)]}
    notes = []
    sb = mp.get("scoreboard")
    if sb and not sb.get("refused"):
        try:
            if own:
                ch = next(c for c in d["channels"] if c["name"] == sb["channel"])
                agents = {n for n, (b, _, body) in cls.items() if b == "uvm_agent" and re.search(r"\b" + ch["_class"] + r"\s+\w+\s*;", body)}
            else:
                agents = {f"{nm}_{sb['channel']}_agent"}
            if check_subscribers(cls, agents, sb, ch2item[sb["channel"]] if own else None):
                sb["deliver"] = True
        except Refuse as e:
            sb = mp["scoreboard"] = {"class": sb["class"], "channel": sb["channel"], "refused": str(e)}
    if sb and sb.get("refused"):
        notes.append(f"{sb['class']} stays as it is (checked in UVM per transaction): {sb['refused']}")
        sb = None
    elif not sb:
        notes.append("no scoreboard of a squashed channel with a DPI reference model: checked in UVM per event")
    elif not sb.get("end"):
        notes.append(f"{sb['class']}: no end condition found ('if (t.<field> == <value>) <flag> = 1;') - give one in the config")
    if not (sb and sb.get("end")) and os.path.exists(os.path.join(a.out, "board_ref.c")):
        os.remove(os.path.join(a.out, "board_ref.c"))        # from an earlier run
    tb_pkgs = [p for p in pkgs if not p.startswith(nm + "_ocv")]
    L = ["// GENERATED by uvm2board.py - the board overlay of the testbench; do not edit, regenerate.",
         "// The module <top>_board installs the factory overrides at time 0 (+OCV_ASIS=1: the testbench as is).",
         '`include "uvm_macros.svh"', f"package {nm}_board_pkg;", "    import uvm_pkg::*;", "    import ocv_uvm_pkg::*;"] + \
        ([] if own else [f"    import {nm}_ocv_uvm_pkg::*;"]) + [f"    import {p}::*;" for p in tb_pkgs] + [""]
    if own:
        for c in d["channels"]:
            if c["kind"] != "source" and c.get("_item"):
                c["_reuse"] = item_not_kept(text, c["_item"])
            for im in c.get("_inmon", []):
                im["_reuse"] = bool(im["item"]) and item_not_kept(text, im["item"])
        L += own_agents(d)
    from_rec = (lambda item, v, r: f"unpack_{item}({v}, {r});") if own else (lambda item, v, r: f"{v}.from_rec({r});")
    if sb and sb.get("end"):
        ch_idx = [c["name"] for c in d["channels"]].index(sb["channel"])
        cnt, err, flag = sb.get("count"), sb.get("errors"), sb["end"]["flag"]
        L += [f"    // {sb['class']} on the board: engine A checks channel '{sb['channel']}' (board_ref.c) where its",
              f"    // records leave the FPGA; this only keeps the scoreboard's own fields current.",
              f"    class {sb['class']}_board extends {sb['class']};",
              f"        `uvm_component_utils({sb['class']}_board)",
              f"        function new(string name, uvm_component parent); super.new(name, parent); endfunction",
              f"        function void build_phase(uvm_phase phase);",
              f"            super.build_phase(phase);",
              f"            if (!ocv_dpi_check_enable({ch_idx}))",
              f"                `uvm_fatal(\"OCV\", \"board_ref.c: no reference function for channel '{sb['channel']}'\")"] + \
             ([f"            void'(ocv_dpi_check_deliver({ch_idx}));   // other subscribers (coverage) get the checked records"]
              if sb.get("deliver") else []) + [
              f"        endfunction",
              f"        task run_phase(uvm_phase phase);",
              f"            ocv_rec_t dr, er; int f, dn; longint nc, ne, ix;",
              f"            ocv_board::start();",
              f"            forever begin",
              f"                ocv_board::wait_progress();",
              f"                while (ocv_dpi_check_mismatch({ch_idx}, dr, er, f, ix)) begin",
              f"                    {ch2item[sb['channel']]} t = {ch2item[sb['channel']]}::type_id::create(\"t\");",
              f"                    {ch2item[sb['channel']]} e = {ch2item[sb['channel']]}::type_id::create(\"e\");",
              f"                    {from_rec(ch2item[sb['channel']], 't', 'dr')} {from_rec(ch2item[sb['channel']], 'e', 'er')}",
              f"                    `uvm_error(\"SB\", $sformatf(\"MISMATCH (engine A) record #%0d field '%s': dut %s, model %s\",",
              f"                               ix, ocv_dpi_field_name({ch_idx}, f), t.convert2string(), e.convert2string()))",
              f"                end",
              f"                ocv_dpi_check_status({ch_idx}, nc, ne, dn);"]
        if cnt: L.append(f"                {cnt} = nc;")
        if err: L.append(f"                {err} = ne;")
        L += [f"                {flag} = dn;", f"            end", f"        endtask",
              f"        function void write({ch2item[sb['channel']]} t); endfunction   // records go to engine A",
              f"    endclass", ""]
        # C reference function from the DPI model
        fld = sb["fields"]
        nargs = len(sb["dpi_args"])
        chd = d["channels"][ch_idx]
        lay = rec_layout(chd)
        nwords = max(1, (sum(f_["width"] for f_ in chd["fields"]) + 31) // 32)
        fast = os.environ.get("OCV_U2B_GENERIC") != "1" and lay is not None and all(n_ in lay and lay[n_][1] <= 32 for n_ in fld) and \
            (not sb.get("observe") or all(n_ in lay for n_ in sb["observe"]["fields"] +
                                          re.findall(r"F\((\w+)\)", sb["observe"]["cond_c"])))
        if fast:
            # the record's layout is known here: words built and fields read with constant shifts
            # and masks, no field descriptors per record
            ob = sb.get("observe")
            C = ["/* GENERATED by uvm2board.py - the testbench's DPI reference model as an OCV reference function",
                 " * (the record layout is constant: words built and read with fixed shifts and masks) */",
                 "#include <stdint.h>", '#include "ocv_uvm_check.h"', "",
                 *([f"void {ob['dpi']}(" + ", ".join("int" for _ in ob["fields"]) + ");"] if ob else []),
                 f"void {sb['dpi']}(" + ", ".join("int *" if x != "input" else "int" for x in sb["dpi_args"]) + ");", "",
                 "static int board_ref(const uint32_t *dut, uint32_t *exp)", "{",
                 f"    int v[{max(1, nargs)}] = {{0}};", "    (void)dut;"]
            if ob:
                cexpr = re.sub(r"ocv_get_raw\(dut, F\((\w+)\)\)", lambda m_: c_get(lay, m_.group(1), nwords), ob["cond_c"])
                C += [f"    /* the DUT's value, as {sb['class']} hands it to the model (a window's last record: the FPGA",
                      f"     * closes a window on every record that may match, see board_brk) */",
                      f"    if (dut && ({cexpr}))",
                      f"        {ob['dpi']}(" + ", ".join(f"(int){c_get(lay, n_, nwords)}" for n_ in ob["fields"]) + ");"]
            C += [f"    {sb['dpi']}(" + ", ".join(f"&v[{i}]" if x != "input" else "0" for i, x in enumerate(sb["dpi_args"])) + ");"]
            C += c_pack(lay, {name: f"v[{ai}]" for name, ai in fld.items()}, nwords)
            end_i = next((ai for name, ai in fld.items() if name == sb["end"]["field"]), None)
        if not fast:
            C = ["/* GENERATED by uvm2board.py - the testbench's DPI reference model as an OCV reference function */",
                 "#include <stdint.h>", '#include "ocv_uvm_check.h"', "",
                 *([f"void {sb['observe']['dpi']}(" + ", ".join("int" for _ in sb["observe"]["fields"]) + ");"]
                   if sb.get("observe") else []),
                 f"void {sb['dpi']}(" + ", ".join("int *" if x != "input" else "int" for x in sb["dpi_args"]) + ");", "",
                 "static int board_ref(const uint32_t *dut, uint32_t *exp)", "{",
                 "    static const ocv_field_t *f[%d];" % max(1, len(fld)),
                 *(["    static const ocv_field_t *g[%d], *h[%d];" % (len(sb["observe"]["fields"]),
                    max(1, len(set(re.findall(r"F\((\w+)\)", sb["observe"]["cond_c"])))))] if sb.get("observe") else []),
                 f"    int v[{max(1, nargs)}] = {{0}};", "    (void)dut;", "    if (!f[0]) {"]
            for i, name in enumerate(fld):
                C.append(f'        f[{i}] = ocv_uvm_field("{sb["channel"]}", "{name}");')
            ob = sb.get("observe")
            if ob:
                for i, name in enumerate(ob["fields"]):
                    C.append(f'        g[{i}] = ocv_uvm_field("{sb["channel"]}", "{name}");')
                cn = sorted({m_ for m_ in re.findall(r"F\((\w+)\)", ob["cond_c"])})
                for i, name in enumerate(cn):
                    C.append(f'        h[{i}] = ocv_uvm_field("{sb["channel"]}", "{name}");')
            C += ["    }"]
            if ob:
                cexpr = re.sub(r"F\((\w+)\)", lambda m_: f"h[{cn.index(m_.group(1))}]", ob["cond_c"])
                C += [f"    /* the DUT's value, as {sb['class']} hands it to the model (a window's last record: the FPGA",
                      f"     * closes a window on every record that may match, see board_brk) */",
                      f"    if (dut && ({cexpr}))",
                      f"        {ob['dpi']}(" + ", ".join(f"(int)ocv_get_raw(dut, g[{i}])" for i in range(len(ob["fields"]))) + ");"]
            C += [f"    {sb['dpi']}(" + ", ".join(f"&v[{i}]" if x != "input" else "0" for i, x in enumerate(sb["dpi_args"])) + ");"]
            end_i = None
            for i, (name, ai) in enumerate(fld.items()):
                C.append(f"    ocv_set_raw(exp, f[{i}], (uint32_t)v[{ai}]);")
                if name == sb["end"]["field"]:
                    end_i = ai
        C += [f"    return (uint32_t)v[{end_i}] == 0x{sb['end']['value']:X}u;   /* the end of the test */" if end_i is not None
              else "    return 0;", "}", "",
              f"/* what {sb['class']} compares: field -> compared bits */",
              "static const ocv_uvm_cmp_t board_cmp[] = {"]
        C += [(f'    {{ "{f}", 0, 1, {v[4:]}ull }},   /* |dut - model| <= {v[4:]} */' if v.startswith("abs:")
               else f'    {{ "{f}", {v}ull, 0, 0 }},') for f, v in sb["compare"].items()]
        C += ["};", f'OCV_UVM_CHECKER_CMP("{sb["channel"]}", board_ref, board_cmp)', ""]
        if sb.get("observe"):
            C += ["/* records the model takes a value from: each closes its squash window (pattern, field, mask, value) */",
                  "static const ocv_uvm_brk_t board_brk[] = {"]
            for k_, p_ in enumerate(sb["observe"]["patterns"]):
                C += [f'    {{ {k_}, "{f_}", {mv[0]}ull, {mv[1]}ull }},' for f_, mv in p_.items()]
            C += ["};", f'OCV_UVM_CHECKER_BRK("{sb["channel"]}", board_brk)', ""]
        open(os.path.join(a.out, "board_ref.c"), "w").write("\n".join(C))
    for s in mp.get("sequences", []):
        seq = next((x for x in find_sequences(cls, item2ch, sources) if x["class"] == s["class"]), None)
        if not seq:
            notes.append(f"sequence {s['class']}: body not found"); continue
        L += [f"    // {seq['class']} on the board: the same records, sent as one block item",
              f"    class {seq['class']}_board extends {seq['class']};",
              f"        `uvm_object_utils({seq['class']}_board)",
              f"        function new(string name = \"{seq['class']}_board\"); super.new(name); endfunction",
              f"        task body();", block_body(seq, own), "        endtask", "    endclass", ""]
    # the overrides, installed by the board top at time 0, before run_test() reaches build_phase
    # (UVM without DPI cannot read +uvm_set_type_override from the command line)
    over = re.findall(r"^    class (\w+)_board extends", "\n".join(L), re.M)
    transport = ({c["_class"] for c in d["channels"]} | {m["class"] for c in d["channels"] for m in c.get("_inmon", [])}) if own else set()
    L += ["    // transport (the verifier's drivers and monitors: the DUT is in the FPGA) always; the",
          "    // speed-ups (engine A, blocks) unless +OCV_ASIS",
          "    function automatic void install(bit asis);", "        uvm_factory f = uvm_coreservice_t::get().get_factory();"]
    L += [f"        f.set_type_override_by_type({c}::get_type(), {c}_board::get_type());" for c in over if c in transport]
    L += [f"        if (!asis) f.set_type_override_by_type({c}::get_type(), {c}_board::get_type());" for c in over if c not in transport]
    L += ["    endfunction", f"endpackage : {nm}_board_pkg", ""]
    install = f"    initial {nm}_board_pkg::install($test$plusargs(\"OCV_ASIS\"));   // +OCV_ASIS: without the speed-ups"
    if own:
        L += board_top(text, a.top, d, install)
    else:
        L += [f"module {a.top}_board;", f"    {a.top} tb ();", install, f"endmodule : {a.top}_board"]
    open(os.path.join(a.out, "board_overlay.sv"), "w").write("\n".join(L) + "\n")
    json.dump(mp, open(os.path.join(a.out, "board_map.json"), "w"), indent=2)
    print(f"uvm2board: {nm}: scoreboard -> engine A: {sb['class'] if sb and sb.get('end') else 'no'}; "
          f"block sequences: {', '.join(s['class'] for s in mp.get('sequences', [])) or 'none'}")
    for n in notes:
        print(f"uvm2board: note: {n}")


if __name__ == "__main__":
    main()
