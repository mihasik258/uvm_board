#!/usr/bin/env bash
# cov.sh - CVA6's own functional coverage (core-v-verif: the isacov agent's uvma_isacov_cov_model and
# uvme_cva6_cov_model_c, cv32a60x configuration) over RVFI records the reference model wrote, through
# Verilator (OCV's 5.052: IEEE 1800-2023 coverage, tools/verilator/ocv_cva6_tb.patch). docs/COVERAGE.md.
#
#   examples/cva6/cov/cov.sh build                  the harness: $OUT/obj/Vcov (about 7 min, 16 GB of memory)
#   examples/cva6/cov/cov.sh run <records> [name]   the coverage of the records: $OUT/<name>.rep (every
#                                                   covergroup instance and its coverpoints/crosses, as
#                                                   get_inst_coverage gives them) and $OUT/<name>.dat
#   records: hw/cpu/run.sh examples/cva6/cva6.bind bench -- --model-opt rvfi_out=<file> ...
#
# Sources: CVA6 (ext/cva6) and CORE_V_VERIF (default ext/core-v-verif), unmodified; the harness
# (ocv_cva6_cov_top.sv) builds the configuration as the CVA6 base test does and connects the coverage
# models as uvme_cva6_env_c::connect_coverage_model. The disassembler (dpi_dasm) is Spike's, as
# core-v-verif builds it; the other DPI functions of the testbench are never called (ocv_cva6_cov_stubs.cpp).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
OUT=$(realpath -m "${OUT:-$OCV/build/cov/cva6}")
export CVA6_REPO_DIR=${CVA6:-$OCV/ext/cva6} CORE_V_VERIF=${CORE_V_VERIF:-$OCV/ext/core-v-verif}
export CVA6_UVMT_DIR=$CVA6_REPO_DIR/verif/tb/uvmt CVA6_CORET_DIR=$CVA6_REPO_DIR/verif/tb/core
export CVA6_UVMT_PATH=$CVA6_UVMT_DIR CVA6_UVME_PATH=$CVA6_REPO_DIR/verif/env/uvme DV_UVME_PATH=$CVA6_REPO_DIR/verif/env/uvme
L=$CORE_V_VERIF/lib
export DV_UVML_HRTBT_PATH=$L/uvm_libs/uvml_hrtbt DV_UVML_TRN_PATH=$L/uvm_libs/uvml_trn DV_UVML_LOGS_PATH=$L/uvm_libs/uvml_logs
export DV_UVML_MEM_PATH=$L/uvm_libs/uvml_mem DV_UVML_SB_PATH=$L/uvm_libs/uvml_sb
export DV_UVMA_CORE_CNTRL_PATH=$L/uvm_agents/uvma_core_cntrl DV_UVMA_RVFI_PATH=$L/uvm_agents/uvma_rvfi
export DV_UVMA_ISACOV_PATH=$L/uvm_agents/uvma_isacov DV_UVMA_CLKNRST_PATH=$L/uvm_agents/uvma_clknrst
export DV_UVMA_AXI_PATH=$L/uvm_agents/uvma_axi5 DV_UVMA_CVXIF_PATH=$L/uvm_agents/uvma_cvxif
export DV_UVMA_INTERRUPT_PATH=$DV_UVME_PATH/uvma_interrupt DV_UVMA_DEBUG_PATH=$L/uvm_agents/uvma_debug
export DV_UVMA_OBI_PATH=$L/uvm_agents/uvma_obi DV_UVMC_RVFI_SCOREBOARD_PATH=$L/uvm_components/uvmc_rvfi_scoreboard
export DV_UVMC_RVFI_REFERENCE_MODEL_PATH=$L/uvm_components/uvmc_rvfi_reference_model
export TBSRC_HOME=$CVA6_REPO_DIR/verif/tb SPIKE_PATH=$CORE_V_VERIF/vendor/riscv/riscv-isa-sim
V=$OCV/build/verilator/install/bin/verilator
VI=$(dirname "$V")/../share/verilator/include
UVM=$OCV/build/verilator/uvm_ocv/uvm_pkg_all_v2020_3_2_nodpi.svh
CORE=$CVA6_REPO_DIR/core/include
mkdir -p "$OUT"
case ${1:-} in
    build)
        # Spike's disassembler alone (core-v-verif mk/Common.mk builds it with Spike's own configure)
        mkdir -p "$OUT/dasm"
        cp "$HERE/dasm_config.h" "$OUT/dasm/config.h"
        S=$SPIKE_PATH
        for f in $S/disasm/dpi_dasm.cc $S/disasm/disasm.cc $S/disasm/regnames.cc $S/disasm/isa_parser.cc; do
            g++ -O2 -fPIC -std=c++17 -w -I"$OUT/dasm" -I"$VI/vltstd" -I"$S/riscv" -I"$S/softfloat" -I"$S" -I"$S/fesvr" \
                -I"$S/disasm" -c "$f" -o "$OUT/dasm/$(basename "${f%.*}").o"
        done
        # the packages of the CVA6 environment, in core-v-verif's file lists (cv32a60x)
        cat > "$OUT/files.f" <<EOT
