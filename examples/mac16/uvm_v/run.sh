#!/usr/bin/env bash
# run.sh - the mac16 UVM testbench written the usual way (mac16_if, mac16_pkg, tb_top): no OCV
# description, no generated agents.
#   examples/mac16/uvm_v/run.sh pc            plain simulation (Verilator): build/uvm/mac16_v_pc/tb_top +N=1000
#   examples/mac16/uvm_v/run.sh host|aarch64  the board form (uvm2board.py reads the testbench)
#   examples/mac16/uvm_v/run.sh vd100         the FPGA image for it
#   examples/mac16/uvm_v/run.sh sd            everything for the board in one folder (uvm/make_sd.sh)
#   examples/mac16/uvm_v/run.sh wave +OCV_WAVE=<channel>:<record> [plusargs]   a failure the board
#                                                 found, re-run in simulation: VCD around that record
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
MODE=$1; shift
export RTL="$HERE/../mac16.sv"
TB=("$HERE/mac16_if.sv" "${TB_PKG:-$HERE/mac16_pkg.sv}" "$HERE/tb_top.sv")
B=$HERE/../build
case $MODE in
    pc) OUT=${OUT:-$B/uvm/mac16_v_pc} exec "$OCV/uvm/build_board.sh" pc - tb_top "${TB[@]}" ;;
    wave)                               # the waveform of a failure the board found: the line it printed
        OUT=${OUT:-$B/uvm/mac16_v_wave}
        "$OCV/uvm/build_board.sh" wave - tb_top "${TB[@]}"
        cd "$OUT" && exec ./tb_top_wave +UVM_TESTNAME=rand_test "$@" ;;
    sd) OUT=${OUT:-$B/sd/mac16_v} exec "$OCV/uvm/make_sd.sh" mac16 tb_top "${TB[@]}" ;;
    host|aarch64|vd100)
        OVL=${OVL:-$B/uvm/mac16_v_overlay}
        python3 "$OCV/uvm/uvm2board.py" "${TB[@]}" -o "$OVL" --top tb_top
        [ -f "$OVL/board_ref.c" ] && export TB_C="${TB_C:-} $OVL/board_ref.c"
        if [ "$MODE" = vd100 ]; then
            OCV_GEN_FLAGS=--uvm OUT=${OUT:-$B/vd100/mac16_v} exec "$OCV/platforms/vd100/build.sh" "$OVL/desc.json" - "$RTL"
        fi
        OUT=${OUT:-$B/uvm/mac16_v_$MODE} exec "$OCV/uvm/build_board.sh" "$MODE" "$OVL/desc.json" tb_top_board \
            "${TB[@]}" "$OVL/board_overlay.sv" ;;
    *)  sed -n '2,10p' "$0"; exit 1 ;;
esac
