#!/usr/bin/env python3
"""flist.py - every source file a Verilator/simulator file list (-f) compiles: the listed files, the
nested lists (-f), with ${VAR}/$VAR from the environment, and the files they `include (found in the
+incdir+ directories). For tools that read a testbench's text (lockstep.py, uvm2board.py).

    flist.py [-f list.f ...] [file.sv ...] [+incdir+dir ...]    -> one path per line
    flist.py --modules-not-packages -f list.f                   -> the list without module/interface
                                                                   files, packages and include dirs kept
"""
import os, re, sys


def expand(args):
    files, incs = [], []

    def env(s):
        return re.sub(r"\$\{(\w+)\}|\$(\w+)", lambda m: os.environ.get(m.group(1) or m.group(2), ""), s)

    def take(tokens, base):
        it = iter(tokens)
        for t in it:
            if t == "-f":
                lst = env(next(it))
                take(read(lst), os.path.dirname(lst))
            elif t.startswith("+incdir+"):
                incs.extend(env(x) for x in t[len("+incdir+"):].split("+") if x)
            elif t.startswith(("+", "-")):
                continue
            else:
                p = env(t)
                files.append(p if os.path.isabs(p) else os.path.join(base, p))

    def read(lst):
        out = []
        for line in open(lst):
            line = re.sub(r"//.*", "", line).strip()
            out.extend(line.split())
        return out

    take(args, os.getcwd())
    seen, order = set(), []

    def visit(p):
        p = os.path.normpath(p)
        if p in seen or not os.path.exists(p):
            return
        seen.add(p)
        order.append(p)
        for inc in re.findall(r'`include\s+"([^"]+)"', open(p, errors="replace").read()):
            for d in [os.path.dirname(p)] + incs:
                q = os.path.join(d, inc)
                if os.path.exists(q):
                    visit(q)
                    break
    for f in files:
        visit(f)
    return order, files, incs


def main():
    a = sys.argv[1:]
    if a and a[0] == "--modules-not-packages":
        _, files, incs = expand(a[1:])
        for d in incs:
            print(f"+incdir+{d}")
        for f in files:
            t = open(f, errors="replace").read()
            if re.search(r"^\s*package\b", t, re.M) and not re.search(r"^\s*(module|interface)\b", t, re.M):
                print(f)
        return
    for p in expand(a)[0]:
        print(p)


if __name__ == "__main__":
    main()
