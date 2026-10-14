#!/usr/bin/env bash
# prog.sh <test> - a core-v-verif CV32E40P test program (tests/programs/custom/<test>) built as
# core-v-verif's Makefiles do (BSP crt0/handlers/syscalls/vectors, link.ld, objcopy -O verilog) into
# build/prog/<test>.hex, the +firmware of the UVM testbench. The BSP needs newlib (xPack GCC, tools/get_cores.sh).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
CVV=${CORE_V_VERIF:-$(cd "$HERE/../../ext/core-v-verif" && pwd)}
T=$1; SRC=$CVV/cv32e40p/tests/programs/custom/$T; BSP=$CVV/cv32e40p/bsp
OUT=$HERE/build/prog; mkdir -p "$OUT/bsp"
# toolchain: RISCV_PREFIX, or xPack's riscv-none-elf (newlib, rv32imc) unpacked in ext/ (tools/get_cores.sh)
X=$(ls -d "$HERE"/../../ext/xpack-riscv-none-elf-gcc-*/bin 2>/dev/null | tail -1)
P=${RISCV_PREFIX:-${X:+$X/riscv-none-elf-}}
[ -n "$P" ] || { echo "prog.sh: no toolchain (RISCV_PREFIX, or xPack riscv-none-elf-gcc in pvo_scr1/ext)"; exit 1; }
CF=(-Os -g -static -mabi=ilp32 -march=${CV_SW_MARCH:-rv32imc_zicsr_zifencei} -Wall -pedantic)
for f in crt0.S handlers.S syscalls.c vectors.S; do "${P}gcc" "${CF[@]}" -c "$BSP/$f" -o "$OUT/bsp/${f%.*}.o"; done
"${P}ar" rcs "$OUT/bsp/libcv-verif.a" "$OUT"/bsp/*.o
# the test's own flags (test.yaml default_cflags replace the defaults, as in core-v-verif's Makefiles);
# GCC >= 12 names Zicsr/Zifencei separately: added to a -march without them (the older toolchain's meaning)
mapfile -t TF < <(python3 - "$SRC/test.yaml" <<'PYEOF'
import re, shlex, sys
t = open(sys.argv[1]).read()
m = re.search(r"^default_cflags:\s*>?\s*\n((?:[ \t]+.*\n?)+)", t, re.M)
for w in shlex.split(" ".join(l.strip() for l in m.group(1).splitlines())) if m else []:
    if w.startswith("-march=") and "zicsr" not in w:
        w += "_zicsr_zifencei"
    print(w)
PYEOF
)
[ ${#TF[@]} -gt 0 ] && TCF=("${TF[@]}") || TCF=("${CF[@]}")
"${P}gcc" "${TCF[@]}" -I "$BSP" -o "$OUT/$T.elf" -nostartfiles "$SRC"/*.[cS] -T "$BSP/link.ld" -L "$OUT/bsp" -lcv-verif
"${P}objcopy" -O verilog "$OUT/$T.elf" "$OUT/$T.hex"
echo "prog: $OUT/$T.hex"
