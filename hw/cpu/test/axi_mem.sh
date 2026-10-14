#!/usr/bin/env bash
# axi_mem.sh - ocv_axi_mem's own test (tb_axi_mem.sv) for a data width, Verilator
#   hw/cpu/test/axi_mem.sh [DW=64] [transactions=3000] [seed=1]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
DW=${1:-64}; N=${2:-3000}; SEED=${3:-1}
OUT=$OCV/build/cpu/test_axi_mem_$DW
mkdir -p "$(dirname "$OUT")"
V=$OCV/build/verilator/install/bin/verilator
"$V" --binary --timing -j "${OCV_MAKE_J:-6}" -Wno-fatal -Wno-lint -Wno-style -GDW="$DW" --top-module tb_axi_mem \
    "$OCV/hw/cpu/ocv_axi_mem.sv" "$HERE/tb_axi_mem.sv" --Mdir "$OUT" > "$OUT.log" 2>&1 || { tail -20 "$OUT.log"; exit 1; }
"$OUT/Vtb_axi_mem" +n="$N" +seed="$SEED"
