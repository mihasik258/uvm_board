# jitcheck.S - the corners of the "jit" model (rv32_jit.c), for t_fast against "iss": code rewritten
# ahead in the running block and in a block already translated (4-byte and RVC), loads and stores to
# device addresses in the middle of a block, the TCM region, accesses at and across a region's end, a block
# longer than the translation limit, division/multiplication corners, sign extension, x0 as a target,
# jalr to an odd address, every branch taken and not, and the no-op encodings (ld, branch funct3 2).
# Starts at the reset vector 0x200, ends by jumping to SIM_EXIT (0xF8).
    .section .text
    .globl _start
_start:
    li    s1, 25                # passes
    la    s2, patch1
    la    s3, patch2
    la    s6, patch3
    li    s4, 0x20000000        # device (no region)
    li    s5, 0x480000          # TCM
    li    s7, 0x1000            # data in RAM
    li    a0, 0
    li    a1, 0
    li    a2, 0
loop:
    # the running block: an instruction ahead of the store
    lw    t0, 0(s2)
    li    t1, 0x100000
    add   t0, t0, t1            # immediate + 1
    sw    t0, 0(s2)
    .option push
    .option norvc
patch1:
    addi  a0, a0, 1
    .option pop
    # device registers in the middle of a block
    lw    t2, 0(s4)
    add   a0, a0, t2
    sw    a0, 4(s4)
    sb    a0, 1(s4)
    lhu   t2, 6(s4)
    xor   a0, a0, t2
    # TCM
    sw    a0, 0(s5)
    lh    t3, 2(s5)
    lbu   t4, 1(s5)
    add   a0, a0, t3
    xor   a0, a0, t4
    sh    a0, 6(s5)
    lw    t4, 4(s5)
    add   a0, a0, t4
    # a block run before: its immediate grows
    lw    t0, 0(s3)
    add   t0, t0, t1
    sw    t0, 0(s3)
    jal   ra, sub
    # RVC rewritten: c.addi a2, 1 <-> c.addi a2, 2 (imm[4:0] at bits 6:2)
    lhu   t0, 0(s6)
    xori  t0, t0, 0xC           # 1 <-> 2
    sh    t0, 0(s6)
    jal   ra, sub3
    # at and across the end of RAM and TCM (across: no region, the environment answers)
    li    t0, 0xFFFC
    sw    a0, 0(t0)             # the last word: in the region
    lw    t5, 0(t0)
    add   a1, a1, t5
    lw    t5, 1(t0)             # one byte past the end
    add   a1, a1, t5
    lw    t5, 2(t0)
    add   a1, a1, t5
    lh    t5, 3(t0)
    add   a1, a1, t5
    lbu   t5, 3(t0)
    add   a1, a1, t5
    sh    a1, 3(t0)             # (a store past the end: the environment's)
    lhu   t5, 2(t0)
    add   a1, a1, t5
    li    t0, 0x48FFFD          # the end of TCM
    lw    t5, 0(t0)
    add   a1, a1, t5
    # arithmetic corners
    li    t0, 0x80000000
    li    t1, -1
    div   t2, t0, t1
    rem   t3, t0, t1
    div   t4, t0, zero
    divu  t5, t0, zero
    rem   t6, t0, zero
    remu  a3, a0, zero
    add   a1, a1, t2
    add   a1, a1, t3
    add   a1, a1, t4
    add   a1, a1, t5
    add   a1, a1, t6
    add   a1, a1, a3
    mulh  a4, t0, t1
    mulhsu a5, t1, t0
    mulhu a6, t0, t1
    mul   a7, a0, t1
    add   a1, a1, a4
    add   a1, a1, a5
    add   a1, a1, a6
    add   a1, a1, a7
    mulhsu a4, a0, a0
    mulh  a5, a0, zero
    divu  a6, a0, s1
    remu  a7, a0, s1
    div   a3, t1, s1
    rem   t2, t1, s1
    add   a1, a1, a4
    add   a1, a1, a5
    add   a1, a1, a6
    add   a1, a1, a7
    add   a1, a1, a3
    add   a1, a1, t2
    slti  a3, t1, -5
    sltiu a4, t1, -1
    sltiu a5, zero, -1
    slt   a6, t0, s1
    sltu  a7, t0, s1
    add   a1, a1, a3
    add   a1, a1, a4
    add   a1, a1, a5
    add   a1, a1, a6
    add   a1, a1, a7
    sra   a3, t0, t1
    srl   a4, t0, t1
    sll   a5, a0, t1
    srai  a6, t0, 31
    srli  a7, a0, 7
    add   a1, a1, a3
    add   a1, a1, a4
    add   a1, a1, a5
    add   a1, a1, a6
    add   a1, a1, a7
    # sign extension, x0 as a target, a store of x0
    sw    t0, 0(s7)
    sw    zero, 4(s7)
    lb    a3, 3(s7)
    lh    a4, 2(s7)
    lbu   a5, 3(s7)
    lhu   a6, 2(s7)
    lw    a7, 4(s7)
    add   a1, a1, a3
    add   a1, a1, a4
    add   a1, a1, a5
    add   a1, a1, a6
    add   a1, a1, a7
    add   zero, t0, t1
    addi  zero, a0, 5
    lw    zero, 0(s7)
    # no-op encodings: ld (rd gets 0 in the light model) and branch funct3 2 (falls through)
    .word 0x00003383            # ld t2, 0(zero)
    add   a1, a1, t2
    .word 0x00002063            # branch f3=2, falls through
    # jalr to an odd address
    la    t0, odd
    addi  t0, t0, 1
    jalr  ra, 0(t0)
    j     after_odd
odd:
    addi  a1, a1, 7
    ret
after_odd:
    # every branch, taken and not
    li    t0, -3
    li    t1, 5
    blt   t0, t1, 1f
    addi  a1, a1, 1
1:  bge   t0, t1, 1f
    addi  a1, a1, 2
1:  bltu  t0, t1, 1f
    addi  a1, a1, 4
1:  bgeu  t0, t1, 1f
    addi  a1, a1, 8
1:  beq   t0, t0, 1f
    addi  a1, a1, 16
1:  bne   t0, t0, 1f
    addi  a1, a1, 32
1:
    # a block longer than the translation limit
    .rept 80
    addi  a1, a1, 3
    .endr
    addi  s1, s1, -1
    bnez  s1, loop
    li    t0, 0xF8
    jr    t0

sub:
    .option push
    .option norvc
patch2:
    addi  a2, a2, 1
    .option pop
    ret

sub3:
patch3:
    c.addi a2, 1
    ret
