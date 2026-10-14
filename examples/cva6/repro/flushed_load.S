# flushed_load.S - directed test: does a load in a trap handler receive the data of a younger load that the
# trap flushed?
#
# Found by tools/minimize_prog.py from a generated program (cva6, seed 10, program 3; 8 words remained):
#   uret                      (illegal: a first trap and mret)
#   lhu  ra, -1063(t6)        (misaligned: cause 4)
#   lb   s3, -943(t6)         (younger loads, flushed by the trap)
#   lb   t0, -1254(t6)
# and the handler's first load, `lhu x27, 0(mepc)`, returned 0 - what the flushed `lb`s would read there.
#
# Here the younger loads read a patterned area instead of zeros, so a wrong value says where it came from:
# each round optionally traps once on an illegal instruction first, then does a misaligned load followed by
# 0..2 younger loads from the pattern; the handler loads a known word ("probe", 0x12345678 at PROBE) and the
# trapping instruction's low half (as the generator's handler does):
#   s0 traps, s1 probe word wrong, s2 instruction half wrong, s3 the last wrong value seen (0xA5.. = pattern).
# End: write s1 + s2 to the status register.

        .equ PAT,     0x7000           # 0xA5A50000 + i, 64 words
        .equ PROBE,   0x7400
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
        li      s3, 0
        li      t0, PAT
        li      t1, 0xA5A50000
        li      t2, 64
fill:   sw      t1, 0(t0)
        addi    t0, t0, 4
        addi    t1, t1, 1
        addi    t2, t2, -1
        bnez    t2, fill
        li      t0, PROBE
        li      t1, 0x12345678
        sw      t1, 0(t0)
        li      t6, PAT + 0x200
        fence

        .macro  round illegal, young
        .if \illegal
        .word   0x00200073             # uret: illegal here (no U mode) - a trap first, as in the found program
        .endif
        lhu     ra, -0x1ff(t6)         # misaligned (odd address): cause 4
        .if \young > 0
        lb      s4, -0x1f0(t6)         # younger loads from the pattern, flushed by the trap
        .endif
        .if \young > 1
        lb      s5, -0x1e1(t6)
        .endif
        nop
        nop
        .endm
        .irp    ill, 0, 1
        .irp    yg, 0, 1, 2
        round   \ill, \yg
        round   \ill, \yg
        .endr
        .endr

        add     t1, s1, s2
        li      t0, STATUS
        sw      t1, 0(t0)
1:      j       1b

        .balign 4
handler:
        sw      s10, 0xa0(zero)        # the generator's handler starts with 4 stores (save area 0xA0)
        sw      s11, 0xa4(zero)
        sw      t3, 0xa8(zero)
        sw      t4, 0xac(zero)
        addi    s0, s0, 1
        csrr    t4, mepc
        li      a2, PROBE
        lw      a3, 0(a2)              # the probe word
        li      a4, 0x12345678
        beq     a3, a4, 2f
        addi    s1, s1, 1
        mv      s3, a3
2:      lhu     t5, 0(t4)              # the trapping instruction's low half: every one here ends in 0b11
        andi    t3, t5, 3
        li      a1, 3
        beq     t3, a1, 3f
        addi    s2, s2, 1
        mv      s3, t5
3:      addi    t4, t4, 4
        csrw    mepc, t4
        mret
