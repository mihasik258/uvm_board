#!/bin/sh
# run_ls.sh <program> [plusargs] - the core-v-verif CV32E40P firmware test on the board, lockstep form
# (variant 1: the testbench unchanged on the A72, the core in the FPGA; BOOT.BIN of cv32e40p_ls booted).
# Logs and the testbench's own files go to /tmp/cv32e40p (the FAT card is slow and small).
D=$(cd "$(dirname "$0")" && pwd)
P=$1; shift
mkdir -p /tmp/cv32e40p && cd /tmp/cv32e40p || exit 1
cp "$D/cv32e40p_tb" ./cv32e40p_tb && chmod +x ./cv32e40p_tb
START=$(date +%s)
./cv32e40p_tb +OCV_BASE=0x80000000 +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c +firmware="$D/$P.hex" "$@" > "run_$P.log" 2>&1
echo "== $P: $(( $(date +%s) - START )) s"
grep -E "exit status|SIMULATION|UVM_ERROR :|UVM_FATAL :|finish at|HELLO|Dhrystones per|Iterations/Sec|Correct" "run_$P.log" | head -8
