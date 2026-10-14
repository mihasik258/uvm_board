#!/usr/bin/env bash
# sim.sh - OCV core regression: register contract check + hub/endpoint testbench in Verilator
# over several record geometries.
# Usage: hw/scripts/sim.sh            (from anywhere)
set -euo pipefail
HW=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$HW/build/sim}
mkdir -p "$OUT"

# W0:D0:W1:D1 = monitor sink width:log2 depth, stimulus/response width:log2 depth.
# 96 exercises padded record slots, 32 one-word records with the minimum slot size,
# 128x8192 the SCR1 RVFI monitor shape.
GEOMS=${GEOMS:-"96:4:64:4 128:4:96:4 32:5:32:1 128:13:128:6"}

python3 "$HW/scripts/check_regs.py"   # HW/SW register contract must agree

fail=0
for g in $GEOMS; do
    IFS=: read -r w0 d0 w1 d1 <<< "$g"
    dir=$OUT/g_${w0}_${d0}_${w1}_${d1}
    rm -rf "$dir"
    verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-fatal --top-module tb_ocv_hub \
        -GW0="$w0" -GD0="$d0" -GW1="$w1" -GD1="$d1" --Mdir "$dir" -o sim \
        -F "$HW/rtl/ocv.f" "$HW/tb/tb_ocv_hub.sv" > "$dir.build.log" 2>&1 \
        || { echo "BUILD FAILED $g (see $dir.build.log)"; fail=1; continue; }
    (cd "$HW" && "$dir/sim") | tee "$dir.run.log" | grep -E 'TB_OCV|FAIL|INFO' || true
    grep -q 'TB_OCV_HUB: PASS' "$dir.run.log" || fail=1
done
# Reactive source (STREAM ring fed during the run, FREEZE_STARVED): W:D:FREEZE
STREAM_CFGS=${STREAM_CFGS:-"64:3:1 64:3:0 32:1:1 96:4:1 32:5:1"}
for g in $STREAM_CFGS; do
    IFS=: read -r w d f <<< "$g"
    dir=$OUT/s_${w}_${d}_${f}
    rm -rf "$dir"
    verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-fatal --top-module tb_ocv_stream \
        -GW="$w" -GD="$d" -GFREEZE="$f" --Mdir "$dir" -o sim \
        -F "$HW/rtl/ocv.f" "$HW/tb/tb_ocv_stream.sv" > "$dir.build.log" 2>&1 \
        || { echo "BUILD FAILED stream $g (see $dir.build.log)"; fail=1; continue; }
    (cd "$HW" && "$dir/sim") | tee "$dir.run.log" | grep -E 'TB_OCV|FAIL|INFO' || true
    grep -q 'TB_OCV_STREAM: PASS' "$dir.run.log" || fail=1
done
# squash sink (fused windows, CRC signatures): record widths x buffer depths
SQUASH_CFGS=${SQUASH_CFGS:-"96:3 32:4 160:2"}
for g in $SQUASH_CFGS; do
    IFS=: read -r w d <<< "$g"
    dir=$OUT/q_${w}_${d}
    rm -rf "$dir"
    verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-fatal --top-module tb_ocv_squash \
        -GW="$w" -GD="$d" --Mdir "$dir" -o sim \
        -F "$HW/rtl/ocv.f" "$HW/tb/tb_ocv_squash.sv" > "$dir.build.log" 2>&1 \
        || { echo "BUILD FAILED squash $g (see $dir.build.log)"; fail=1; continue; }
    (cd "$HW" && "$dir/sim") | tee "$dir.run.log" | grep -E 'TB_OCV|FAIL' || true
    grep -q 'TB_OCV_SQUASH: PASS' "$dir.run.log" || fail=1
done
# DMA sink (FIFO emptied into a ring in PS memory over AXI4): record width : log2 FIFO depth :
# AXI data width : log2 ring records - slots of one beat, several beats, wider than a 256-byte block
# boundary's share, a ring smaller than a block, 512-bit data
DMA_CFGS=${DMA_CFGS:-"160:3:128:4 32:2:64:4 96:3:128:5 160:3:256:4 160:6:128:8 128:4:512:6 640:4:128:3"}
for g in $DMA_CFGS; do
    IFS=: read -r w d dw rl <<< "$g"
    dir=$OUT/d_${w}_${d}_${dw}_${rl}
    rm -rf "$dir"
    verilator --binary --timing --timescale 1ns/1ps -Wall -Wno-fatal --unroll-count 256 --top-module tb_ocv_dma \
        -GW="$w" -GD="$d" -GDW="$dw" -GRL="$rl" --Mdir "$dir" -o sim \
        -F "$HW/rtl/ocv.f" "$HW/tb/tb_ocv_dma.sv" > "$dir.build.log" 2>&1 \
        || { echo "BUILD FAILED dma $g (see $dir.build.log)"; fail=1; continue; }
    (cd "$HW" && "$dir/sim") | tee "$dir.run.log" | grep -E 'TB_OCV|FAIL' || true
    grep -q 'TB_OCV_DMA: PASS' "$dir.run.log" || fail=1
done
[ $fail -eq 0 ] && echo "SIM: ALL PASS" || { echo "SIM: FAILURES"; exit 1; }
