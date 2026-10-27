#!/bin/sh
# board_run.sh - the OTBN+KMAC UVM test (examples/otbn/uvm_c) on the VD100: the testbench on the A72, the DUT in
# the FPGA (image examples/otbn/fpga.sh: BOOT_otbn.BIN, or BOOT_otbn_fault22.BIN with the injected bug).
#
#   sh board_run.sh [rounds] [seed]      default 10 rounds of keygen + sign, seed 1
# Logs next to this script: otbn_<image>_r<rounds>_s<seed>.log (the image from the hub's DUT_ID is the same for
# both: the name says which BOOT was copied last, from use.sh's note).
D=$(cd "$(dirname "$0")" && pwd)
R=${1:-10}
S=${2:-1}
IMG=$(cat "$D/../booted" 2>/dev/null || echo unknown)
L=$D/otbn_${IMG}_r${R}_s${S}.log
echo "board_run: OTBN, image $IMG, $R round(s), seed $S -> $L"
( time OCV_BASE=0x80000000 "$D/tb_top" +PROG="$D/run_mldsa87" +ROUNDS="$R" +SEED="$S" +UVM_NO_RELNOTES ) > "$L" 2>&1
grep -E "^OCV: .*(PASS|FAIL)|MISMATCH|UVM_ERROR :|^real" "$L" | head -8
sync
