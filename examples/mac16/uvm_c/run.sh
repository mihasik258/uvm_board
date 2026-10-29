#!/usr/bin/env bash
# run.sh - the mac16 UVM test written by the OCV contract (mac16_c_pkg.sv): the testbench, the RTL and the reference
# model in C (examples/mac16/mac16_model.c); uvm/ocv_contract.py derives the DUT's description and the record packing
# from the test's classes - no description file.
#
#   examples/mac16/uvm_c/run.sh pc        simulation: testbench + RTL in one Verilator model
#   examples/mac16/uvm_c/run.sh host      the board build, the FPGA image simulated inside the program (no board)
#   examples/mac16/uvm_c/run.sh aarch64   the board build for the VD100's A72
# then: $OUT/tb_top [+N=<operands>] [+PKT=<operands per transaction>] [+SEED=n] [+OCV_BASE=0x80000000 on the board]
# OCV_RTL_REPLACE=<mac16.sv>: that file in place of examples/mac16/mac16.sv (an injected bug)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
MODE=${1:-pc}
OUT=$(realpath -m "${OUT:-$OCV/build/uvm/mac16_c_$MODE}")
mkdir -p "$OUT"
TB=("$HERE/../uvm_v/mac16_if.sv" "$HERE/mac16_c_pkg.sv" "$HERE/tb_top.sv")
python3 "$OCV/uvm/ocv_contract.py" "${TB[@]}" --top tb_top -o "$OUT/contract" ${OCV_UVM_GEN:+--gen-flags "$OCV_UVM_GEN"}
RTL=$HERE/../mac16.sv
if [ -n "${OCV_RTL_REPLACE:-}" ]; then
    [ "$(basename "$OCV_RTL_REPLACE")" = mac16.sv ] || { echo "run.sh: OCV_RTL_REPLACE must be a mac16.sv"; exit 1; }
    RTL=$(realpath "$OCV_RTL_REPLACE")
fi
export RTL
export TB_C="$HERE/../mac16_model.c"
[ "$MODE" = pc ] || TB_C="$TB_C $OCV/sw/lib/ocv_runner.c $OCV/uvm/ocv_uvm_runner.c"
export TB_CFLAGS="-I$OUT/gen"
export OCV_HUB=plain
OUT=$OUT OCV_CONTRACT=$OUT/contract exec "$OCV/uvm/build_board.sh" "$MODE" "$OUT/contract/desc.json" tb_top "${TB[@]}"
