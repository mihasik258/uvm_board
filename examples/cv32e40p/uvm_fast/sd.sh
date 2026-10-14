#!/usr/bin/env bash
# sd.sh - test 1 (core-v-verif's UVM testbench on the board, CV32E40P in the FPGA) into an SD-card folder
# made by hw/cpu/make_sd.sh (the cv32e40p image boots: `use.sh cv32e40p`):
#
#   examples/cv32e40p/uvm_fast/sd.sh <sd dir> [program.hex ...]     (default: hello-world dhrystone coremark)
#
# On the board (as root):  sh /run/media/FAT-mmcblk1p1/ocv/cpu/cv32e40p/uvm_fast/board_uvm.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SD=$(realpath "${1:?sd dir}"); shift
BIN=$HERE/../build/uvm_fast/board_aarch64/uvmt_cv32e40p_tb
[ -x "$BIN" ] || { echo "sd.sh: no $BIN - build it: uvm_fast/run.sh aarch64"; exit 1; }
D=$SD/ocv/cpu/cv32e40p/uvm_fast
mkdir -p "$D/progs"
cp "$BIN" "$D/"
if [ $# -eq 0 ]; then
    P=$HERE/../build/prog
    set -- "$P/hello-world.hex" "$P/dhrystone.hex" "$P/coremark.hex"
fi
cp "$@" "$D/progs/"
cat > "$D/board_uvm.sh" <<'RUN'
#!/bin/sh
# board_uvm.sh - core-v-verif's firmware test with each program in progs/: the testbench on this processor,
# CV32E40P in the FPGA (the cv32e40p image must be the one booted), every instruction checked. One line per
# program: the time, the OCV verdict, UVM's.
D=$(cd "$(dirname "$0")" && pwd)
cd "$D"
for p in progs/*.hex; do
    s=$(cut -d' ' -f1 /proc/uptime)          # (busybox: no date +%N, no bc)
    OCV_BASE=0x80000000 ./uvmt_cv32e40p_tb +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c +firmware="$D/$p" > "/tmp/uvm_$(basename "$p").log" 2>&1
    e=$(cut -d' ' -f1 /proc/uptime)
    printf '== %s: %s s\n' "$(basename "$p")" "$(awk "BEGIN { print $e - $s }")"
    grep -E "OCV: cv32e40p (PASS|FAIL)|MISMATCH|UVM_ERROR :|UVM_FATAL :|SIMULATION (PASSED|FAILED)" "/tmp/uvm_$(basename "$p").log" | cut -c1-220
done
echo "DONE board_uvm (logs: /tmp/uvm_*.log)"
RUN
echo "sd.sh: test 1 in $D ($(ls "$D/progs" | wc -l) programs)"
