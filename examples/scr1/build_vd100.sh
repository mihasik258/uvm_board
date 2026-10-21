#!/usr/bin/env bash
# build_vd100.sh - SCR1 through OCV on the ALINX VD100: FPGA image + PS program + test programs.
#
#   examples/scr1/build_vd100.sh [<program.hex> ...]
#
# The same sources and defines as run_cosim.sh, built by the VD100 platform layer
# (platforms/vd100/build.sh; its environment applies: VIVADO_SETTINGS, REF_BOOTBIN, LINUX_DIR,
# OCV_CLK_MHZ, OCV_STOP, OUT). The programs (default: programs/*.hex and a random program, seed 1)
# are put next to the PS program; on the board:
#   /mnt/ocv/run.sh --model-opt program=hello.hex
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
SCR1=$(cd "${SCR1:-$OCV/ext/scr1}" && pwd)

S=${SCR1_SRC:-$SCR1/src}
export OUT=${OUT:-$HERE/build/vd100/scr1}
export OCV_CLK_MHZ=${OCV_CLK_MHZ:-80}
mkdir -p "$OUT"
{ sed -e '$a\' "$S/core.files"; sed -e '$a\' "$S/axi_top.files"
  printf '%s\n' core/cache/scr1_icache.sv core/cache/scr1_dcache.sv core/cache/scr1_cache_wrapper.sv; } \
  | sed "s#^#$S/#" > "$OUT/scr1_rtl.f"
mapfile -t RTL < "$OUT/scr1_rtl.f"

if [ $# -gt 0 ]; then
    PROGS=("$@")
else
    "$HERE/gen_random_prog.py" --seed 1 -o "$OUT/random_s1.hex" > /dev/null
    PROGS=("$HERE"/programs/*.hex "$OUT/random_s1.hex")
fi

export RTL_DEFINES="-DSCR1_CFG_RV32IMC_MAX -DSCR1_RVFI_EN -I$S/includes ${SCR1_DEFINES:-}"
export MODEL_SRCS="$OCV/models/cpu/iss/rv32_iss.c $OCV/models/cpu/cpu_model.c $OCV/models/cpu/ocv_cov_filter.c $HERE/scr1_cov.c $HERE/scr1_gen.c ${CPU_SRCS:-}"
export MODEL_CFLAGS="-I$OCV/models/cpu/iss -I$OCV/models/cpu ${CPU_CFLAGS:-}"
export PAYLOAD="${PROGS[*]}"
exec "$OCV/platforms/vd100/build.sh" "$HERE/scr1.json" "$HERE/scr1_model.c" \
    "${RTL[@]}" "$HERE/scr1_ocv_axi_mem.sv" "$HERE/scr1_ocv_dut.sv"
