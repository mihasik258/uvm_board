# mie_disable.S - directed test: is an interrupt taken after software disabled it in mie?
#
# RISC-V privileged spec (3.1.9): the interrupt-trap conditions "must also be evaluated immediately
# following ... an explicit write to a CSR on which these interrupt trap conditions expressly depend
# (including mip, mie, mstatus ...)". So after `csrs mie, MTIE` with the timer line high and mstatus.MIE
# set, the trap must come before the next instruction; after `csrw mie, x0` no timer interrupt may be taken.
#
# The timer line is held high for the whole run (--model-opt irq=0x80). Each of 16 rounds enables MTIE and
# disables it again after g = 0..15 nops; then 8 rounds enable and disable back to back. The handler (which must find MTIE set - it was enabled when the
# interrupt was taken) disables MTIE itself, so every round takes the interrupt at most once:
#   s0  interrupts taken                       (16 + 8 expected)
#   s1  interrupts taken while mie.MTIE = 0    (0 expected: taken after the disable - the violation)
#   s4  interrupts not taken right after `csrs mie` (mepc != the instruction after it; 0 expected)
# and the mepc of each interrupt goes to RESULTS (one word per interrupt). At the end s0, s1, s4 are also
# written to RESULTS + 0x100..0x108 and the test stops by writing s1 into the status register 0x20000004
# (the binding's end of program).
#
# Build: riscv-none-elf-gcc -march=rv32imc_zicsr -mabi=ilp32 -nostdlib -Wl,-Ttext=0 mie_disable.S
#        objcopy -O verilog (examples/cva6/repro/run.sh does it and runs the core on the PC and the model)

        .equ RESULTS, 0x8000
        .equ STATUS,  0x20000004

        .section .text
        .globl _start
        .org 0x80                      # the binding's boot address
_start:
        la      t0, handler
        csrw    mtvec, t0              # direct mode
        li      s0, 0
        li      s1, 0
        li      s4, 0
        li      s3, 0x80               # MTIE / MTIP
        li      s5, RESULTS
        csrw    mie, x0
        csrsi   mstatus, 8             # MIE = 1; nothing enabled in mie yet
        li      s2, 0                  # g: nops between the enable and the disable
round:
        la      t1, sled_end
        slli    t2, s2, 2
        sub     t1, t1, t2             # jump into the sled: g nops before the disable
        csrs    mie, s3                # MTIE on: the pending timer interrupt must be taken right here
after_enable:
        jr      t1
sled:
        .rept   16
        nop                            # (assembled as 4-byte nops: -march without C below)
        .endr
sled_end:
        csrw    mie, x0                # MTIE off: no timer interrupt from here on
        .rept   8
        nop
        .endr
        addi    s2, s2, 1
        li      t0, 16
        blt     s2, t0, round

        # phase 2: enable and disable back to back (0..7 nops before, to vary the fetch alignment). The trap
        # must come between the two writes; taken after `csrw mie, x0` is the violation (counted in s1).
        li      s2, 0
round2:
        la      t1, sled2_end
        slli    t2, s2, 2
        sub     t1, t1, t2
        jr      t1
sled2:
        .rept   8
        nop
        .endr
sled2_end:
        csrs    mie, s3                # MTIE on: the trap belongs right after this ...
        csrw    mie, x0                # ... and never after this
        .rept   8
        nop
        .endr
        addi    s2, s2, 1
        li      t0, 8
        blt     s2, t0, round2

        csrci   mstatus, 8
        li      t0, RESULTS + 0x100
        sw      s0, 0(t0)
        sw      s1, 4(t0)
        sw      s4, 8(t0)
        li      t0, STATUS
        sw      s1, 0(t0)              # the end
1:      j       1b

        .balign 4
handler:
        csrr    t3, mepc
        slli    t4, s0, 2
        add     t4, t4, s5
        sw      t3, 0(t4)              # where it was taken
        addi    s0, s0, 1
        la      t4, after_enable
        beq     t3, t4, 2f
        la      t4, sled2_end + 4
        beq     t3, t4, 2f
        addi    s4, s4, 1              # not right after the enable
2:      csrr    t3, mie
        and     t3, t3, s3
        bnez    t3, 3f
        addi    s1, s1, 1              # taken although MTIE is off
3:      csrc    mie, s3                # handled: the line stays high, so MTIE off before returning
        mret
