# rv64_basic.S - directed test of the 64-bit CVA6 against the reference model: what is new in RV64 - 64-bit register
# values and arithmetic, the W forms (addw, subw, sllw, sraw, addiw), ld / sd / lwu, 64-bit shifts, the RV64C
# forms (c.ld, c.sd, c.ldsp, c.sdsp, c.addiw, c.addw, c.subw, 6-bit shift amounts), CSR reads of 64-bit counters,
# a trap (ecall) and its handler; a loop so the core's pipeline overlaps them. Every record (issue, register writes,
# stores, CSR reads) is compared. Stops by writing 0 to the status register 0x20000004 (the binding's end).
#
# Build: riscv-none-elf-gcc -march=rv64imac_zicsr -mabi=lp64 -nostdlib -Wl,-Ttext=0 (examples/cva6_64/tests/build.sh)

        .equ STATUS,  0x20000004
        .equ DATA,    0x8000

        .section .text
        .globl _start
        .org 0x80                      # the binding's boot address
_start:
        la      t0, handler
        csrw    mtvec, t0
        li      sp, 0x3FF000           # the stack (the binding's 16 KiB below 4 MiB)
        li      s0, DATA
        li      s1, 200                # loop count
        li      a0, 0x123456789ABCDEF0
        li      a1, -3
loop:
        add     a2, a0, a1             # 64-bit
        sub     a3, a0, a2
        mul     a4, a0, a1
        mulh    a5, a0, a1
        divu    a6, a0, s1
        remu    a7, a0, s1
        addw    t1, a0, a1             # 32-bit, sign-extended
        subw    t2, a1, a0
        sllw    t3, a0, a1
        sraw    t4, a0, s1
        addiw   t5, a0, -7
        slli    t6, a0, 37             # 6-bit shift amounts
        srai    t6, t6, 45
        srli    a3, a0, 63
        sd      a0, 0(s0)
        sd      a2, 8(s0)
        sw      a1, 16(s0)
        ld      a4, 8(s0)
        lw      a5, 16(s0)
        lwu     a6, 16(s0)
        lhu     a7, 2(s0)
        c.ld    a4, 0(s0)              # RV64C
        c.sd    a5, 16(s0)
        c.addiw a5, -1
        c.addw  a4, a5
        c.subw  a4, a5
        c.slli  a4, 33
        c.srli  a4, 35
        c.srai  a5, 40
        addi    sp, sp, -16
        c.sdsp  a0, 8(sp)
        c.ldsp  a2, 8(sp)
        addi    sp, sp, 16
        csrr    t1, minstret           # 64-bit counters (RV64: no minstreth)
        csrr    t2, mcycle
        xor     a0, a0, a2

        slli    a0, a0, 1
        addi    a0, a0, 1
        addi    s1, s1, -1
        bnez    s1, loop
        ecall                          # a trap: the handler steps over it
        li      t0, STATUS
        sw      zero, 0(t0)            # the end
1:      j       1b

        .align 2
handler:
        csrr    t0, mepc
        addi    t0, t0, 4
        csrw    mepc, t0
        mret
