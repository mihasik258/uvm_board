#!/usr/bin/env bash
# run.sh - the UVM test of OTBN+KMAC written by the OCV contract (otbn_c_pkg.sv): the testbench, the DUT's RTL
# (OpenTitan's, examples/otbn/files.sh) and its reference model (examples/otbn/otbn_model.c with mldsa-native); the
# DUT's description and the record packing are derived from the test's classes (uvm/ocv_contract.py).
#
#   examples/otbn/uvm_c/run.sh pc        simulation: testbench + RTL in one Verilator model
#   examples/otbn/uvm_c/run.sh host      the board build, the FPGA image simulated inside the program (no board)
#   examples/otbn/uvm_c/run.sh aarch64   the board build for the VD100's A72
# then: $OUT/tb_top +PROG=build/otbn/prog/run_mldsa87 [+ROUNDS=n] [+SEED=n] [+OCV_BASE=0x80000000 on the board]
# (the program: examples/otbn/build_prog.sh)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
MODE=${1:-pc}
OUT=$(realpath -m "${OUT:-$OCV/build/uvm/otbn_c_$MODE}")
mkdir -p "$OUT"
"$OCV/examples/otbn/files.sh" default > /dev/null
TB=("$HERE/otbn_if.sv" "$HERE/otbn_c_pkg.sv" "$HERE/tb_top.sv")
GEN=${OCV_UVM_GEN:---dma 128}
python3 "$OCV/uvm/ocv_contract.py" "${TB[@]}" --top tb_top --gen-flags "$GEN" -o "$OUT/contract"
export RTL="$OCV/examples/otbn/otbn_kmac_ocv.sv"
# OCV_RTL_REPLACE="<file.sv> ...": these files in place of OpenTitan's of the same name (an injected bug)
F=$OCV/build/otbn/rtl/default/otbn_kmac_ocv.f
if [ -n "${OCV_RTL_REPLACE:-}" ]; then
    cp "$F" "$OUT/rtl.f"; F=$OUT/rtl.f
    for r in $OCV_RTL_REPLACE; do
        r=$(realpath "$r"); grep -q "/$(basename "$r")\$" "$F" || { echo "run.sh: no $(basename "$r") in the RTL"; exit 1; }
        sed -i "s#^.*/$(basename "$r")\$#$r#" "$F"
    done
fi
# OCV_RTL_DEFINES: more defines of the RTL (e.g. +define+OCV_OTBN_FAULT_BITS=22 for the injected bug)
export RTL_DEFINES="-f $F ${OCV_RTL_DEFINES:-}" OCV_UVM_GEN="$GEN"
# the reference model and ML-DSA-87 of mldsa-native (one compilation unit)
MLD=$OCV/ext/mldsa-native/mldsa
export TB_C="$OCV/examples/otbn/otbn_model.c $MLD/mldsa_native.c"
[ "$MODE" = pc ] || TB_C="$TB_C $OCV/sw/lib/ocv_runner.c $OCV/uvm/ocv_uvm_runner.c"
export OCV_HUB=plain
# Verilator as for the other cores (hw/cpu/run.sh pc): no X randomisation, no assertions (the FPGA has none)
export TB_VFLAGS="--x-assign fast --x-initial fast --noassert"
export TB_CFLAGS="-I$OUT/gen -I$MLD -DMLD_CONFIG_PARAMETER_SET=87 -DMLD_CONFIG_NAMESPACE_PREFIX=mldsa"
OUT=$OUT OCV_CONTRACT=$OUT/contract "$OCV/uvm/build_board.sh" "$MODE" "$OUT/contract/desc.json" tb_top "${TB[@]}"
