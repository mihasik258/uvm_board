# misaligned_load.S - directed test: does a load right after a misaligned-load exception read the right data?
#
# Seen in generated programs (cva6, seed 10): a misaligned `lhu` traps (CVA6 does not split misaligned
# accesses: cause 4); the handler's first load, `lhu x27, 0(mepc)` (it reads the trapping instruction to
# step over it), returned 0 instead of the instruction's low half - the handler then stepped 2 bytes, into
# the middle of the instruction, and the program went astray.
#
# Here: misaligned loads (lhu, lw, lh at odd/2-aligned offsets) at addresses in a zeroed area and in a
# patterned one, each right after an add / mul / div / rem / divu and 0..2 nops (seed 10 had a rem just
# before); the handler is the generator's: it reads mcause and mepc,
# loads the instruction's low half to get its length, steps over it, then (unlike the generator) also loads a
# known word from the pattern - both loads are compared with the reference model (stream regw), and the
# handler counts wrong values itself:
#   s0  traps taken, s1  instruction halfword read wrong (not 0x..83/0x..03: 32-bit loads end in 0b11),
#   s2  pattern word read wrong.
# End: the counters at 0x8100.. and a write of s1+s2 to the status register.

        .equ PAT,     0x7000           # 64 words: 0xA5A50000 + i
        .equ ZERO,    0x7800           # zeros
        .equ RESULTS, 0x8100
        .equ STATUS,  0x20000004

        .section .text
        .globl _start
        .org 0x80
_start:
        la      t0, handler
        csrw    mtvec, t0
        li      s0, 0
        li      s1, 0
        li      s2, 0
        li      t0, PAT
        li      t1, 0xA5A50000
        li      t2, 64
fill:   sw      t1, 0(t0)
        addi    t0, t0, 4
        addi    t1, t1, 1
        addi    t2, t2, -1
        bnez    t2, fill
        li      s8, PAT
        li      s9, ZERO
        fence

        li      s10, 1234567
        li      s11, 89
        .macro  probe base, op, off, gap, pre
        \pre    a5, s10, s11           # an instruction before (seed 10: a rem right before the load)
        .rept   \gap
        nop
        .endr
        \op     a0, \off(\base)
        .endm
        # every combination of preceding operation, area, load kind, misalignment and gap
        .irp    pre, add, mul, div, rem, divu
        .irp    base, s8, s9
        .irp    gap, 0, 1, 2
        probe   \base, lhu, 1, \gap, \pre
        probe   \base, lw, 2, \gap, \pre
        probe   \base, lw, 67, \gap, \pre
        probe   \base, lh, 3, \gap, \pre
        .endr
        .endr
        .endr

        li      t0, RESULTS
        sw      s0, 0(t0)
        sw      s1, 4(t0)
        sw      s2, 8(t0)
        add     t1, s1, s2
        li      t0, STATUS
        sw      t1, 0(t0)
1:      j       1b

        .balign 4
handler:
        addi    s0, s0, 1
        csrr    t3, mcause
        csrr    t4, mepc
        lhu     t5, 0(t4)              # the trapping instruction's low half (as the generator's handler)
        andi    t6, t5, 3
        li      a1, 3
        beq     t6, a1, 2f
        addi    s1, s1, 1              # read wrong: every instruction here is 32-bit
2:      addi    t4, t4, 4
        csrw    mepc, t4
        li      a2, PAT + 4 * 21
        lw      a3, 0(a2)              # and a known word
        li      a4, 0xA5A50015
        beq     a3, a4, 3f
        addi    s2, s2, 1
3:      mret
