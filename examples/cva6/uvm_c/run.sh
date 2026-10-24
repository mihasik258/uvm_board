#!/usr/bin/env bash
# run.sh - the CVA6 UVM test written by the OCV contract (cva6_c_pkg.sv): the testbench, the core's RTL and its
# reference model; the DUT's description is its wrapper's (gen/cpu_wrap.py from examples/cva6/cva6.bind), the record
# packing is derived from the test's classes (uvm/ocv_contract.py) - nothing written for the board.
#
#   examples/cva6/uvm_c/run.sh pc        simulation: testbench + CVA6 RTL in one Verilator model
#   examples/cva6/uvm_c/run.sh host      the board build, the FPGA image simulated inside the program (no board)
#   examples/cva6/uvm_c/run.sh aarch64   the board build for the VD100's A72 (the image of hw/cpu/run.sh ... vd100)
# then: $OUT/tb_top +PROG=<program.hex> [+OCV_MODEL="key=value ..."] [+OCV_BASE=0x80000000 on the board]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
MODE=${1:-pc}
OUT=$(realpath -m "${OUT:-$OCV/build/uvm/cva6_c_$MODE}")
mkdir -p "$OUT"
export CVA6=${CVA6:-$OCV/ext/cva6}
python3 "$OCV/gen/cpu_wrap.py" "$OCV/examples/cva6/cva6.bind" -o "$OUT/wrap" > "$OUT/wrap.log" || { cat "$OUT/wrap.log"; exit 1; }
# shellcheck disable=SC1091
source "$OUT/wrap/wrap.env"
TB=("$HERE/cva6_if.sv" "$HERE/cva6_c_pkg.sv" "$HERE/tb_top.sv")
GEN=${OCV_UVM_GEN:---dma 128}            # (as the board image: hw/cpu/run.sh ... vd100 with OCV_GEN_FLAGS="--dma 128")
python3 "$OCV/uvm/ocv_contract.py" "${TB[@]}" --top tb_top --desc "$OUT/wrap/cva6.json" --gen-flags "$GEN" -o "$OUT/contract"
export RTL="${RTL_SIM[*]}"
export RTL_DEFINES OCV_UVM_GEN="$GEN"
# the reference model in the testbench: the runner's model of the core
export TB_C="$OCV/models/cpu/ocv_cpu_model.c $MODEL_SRCS"
# the board builds: the runner checks the core against the model (ocv_model_checker's board side)
[ "$MODE" = pc ] || TB_C="$TB_C $OCV/sw/lib/ocv_runner.c $OCV/uvm/ocv_uvm_runner.c"
export TB_CFLAGS="$MODEL_CFLAGS -I$OUT/gen"
# CVA6 in Verilator as hw/cpu/run.sh pc builds it
export TB_VFLAGS="--x-assign fast --x-initial fast --noassert"
OUT=$OUT OCV_CONTRACT=$OUT/contract "$OCV/uvm/build_board.sh" "$MODE" "$OUT/contract/desc.json" tb_top "${TB[@]}"
# CVA6's RVFI tracer writes trace_hart_0.dasm where the test runs (~50 bytes per instruction): to /dev/null
rm -f "$OUT/trace_hart_0.dasm"; ln -s /dev/null "$OUT/trace_hart_0.dasm"
