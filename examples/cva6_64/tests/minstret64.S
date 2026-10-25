# minstret64.S - directed test of the 64-bit CVA6: is minstret the number of instructions committed without an
# exception, all 64 bits of it? (the RV64 form of examples/cva6/repro/minstret.S: one 64-bit CSR, no minstreth)
#
# The model checks every CSR read against its own count. The test reads minstret around ecalls, illegal
# instructions and misaligned loads (each traps: not counted), writes it just below 2^32 and reads it across the
# carry into bit 32 - the injected bug of docs/COMPARISON.md (the carry lost) shows there - and just below 2^64.
# No interrupts. Stops by writing 0 to the status register 0x20000004 (the binding's end).
#
# Build: examples/cva6_64/tests/build.sh minstret64

        .equ STATUS,  0x20000004

        .section .text
        .globl _start
        .org 0x80                      # the binding's boot address
_start:
        la      t0, handler
        csrw    mtvec, t0
        csrr    a0, minstret
        nop
        csrr    a2, minstret
        ecall                          # traps: not counted
        csrr    a3, minstret
        .word   0x00000000             # illegal: traps
        csrr    a4, minstret
        li      t1, 0x1001
        lw      t2, 0(t1)              # misaligned: traps
        csrr    a5, minstret

        # just below the carry into bit 32
        li      t0, 0xFFFFFFFA
        csrw    minstret, t0
        csrr    a6, minstret           # 0xFFFFFFFA (the writing csrw replaced the count it was in)
        nop
        nop
        nop
        nop
        csrr    s2, minstret           # 0xFFFFFFFF
        csrr    s3, minstret           # 0x1_0000_0000: past the carry

        # just below the wrap of all 64 bits
        li      t0, -4
        csrw    minstret, t0
        csrr    s4, minstret           # 0xFFFF_FFFF_FFFF_FFFC
        nop
        nop
        csrr    s5, minstret           # 0xFFFF_FFFF_FFFF_FFFF
        csrr    s6, minstret           # 0: wrapped

        # a long loop: the count across many blocks
        li      t0, 0xFFFFFF00
        csrw    minstret, t0
        li      t0, 100000
1:      addi    t0, t0, -1
        bnez    t0, 1b
        csrr    s7, minstret

        li      t0, STATUS
        sw      x0, 0(t0)
2:      j       2b

        .balign 4
handler:                               # step over the trapping instruction (all of them are 4 bytes here)
        csrr    t3, mepc
        addi    t3, t3, 4
        csrw    mepc, t3
        mret
