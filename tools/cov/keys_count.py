import sys
def vclass(v):
    if v == 0: return 0
    if v == 1: return 1
    if v == 0xffffffff: return 2
    if v == 0x80000000: return 3
    return 4 if v >> 31 else 5
def rel(a, b):
    sa = a - (1 << 32) if a >> 31 else a
    sb = b - (1 << 32) if b >> 31 else b
    return (a == b) | ((sa < sb) << 1) | ((a < b) << 2)
def noimm(w):
    """the word without its immediate (fields the covergroups read as values: name, registers, csr)"""
    if w & 3 != 3: return w            # compressed: as is
    op = w & 0x7f
    if op in (0x33, 0x3b): return w     # R-type: no immediate
    if op == 0x73: return w             # SYSTEM: csr address is the 'immediate'
    if op in (0x13, 0x1b) and (w >> 12) & 3 == 1: return w & 0xfe0fffff | 0  # shift-immediate keeps funct7 (shamt removed)
    if op in (0x37, 0x17, 0x6f): return w & 0xfff     # LUI/AUIPC/JAL: rd + opcode
    if op in (0x63, 0x23): return w & 0x01fff07f       # B/S: rs1 rs2 funct3 opcode
    return w & 0x000fffff                               # I-type: rs1 funct3 rd opcode
def immclass(w):
    if w & 3 != 3: return 0
    op = w & 0x7f
    if op in (0x13, 0x03, 0x67): imm = w >> 20; s = imm >> 11
    elif op == 0x23: imm = ((w >> 25) << 5) | ((w >> 7) & 31); s = imm >> 11
    elif op == 0x63: s = w >> 31; imm = (w >> 7) & 0x1ffffff
    elif op in (0x37, 0x17): imm = w >> 12; s = 2
    elif op == 0x6f: s = w >> 31; imm = w >> 12
    else: return 0
    return 0 if imm == 0 else (1 + (s == 1)) if s != 2 else 3
def prevpart(w):
    if w is None: return None
    if w & 3 != 3: return w & 0xffff
    op = w & 0x7f
    p = op | (w & 0xf80) | (w & 0x7000)              # opcode rd funct3
    if op in (0x33, 0x3b): p |= w & 0xfe000000        # funct7
    if op == 0x73: p |= w & 0xfff00000                 # csr
    if op == 0x13 and (w >> 12) & 3 == 1: p |= w & 0xfe000000
    return p
variants = {
  "A word+classes":            lambda c, p: (c[0], c[1:]),
  "B noimm+immclass+classes":  lambda c, p: (noimm(c[0][0]), immclass(c[0][0]), c[1:]),
  "C = A + prev word":         lambda c, p: (c[0], c[1:], p),
  "D = B + prev fields":       lambda c, p: (noimm(c[0][0]), immclass(c[0][0]), c[1:], prevpart(p)),
  "E = B + prev fields + shamt": lambda c, p: (noimm(c[0][0]), immclass(c[0][0]), c[1:], prevpart(p), c[-1]),
}
sets = {k: set() for k in variants}
marks = {100000, 300000, 1000000, 2000000, 3000000, 4000000}
prev = None
n = 0
for line in open(sys.argv[1]):
    f = [int(x, 16) for x in line.split()]
    insn, pc, trap, rs1, a, rs2, b, rd, d, ma = f[:10]
    c = ((insn, trap, ma & 3), vclass(a), vclass(b), vclass(d), rel(a, b), b & 31)
    for k, fn in variants.items():
        sets[k].add(fn(c, prev))
    prev = insn
    n += 1
    if n in marks:
        print(n, {k: len(v) for k, v in sets.items()})
print(n, {k: len(v) for k, v in sets.items()})
