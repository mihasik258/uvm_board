# devices.S - device windows of a core under ocv/gen/cpu_wrap.py (the windows of cv32e40p.bind: printer
# 0x10000000, vp 0x15000000, status 0x20000000): stores and loads of every width, a word read back,
# misaligned accesses across a word, all three windows, interleaved with RAM accesses. The answers are the
# processor's (here: what was written before, else 0), so the registers depend on them - every one is
# compared. Starts at 0x200, ends by jumping to 0xF8.
    .section .text
    .globl _start
_start:
    li    s0, 0x10000000        # printer
    li    s1, 0x15000000        # vp
    li    s2, 0x20000000        # status
    li    s3, 0x8000            # RAM
    li    s4, 20                # passes
    li    a0, 0x12345678
1:
    sb    a0, 0(s0)             # print a byte
    sw    a0, 4(s0)
    sw    a0, 0(s1)             # vp: write, read back
    lw    a1, 0(s1)
    add   a0, a0, a1
    sh    a0, 6(s1)
    lhu   a2, 6(s1)
    lb    a3, 7(s1)
    xor   a0, a0, a2
    add   a0, a0, a3
    sw    a0, 0(s3)             # RAM between device accesses
    lw    t0, 0(s3)
    sw    a0, 0x100(s1)
    lw    a4, 0x102(s1)         # misaligned across a word: two bus reads
    sw    t0, 0x104(s1)
    lh    a5, 0x103(s1)         # misaligned halfword across a word
    sw    a4, 0x10d(s1)         # misaligned store across a word: two bus writes
    add   a0, a0, a4
    add   a0, a0, a5
    lw    a6, 0x7f0(s1)         # never written: 0
    add   a0, a0, a6
    sw    a0, 0(s2)             # status
    lw    a7, 0(s2)
    add   a0, a0, a7
    slli  t1, a0, 3
    xor   a0, a0, t1
    addi  s1, s1, 8             # walk the window
    addi  s4, s4, -1
    bnez  s4, 1b
    li    t0, 0xF8
    jr    t0
