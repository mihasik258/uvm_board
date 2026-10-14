#!/usr/bin/env python3
"""minimize_prog.py - shrink a failing generated program to the instructions the failure needs.

    tools/minimize_prog.py <tb_pc> <program.bin> <pattern> [--from 0x200] [--to 0x...] [-o out.bin]
                           [--model-opt k=v ...]

Delta debugging (ddmin) over the 32-bit words of the code range [from, to): a set of words is replaced by
`nop` (addi x0,x0,0) and the program is run again on the PC reference (tb_pc: the core in Verilator, every
record compared with the model); the change is kept when the run still prints a line matching <pattern>
(a regular expression, e.g. "MISMATCH channel 'regw' .*dut rd=0x1b data=0x0;"). The result is the smallest
program found (1-minimal over the words tried) and the list of the words that remain, disassembled when a
RISC-V objdump is around. Each run is limited by --timeout seconds (a run that hangs counts as "no").
"""
import argparse, os, re, shutil, struct, subprocess, sys, tempfile

NOP = 0x00000013


def run(tb, image, pattern, opts, timeout, tmp):
    path = os.path.join(tmp, "p.bin")
    with open(path, "wb") as f:
        f.write(image)
    cmd = [tb, "--model-opt", f"program={path}"]
    for o in opts:
        cmd += ["--model-opt", o]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                             env=dict(os.environ, OCV_PC_ERRORS="50")).stdout
    except subprocess.TimeoutExpired:
        return False
    return re.search(pattern, out) is not None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("tb"); ap.add_argument("program"); ap.add_argument("pattern")
    ap.add_argument("--from", dest="lo", type=lambda s: int(s, 0), default=0x200)
    ap.add_argument("--to", dest="hi", type=lambda s: int(s, 0), default=None)
    ap.add_argument("--model-opt", action="append", default=[])
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("-o", "--out", default=None)
    a = ap.parse_args()
    image = bytearray(open(a.program, "rb").read())
    hi = a.hi if a.hi is not None else len(image) & ~3
    tmp = tempfile.mkdtemp(prefix="minimize_")
    runs = 0

    def test(img):
        nonlocal runs
        runs += 1
        return run(a.tb, bytes(img), a.pattern, a.model_opt, a.timeout, tmp)

    if not test(image):
        sys.exit("minimize: the program does not fail with this pattern to begin with")
    # candidates: non-nop, non-zero words of the range
    cand = [o for o in range(a.lo, hi, 4)
            if struct.unpack_from("<I", image, o)[0] not in (0, NOP)]
    print(f"minimize: {len(cand)} candidate words in [{a.lo:#x}, {hi:#x})", flush=True)

    def with_nops(img, offs):
        t = bytearray(img)
        for o in offs:
            struct.pack_into("<I", t, o, NOP)
        return t

    n = 2
    while len(cand) >= 2:
        chunk = max(1, len(cand) // n)
        subsets = [cand[i:i + chunk] for i in range(0, len(cand), chunk)]
        reduced = False
        for s in subsets:                       # try removing one chunk (keep its complement)
            trial = with_nops(image, s)
            if test(trial):
                image = trial
                cand = [o for o in cand if o not in set(s)]
                n = max(n - 1, 2)
                reduced = True
                print(f"minimize: {len(cand)} words left ({runs} runs)", flush=True)
                break
        if not reduced:
            if n >= len(cand):
                break
            n = min(len(cand), n * 2)
    out = a.out or os.path.splitext(a.program)[0] + "_min.bin"
    open(out, "wb").write(image)
    print(f"minimize: {len(cand)} words remain after {runs} runs -> {out}")
    objdump = shutil.which("riscv64-unknown-elf-objdump") or shutil.which("riscv-none-elf-objdump")
    for o in cand:
        w = struct.unpack_from("<I", image, o)[0]
        line = f"  {o:#07x}: {w:08x}"
        if objdump:
            raw = os.path.join(tmp, "w.bin")
            open(raw, "wb").write(struct.pack("<I", w))
            d = subprocess.run([objdump, "-D", "-b", "binary", "-m", "riscv:rv32", "-M", "no-aliases", raw],
                               capture_output=True, text=True).stdout.splitlines()
            ins = [l.split("\t", 2)[-1] for l in d if re.match(r"\s+0:", l)]
            if ins:
                line += f"  {ins[0]}"
        print(line)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
