# writes.S - stores of every width and lane, and CSR writes of every form (with and without a write:
# csrrs/csrrc with rs1 = x0 or uimm = 0 do not write), for the retire port's rvfi_mem_* / rvfi_csrw_*.
# CSR instructions have rd = x0: the reference ISS does not keep CSR values (only the writes are compared).
# Starts at the reset vector 0x200, ends by jumping to SIM_EXIT (0xF8).
    .section .text
    .globl _start
_start:
    li    s0, 0x1000            # data area
    li    t0, 0x89ABCDEF
    li    t1, 0x13579BDF
    li    s1, 40                # loop: values change every pass
1:
    sw    t0, 0(s0)
    sh    t0, 4(s0)
    sh    t1, 6(s0)
    sb    t0, 8(s0)
    sb    t1, 9(s0)
    sb    t0, 10(s0)
    sb    t1, 11(s0)
    lw    a0, 4(s0)
    lw    a1, 8(s0)
    csrw  mscratch, t0          # csrrw x0
    csrrw x0, mscratch, t1
    csrrs x0, mscratch, a0
    csrrc x0, mscratch, a1
    csrrs x0, mscratch, x0      # no write
    csrrc x0, mscratch, x0      # no write
    csrrwi x0, mscratch, 21
    csrrsi x0, mscratch, 10
    csrrci x0, mscratch, 3
    csrrsi x0, mscratch, 0      # no write
    csrrci x0, mscratch, 0      # no write
    add   t0, t0, a1
    xor   t1, t1, a0
    slli  t2, t0, 3
    or    t1, t1, t2
    addi  s0, s0, 12
    addi  s1, s1, -1
    bnez  s1, 1b
    li    t0, 0xF8
    jr    t0
