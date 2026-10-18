#!/usr/bin/env python3
"""qphase.py <bench_binary> <hot.txt> <phases.txt> - where the model's *executed* A72 instructions go:
the translated code by phase (rv32_jit.c's own phase intervals, OCV_JIT_PHASES) and the program (C) part.
Both files must come from one run (the mmap addresses differ between runs).

hotblocks reports one entry per TCG block (its address, its length and how many times it ran): a block may
span phase boundaries, so its length is split across the phases it covers."""
import bisect, collections, sys

binf, hotf, phf = sys.argv[1], sys.argv[2], sys.argv[3]
NM = ["enter", "arg", "op+mem", "out", "cov.classA", "cov.classB", "cov.bin", "cov.s0s1", "cov.mis", "rec", "exit"]
ranges = []                                 # (start, nw, [(off, tag)], offs)
for l in open(phf):
    p = l.split()
    if len(p) < 3: continue
    a, nw, niv = int(p[0], 16), int(p[1]), int(p[2])
    iv = [(int(p[3 + 2 * i]), int(p[4 + 2 * i])) for i in range(niv)]
    ranges.append((a, nw, iv, [o for o, _ in iv]))
ranges.sort(); starts = [r[0] for r in ranges]
cnt = collections.Counter()
for l in open(hotf):
    p = l.strip().split(", ")
    if len(p) != 4 or not p[0].startswith("0x"): continue
    a, i, e = int(p[0], 16), int(p[2]), int(p[3])
    if a < 0x10000000:                       # the program (C), not the generated code
        cnt["C"] += i * e
        continue
    j = bisect.bisect_right(starts, a) - 1
    if j < 0 or a - ranges[j][0] >= 4 * ranges[j][1]:
        cnt["other"] += i * e
        continue
    off, left = (a - ranges[j][0]) // 4, i
    iv, offs, nw = ranges[j][2], ranges[j][3], ranges[j][1]
    while left > 0:
        k = bisect.bisect_right(offs, off) - 1
        tag = NM[iv[k][1]] if k >= 0 else "enter"
        end = iv[k + 1][0] if k + 1 < len(iv) else nw
        n = min(left, end - off)
        cnt[tag] += n * e; off += n; left -= n
tot = sum(cnt[k] for k in NM) + cnt["other"]
allq = sum(cnt.values())
nri = allq  # (the caller knows the RISC-V instruction count; this is just the A72 side)
print(f"qphase: {allq} A72 instructions: translated code {tot} ({100.0*tot/allq:.1f}%),"
      f" program(C) {cnt['C']} ({100.0*cnt['C']/allq:.1f}%)")
print("  translated code, by phase:")
for k in NM + ["other"]:
    if cnt[k]: print(f"    {k:11s} {cnt[k]:12d}  {100.0*cnt[k]/max(tot,1):5.1f}% of translated, {100.0*cnt[k]/allq:5.1f}% of all")