+incdir+$OCV/uvm/vlt
+incdir+$(dirname "$UVM")
+incdir+$CORE
$CORE/config_pkg.sv
$CORE/cv32a60x_config_pkg.sv
$CORE/riscv_pkg.sv
$CORE/ariane_pkg.sv
$CORE/build_config_pkg.sv
$UVM
-f \${DV_UVML_HRTBT_PATH}/uvml_hrtbt_pkg.flist
-f \${DV_UVML_TRN_PATH}/uvml_trn_pkg.flist
-f \${DV_UVML_LOGS_PATH}/uvml_logs_pkg.flist
-f \${DV_UVML_MEM_PATH}/uvml_mem_pkg.flist
-f \${DV_UVML_SB_PATH}/uvml_sb_pkg.flist
-f \${DV_UVMA_CLKNRST_PATH}/uvma_clknrst_pkg.flist
-f \${DV_UVMA_DEBUG_PATH}/uvma_debug_pkg.flist
-f \${DV_UVMA_AXI_PATH}/src/uvma_axi_pkg.flist
-f \${DV_UVMA_CORE_CNTRL_PATH}/uvma_core_cntrl_pkg.flist
-f \${DV_UVMA_RVFI_PATH}/uvma_rvfi_pkg.flist
-f \${DV_UVMA_ISACOV_PATH}/uvma_isacov_pkg.flist
-f \${DV_UVMA_CVXIF_PATH}/src/uvma_cvxif_pkg.flist
-f \${DV_UVMC_RVFI_REFERENCE_MODEL_PATH}/uvmc_rvfi_reference_model_pkg.flist
-f \${DV_UVMC_RVFI_SCOREBOARD_PATH}/uvmc_rvfi_scoreboard_pkg.flist
-f \${CVA6_UVME_PATH}/uvma_interrupt/uvma_interrupt_pkg.flist
-f \${CVA6_UVME_PATH}/uvme_cva6_pkg.flist
$CVA6_UVMT_DIR/uvmt_cva6_tb_ifs.sv
$CVA6_UVMT_DIR/uvmt_axi_switch_intf.sv
+incdir+$CVA6_CORET_DIR
$CVA6_CORET_DIR/uvma_cva6pkg_utils_pkg.sv
$HERE/ocv_cva6_cov_top.sv
EOT
        D=$OUT/dasm
        "$V" --cc --exe --build --timing --coverage-user -j "${OCV_MAKE_J:-6}" -Wno-fatal -Wno-lint -Wno-style \
            -Wno-BADSTDPRAGMA -Wno-SUPERNFIRST -Wno-ENUMVALUE +define+UVM -f "$OUT/files.f" --top-module ocv_cva6_cov_top \
            --Mdir "$OUT/obj" -o Vcov "$OCV/uvm/vlt/ocv_fast_random.cpp" "$OCV/uvm/vlt/ocv_main.cpp" \
            "$OCV/uvm/cov/ocv_cov_feed.c" "$HERE/ocv_cva6_cov_stubs.cpp" -CFLAGS "-DOCV_VTOP=Vocv_cva6_cov_top -O1" \
            -LDFLAGS "$D/dpi_dasm.o $D/disasm.o $D/regnames.o $D/isa_parser.o" > "$OUT/build.log" 2>&1 \
            || { grep -m20 '%Error\|error:' "$OUT/build.log"; exit 1; }
        echo "build: $OUT/obj/Vcov" ;;
    run)
        [ $# -ge 2 ] || { sed -n '2,12p' "$0"; exit 1; }
        REC=$(realpath "$2"); NAME=${3:-$(basename "${REC%.*}")}
        rc=0
        (cd "$OUT" && ./obj/Vcov +OCV_RVFI="$REC" +UVM_NO_RELNOTES +ocv_cov_dat="$OUT/$NAME.dat" \
            +ocv_cov_report="$OUT/$NAME.rep") > "$OUT/$NAME.log" 2>&1 || rc=$?
        grep -E "RVFI records sampled|^UVM_(ERROR|FATAL) :|^%Error" "$OUT/$NAME.log" | sed 's/^/  /' || true
        awk '/^[^ ]/ { s += $3; n++ } END { if (n) printf "cov: %d covergroup instances, mean %.2f%%\n", n, s / n }' \
            "$OUT/$NAME.rep" 2>/dev/null || true
        echo "cov: $OUT/$NAME.rep (rc $rc)"
        exit $rc ;;
    *) sed -n '2,12p' "$0"; exit 1 ;;
esac
