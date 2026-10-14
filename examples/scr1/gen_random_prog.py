#!/usr/bin/env python3
"""gen_random_prog.py - random RV32IM test program for SCR1 through OCV.

    gen_random_prog.py [--seed S] [--ops N] [--loops K] -o program.hex

Builds a straight-line block of N random instructions and runs it K times in a loop, so the core
retires about N*K instructions (well beyond one monitor buffer: the run drains it). Registers
start from corner values (0, +-1, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, ...) mixed with random
ones, and keep evolving from iteration to iteration. The mix: register and immediate ALU ops,
shifts, compares, M-extension multiply/divide, forward conditional branches, aligned loads and
stores into a data area, LUI/AUIPC. No CSRs and no traps, so a plain ISA model covers it. The
program ends by jumping to SIM_EXIT (0xF8), the SCR1 test convention.

Memory (the scr1_ocv_dut 64 KiB RAM): code at the reset vector 0x200, data at 0x8000 (4 KiB).
Registers: x30 = loop counter, x31 = data base; the random ops use x1..x29.
Output: Verilog $readmemh byte image.
"""
import argparse, random, struct

RESET, DATA, DATA_BYTES, SIM_EXIT = 0x200, 0x8000, 0x1000, 0xF8
CODE_LIMIT = DATA                      # code must end below the data area

def R(f7, rs2, rs1, f3, rd, op=0x33): return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def I(imm, rs1, f3, rd, op=0x13):     return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def S(imm, rs2, rs1, f3, op=0x23):
    return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op
def B(imm, rs2, rs1, f3, op=0x63):
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
         | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op
def U(imm, rd, op): return (imm & 0xFFFFF000) | (rd << 7) | op
def J(imm, rd, op=0x6F):
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) \
         | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | op

def li(rd, v):
    """lui+addi pair that loads any 32-bit value."""
    v &= 0xFFFFFFFF
    lo = v & 0xFFF
    if lo >= 0x800: lo -= 0x1000
    hi = (v - lo) & 0xFFFFFFFF
    return [U(hi, rd, 0x37), I(lo, rd, 0, rd)]

CORNERS = [0, 1, 2, 0xFFFFFFFF, 0xFFFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001, 0x0000FFFF, 0xFFFF0000,
           0x00008000, 0xFFFF8000, 0x55555555, 0xAAAAAAAA, 31, 32]

RTYPE = [(0x00, 0), (0x20, 0), (0x00, 1), (0x00, 2), (0x00, 3), (0x00, 4), (0x00, 5), (0x20, 5),
         (0x00, 6), (0x00, 7)]                                  # add sub sll slt sltu xor srl sra or and
MTYPE = [(0x01, f3) for f3 in range(8)]                          # mul mulh mulhsu mulhu div divu rem remu
ITYPE = [0, 2, 3, 4, 6, 7]                                       # addi slti sltiu xori ori andi

def random_op(rnd, remaining):
    reg = lambda: rnd.randint(1, 29)
    src = lambda: rnd.choice([0] + list(range(1, 30)))
    k = rnd.random()
    if k < 0.25:
        f7, f3 = rnd.choice(RTYPE)
        return [R(f7, src(), src(), f3, reg())]
    if k < 0.40:
        f7, f3 = rnd.choice(MTYPE)
        return [R(f7, src(), src(), f3, reg())]
    if k < 0.55:
        imm = rnd.choice([0, 1, -1, 2047, -2048, rnd.randint(-2048, 2047)])
        return [I(imm, src(), rnd.choice(ITYPE), reg())]
    if k < 0.68:                                                 # slli / srli / srai, amounts 0..31
        f3, f7 = rnd.choice([(1, 0), (5, 0), (5, 0x20)])
        sh = rnd.choice([0, 1, 31, rnd.randint(0, 31)])
        return [I((f7 << 5) | sh, src(), f3, reg())]
    if k < 0.78 and remaining > 5:      # forward branch over 1..4 instructions, never past the block
        skip = rnd.randint(1, 4)
        return [B((skip + 1) * 4, src(), src(), rnd.choice([0, 1, 4, 5, 6, 7]))], skip
    if k < 0.86:                                                 # aligned load from the data area
        f3, size = rnd.choice([(0, 1), (4, 1), (1, 2), (5, 2), (2, 4)])
        off = rnd.randrange(0, DATA_BYTES, size)
        return [I(off, 31, f3, reg(), 0x03)]
    if k < 0.94:                                                 # aligned store into the data area
        f3, size = rnd.choice([(0, 1), (1, 2), (2, 4)])
        off = rnd.randrange(0, DATA_BYTES, size)
        return [S(off, src(), 31, f3)]
    if k < 0.97:
        return [U(rnd.getrandbits(32), reg(), 0x37)]            # lui
    return [U(rnd.getrandbits(32), reg(), 0x17)]                # auipc

def build(seed, ops, loops):
    rnd = random.Random(seed)
    code = []
    for r in range(1, 30):                                       # corner-heavy initial registers
        code += li(r, rnd.choice(CORNERS) if rnd.random() < 0.6 else rnd.getrandbits(32))
    code += li(31, DATA) + li(30, loops)
    loop_top = len(code)
    n = 0
    while n < ops:
        got = random_op(rnd, ops - n)
        insns, skip = (got if isinstance(got, tuple) else (got, 0))
        code += insns
        n += 1
        for _ in range(min(skip, ops - n)):                      # the instructions a branch may skip
            code += random_op(rnd, 0)                            # remaining=0: never a branch
            n += 1
    code.append(I(-1, 30, 0, 30))                                # addi x30, x30, -1
    code.append(B(8, 0, 30, 0))                                  # beq x30, x0, +8 (done)
    code.append(J((loop_top - len(code)) * 4, 0))                # jal x0, loop_top (block > 4 KiB)
    code += li(5, SIM_EXIT) + [I(0, 5, 0, 0, 0x67)]              # jalr x0, 0(x5) -> SIM_EXIT
    if RESET + 4 * len(code) > CODE_LIMIT:
        raise SystemExit(f"program too large ({len(code)} instructions); use fewer --ops")
    image = bytearray(DATA + DATA_BYTES)
    for i, w in enumerate(code):
        struct.pack_into("<I", image, RESET + 4 * i, w)
    for a in range(DATA, DATA + DATA_BYTES, 4):
        struct.pack_into("<I", image, a, rnd.choice(CORNERS) if rnd.random() < 0.3 else rnd.getrandbits(32))
    return image, len(code)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--ops", type=int, default=4000)
    ap.add_argument("--loops", type=int, default=10)
    ap.add_argument("-o", "--out", required=True)
    a = ap.parse_args()
    image, n = build(a.seed, a.ops, a.loops)
    with open(a.out, "w") as f:
        f.write("@00000000\n")
        for i in range(0, len(image), 16):
            f.write(" ".join(f"{b:02X}" for b in image[i:i + 16]) + "\n")
    print(f"gen_random_prog: seed {a.seed}: {n} instructions, block of {a.ops} ops x {a.loops} loops -> {a.out}")

if __name__ == "__main__":
    main()
