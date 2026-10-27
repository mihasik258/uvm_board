#!/bin/sh
# board_run.sh - the 64-bit CVA6's UVM test (examples/cva6_64/uvm_c) on the VD100: the testbench and Spike on the
# A72, the core in the FPGA (BOOT_cva6_64.BIN, or BOOT_cva6_64_fault.BIN: the carry into minstret[63:32] lost).
#
#   sh board_run.sh [program ...]     default: rv64_basic, minstret64, nettle-aes x1 (progs/)
#   sh board_run.sh long              nettle-aes x1100 with minstret reads: past 2^32 instructions
# Logs next to this script: cva6_64_<image>_<program>.log
D=$(cd "$(dirname "$0")" && pwd)
IMG=$(cat "$D/../booted" 2>/dev/null || echo unknown)
if [ "${1:-}" = long ]; then set -- nettle-aes_s1100_instret_rv64
elif [ $# -eq 0 ]; then set -- rv64_basic minstret64 nettle-aes_s1_rv64
fi
for p in "$@"; do
    L=$D/cva6_64_${IMG}_$p.log
    echo "board_run: cva6_64, image $IMG, $p -> $L"
    # (run where CVA6's RVFI tracer file, if anything writes it, goes nowhere: a FAT card has no links)
    mkdir -p /tmp/cva6_64 && ln -sf /dev/null /tmp/cva6_64/trace_hart_0.dasm
    ( cd /tmp/cva6_64 && time OCV_BASE=0x80000000 "$D/tb_top" +PROG="$D/progs/$p.hex" +UVM_NO_RELNOTES ) > "$L" 2>&1
    grep -E "^OCV: .*(PASS|FAIL)|MISMATCH|UVM_ERROR :|^real" "$L" | head -6
    sync
done
