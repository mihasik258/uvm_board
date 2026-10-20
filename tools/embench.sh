#!/usr/bin/env bash
# embench.sh [scale] [benchmarks...] - Embench-IoT programs (ext/embench-iot: real, self-checking programs -
# crypto, compression, parsing, jpeg, sorting...) built for the RV32 cores with core-v-verif's BSP (crt0,
# syscalls, link.ld: the same as the core-v-verif programs), into build/embench/<name>_s<scale>.hex.
#
#   tools/embench.sh 1                  all of them, Embench's own length (~ a few million instructions each)
#   tools/embench.sh 50 nettle-aes      one, 50 times as long (GLOBAL_SCALE_FACTOR): one long test
#
# Each program checks its own result (verify_benchmark) and returns it from main: the BSP's exit writes it
# to the status device (0 = correct). The board support is Embench's generic one (nothing timed, nothing
# printed: tools/embench_board): core-v-verif's corev32 board exits before the check.
# EMBENCH_BOARD=embench_board_instret: the triggers read minstret/minstreth (as Embench's RISC-V boards read
# the cycle counter); the programs are named <name>_s<scale>_instret.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
EB=$OCV/ext/embench-iot; BSP=$OCV/ext/core-v-verif/cv32e40p/bsp
[ -d "$EB/src" ] || { echo "embench.sh: no ext/embench-iot (git clone --depth 1 https://github.com/embench/embench-iot)"; exit 1; }
SCALE=${1:-1}; shift || true
X=$(ls -d "$OCV"/ext/xpack-riscv-none-elf-gcc-*/bin 2>/dev/null | tail -1)
P=${RISCV_PREFIX:-${X:+$X/riscv-none-elf-}}
OUT=$OCV/build/embench; mkdir -p "$OUT/bsp"
CF=(-std=gnu17 -O2 -g -static -mabi=ilp32 -march=${CV_SW_MARCH:-rv32imc_zicsr_zifencei} -ffunction-sections -fdata-sections)
for f in crt0.S handlers.S syscalls.c vectors.S; do "${P}gcc" "${CF[@]}" -c "$BSP/$f" -o "$OUT/bsp/${f%.*}.o"; done
"${P}ar" rcs "$OUT/bsp/libcv-verif.a" "$OUT"/bsp/*.o
LIST=("$@"); [ ${#LIST[@]} -gt 0 ] || mapfile -t LIST < <(ls "$EB/src")
for b in "${LIST[@]}"; do
    n=${b}_s$SCALE${EMBENCH_BOARD:+_${EMBENCH_BOARD#embench_board_}}
    if "${P}gcc" "${CF[@]}" -DGLOBAL_SCALE_FACTOR="$SCALE" -DWARMUP_HEAT=0 -I "$EB/support" -I "$OCV/tools/${EMBENCH_BOARD:-embench_board}" -I "$BSP" \
        "$EB"/src/"$b"/*.c "$EB/support/main.c" "$EB/support/beebsc.c" "$EB/support/board.c" "$EB/support/chip.c" \
        -nostartfiles -T "$BSP/link.ld" -L "$OUT/bsp" -lcv-verif -lm -Wl,--gc-sections -o "$OUT/$n.elf" 2> "$OUT/$n.log"; then
        "${P}objcopy" -O verilog "$OUT/$n.elf" "$OUT/$n.hex"
        printf 'embench: %-16s %s (%s bytes of code+data)\n' "$b" "$OUT/$n.hex" "$("${P}size" "$OUT/$n.elf" | awk 'NR==2{print $1+$2}')"
    else
        echo "embench: $b failed to build: $OUT/$n.log"
    fi
done
