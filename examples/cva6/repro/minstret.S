# minstret.S - directed test: is minstret(h) the number of instructions committed without an exception?
#
# The model checks every CSR read against its own count (csr_regfile.sv: an instruction is counted when it
# commits without an exception; a write replaces its half of the count, the writing instruction included).
# The test reads minstret/minstreth around ecalls, illegal instructions and misaligned loads (each traps:
# not counted), writes minstret close to 2^32 and reads both halves across the carry into minstreth.
# No interrupts. Stops by writing 0 to the status register 0x20000004 (the binding's end of program).
#
# Build/run: examples/cva6/repro/run.sh minstret 0

        .equ STATUS,  0x20000004

        .section .text
        .globl _start
        .org 0x80                      # the binding's boot address
_start:
        la      t0, handler
        csrw    mtvec, t0
        csrr    a0, minstret
        csrr    a1, minstreth
        nop
        csrr    a2, minstret           # a0 + 4 (csrr a1, nop, this one's predecessors)
        ecall                          # traps: not counted (nor the handler's mret? - it commits: counted)
        csrr    a3, minstret
        .word   0x00000000             # illegal: traps
        csrr    a4, minstret
        li      t1, 0x1001
        lw      t2, 0(t1)              # misaligned: traps
        csrr    a5, minstret

        # just below the carry: the halves read across it
        li      t0, -6                 # 0xFFFFFFFA
        csrw    minstret, t0
        csrr    a6, minstret           # 0xFFFFFFFA (the writing csrw replaced the count it was in)
        csrr    a7, minstreth          # 0
        nop
        nop
        nop
        csrr    s2, minstret           # 0xFFFFFFFF: the next count carries
        csrr    s3, minstreth          # 1 (this read is past the carry)
        li      t0, 0x7
        csrw    minstreth, t0
        csrr    s4, minstreth          # 7
        csrr    s5, minstret

        # a long loop: the count across many blocks (the translated code counts them, not the interpreter)
        li      t0, 100000
1:      addi    t0, t0, -1
        bnez    t0, 1b
        csrr    s6, minstret
        csrr    s7, minstreth

        li      t0, STATUS
        sw      x0, 0(t0)
2:      j       2b

        .balign 4
handler:                               # step over the trapping instruction (all of them are 4 bytes here)
        csrr    t3, mepc
        addi    t3, t3, 4
        csrw    mepc, t3
        mret
