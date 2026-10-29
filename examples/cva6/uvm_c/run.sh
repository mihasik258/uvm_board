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
# the functional coverage: core-v-verif's isacov (cva6_isacov.sv: its packages), unmodified; Spike's disassembler for it
CVV=${CORE_V_VERIF:-$OCV/ext/core-v-verif}
L=$CVV/lib; SPK=$CVV/vendor/riscv/riscv-isa-sim
TB=("$HERE/cva6_if.sv" "$HERE/cva6_isacov.sv" "$HERE/cva6_c_pkg.sv" "$HERE/tb_top.sv")
COV_INC="+incdir+$L/uvm_libs/uvml_hrtbt +incdir+$L/uvm_libs/uvml_trn +incdir+$L/uvm_libs/uvml_logs"
COV_INC="$COV_INC +incdir+$L/uvm_agents/uvma_core_cntrl +incdir+$L/uvm_agents/uvma_rvfi +incdir+$L/uvm_agents/uvma_isacov"
COV_INC="$COV_INC +incdir+$L/uvm_agents/uvma_isacov/cov +incdir+$SPK/disasm +incdir+$CVA6/verif/tb/core +incdir+$CVA6/core/include"
mkdir -p "$OUT/dasm"; cp "$OCV/examples/cva6/cov/dasm_config.h" "$OUT/dasm/config.h"
COV_C="$SPK/disasm/dpi_dasm.cc $SPK/disasm/disasm.cc $SPK/disasm/regnames.cc $SPK/disasm/isa_parser.cc $OCV/examples/cva6/cov/ocv_cva6_cov_stubs.cpp"
COV_CFLAGS="-I$OUT/dasm -I$OCV/build/verilator/install/share/verilator/include/vltstd -I$SPK/riscv -I$SPK/softfloat -I$SPK -I$SPK/fesvr -I$SPK/disasm"
GEN=${OCV_UVM_GEN:---dma 128}            # (as the board image: hw/cpu/run.sh ... vd100 with OCV_GEN_FLAGS="--dma 128")
python3 "$OCV/uvm/ocv_contract.py" "${TB[@]}" --top tb_top --desc "$OUT/wrap/cva6.json" --gen-flags "$GEN" -o "$OUT/contract"
export RTL="${RTL_SIM[*]}"
export RTL_DEFINES OCV_UVM_GEN="$GEN"
# the reference model in the testbench: the runner's model of the core
export TB_C="$OCV/models/cpu/ocv_cpu_model.c $MODEL_SRCS $COV_C"
# the board builds: the runner checks the core against the model (ocv_model_checker's board side)
[ "$MODE" = pc ] || TB_C="$TB_C $OCV/sw/lib/ocv_runner.c $OCV/uvm/ocv_uvm_runner.c"
export OCV_HUB=plain                     # (the hub as the runner drives it: the hw/cpu image's)
export TB_CFLAGS="$MODEL_CFLAGS -I$OUT/gen $COV_CFLAGS"
# CVA6 in Verilator as hw/cpu/run.sh pc builds it; the coverage's packages (isacov's warnings as in cov.sh)
export TB_VFLAGS="--x-assign fast --x-initial fast --noassert $COV_INC -Wno-BADSTDPRAGMA -Wno-SUPERNFIRST -Wno-ENUMVALUE"
OUT=$OUT OCV_CONTRACT=$OUT/contract "$OCV/uvm/build_board.sh" "$MODE" "$OUT/contract/desc.json" tb_top "${TB[@]}"
# CVA6's RVFI tracer writes trace_hart_0.dasm where the test runs (~50 bytes per instruction): to /dev/null
rm -f "$OUT/trace_hart_0.dasm"; ln -s /dev/null "$OUT/trace_hart_0.dasm"
