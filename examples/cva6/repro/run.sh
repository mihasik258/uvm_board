#!/usr/bin/env bash
# run.sh - build a directed CVA6 test (repro/<name>.S) and run it on the PC reference (the core in Verilator,
# every instruction compared with the model), with the interrupt lines held as the test needs.
#
#   examples/cva6/repro/run.sh [mie_disable|misaligned_load] [irq value, default 0x80 (timer line high)]
#
# Prints the model's verdict, the test's own counters (RESULTS + 0x100: taken / taken while disabled / late)
# and where each interrupt was taken. mie_disable: CVA6 issue openhwfoundation/cva6#3175 (writes to mie do
# not flush the pipeline: an interrupt comes late after an enable, or after a disable).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
T=${1:-mie_disable}; IRQ=${2:-0x80}
B=$OCV/build/repro/cva6; mkdir -p "$B"
X=$(ls -d "$OCV"/ext/xpack-riscv-none-elf-gcc-*/bin 2>/dev/null | tail -1)
P=${RISCV_PREFIX:-${X:+$X/riscv-none-elf-}}
[ -n "$P" ] || { echo "run.sh: no RISC-V toolchain (RISCV_PREFIX or ext/xpack-riscv-none-elf-gcc-*)"; exit 1; }
"${P}gcc" -march=rv32im_zicsr -mabi=ilp32 -nostdlib -nostartfiles -Wl,-Ttext=0 -Wl,--no-relax \
    "$HERE/$T.S" -o "$B/$T.elf"
"${P}objcopy" -O verilog "$B/$T.elf" "$B/$T.hex"
"${P}objdump" -d "$B/$T.elf" > "$B/$T.dis"
OUT=$B/core OCV_CPU_TRACE=$B/$T.trace "$OCV/hw/cpu/run.sh" "$OCV/examples/cva6/cva6.bind" pc "$B/$T.hex" -- \
    --model-opt "irq=$IRQ" > "$B/$T.log" 2>&1 || true
grep -E "tb_pc: (cva6|MISMATCH)|ERRATUM" "$B/$T.log" | head -8
echo "interrupts the model was told about (the core took them), and whether the model's state allowed each:"
grep -A1 "^interrupt" "$B/$T.trace" | grep -v "^--" | paste - - 2>/dev/null | sed 's/^/  /' | head -20 || true
# the test's own counters: the last values it stored (the model executed the same stores)
python3 - "$B/$T.trace" "$B/$T.dis" <<'EOF'
import re, sys
tr = open(sys.argv[1]).read().splitlines()
regs = {}
for l in tr:
    m = re.match(r"\d+ ([0-9a-f]{8}) ([0-9a-f]{8}) x(\d+)=([0-9a-f]{8})", l)
    if m: regs[int(m.group(3))] = int(m.group(4), 16)
print(f"test counters (model's registers at the end; their meaning: the test's header): "
      f"s0={regs.get(8, 0)} s1={regs.get(9, 0)} s2={regs.get(18, 0)} s3={regs.get(19, 0):#x} s4={regs.get(20, 0)}")
EOF
