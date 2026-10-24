#!/usr/bin/env bash
# build.sh - the 64-bit CVA6's directed tests: examples/cva6_64/tests/<name>.S -> build/cva6_64/tests/<name>.hex
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
X=$(ls -d "$OCV"/ext/xpack-riscv-none-elf-gcc-*/bin 2>/dev/null | tail -1)
P=${RISCV_PREFIX:-${X:+$X/riscv-none-elf-}}
[ -n "$P" ] || { echo "build.sh: no RISC-V toolchain (RISCV_PREFIX or ext/xpack-riscv-none-elf-gcc-*)"; exit 1; }
B=$OCV/build/cva6_64/tests; mkdir -p "$B"
for T in "${@:-rv64_basic}"; do
    "${P}gcc" -march=rv64imac_zicsr -mabi=lp64 -nostdlib -nostartfiles -Wl,-Ttext=0 -Wl,--no-relax \
        "$HERE/$T.S" -o "$B/$T.elf"
    "${P}objcopy" -O verilog "$B/$T.elf" "$B/$T.hex"
    echo "build.sh: $B/$T.hex"
done
