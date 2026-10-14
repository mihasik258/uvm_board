#!/usr/bin/env bash
# run.sh - core-v-verif's CV32E40P UVM testbench on the board, transaction by transaction: the core in the
# FPGA (hw/cpu, examples/cv32e40p/cv32e40p.bind: RAM, the virtual peripherals' windows), the testbench
# - its env, agents, test, virtual peripheral sequences - as it is on the processor; every instruction checked
# against the reference model (C, the OCV runner). The testbench's own files are not changed; three are taken
# in place of others, made here:
#   uvmt_cv32e40p_dut_wrap  -> uvmt_cv32e40p_dut_wrap_ocv.sv (the bridge: same name and ports)
#   uvma_clknrst_if.sv      -> a copy with `ocv_hold` (the clock stands still while the core runs on its own)
#   uvmt_cv32e40p_tb.sv     -> a copy without its reads of the core's internals (tb_top.py says which)
#
#   examples/cv32e40p/uvm_fast/run.sh host|aarch64      build: host = the FPGA simulated inside the program
#                                                           (to check it on a PC), aarch64 = for the board
#   examples/cv32e40p/uvm_fast/run.sh test +firmware=<hex|elf> [plusargs]   run the host build
# On the board: ./uvmt_cv32e40p_tb +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c +firmware=<hex> (OCV_BASE=0x80000000)
# The FPGA image is the binding's (hw/cpu/run.sh examples/cv32e40p/cv32e40p.bind vd100).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
EXT=$(cd "$OCV/ext" && pwd)
export CORE_V_VERIF=${CORE_V_VERIF:-$EXT/core-v-verif}
export DESIGN_RTL_DIR=${CV32E40P:-$EXT/cv32e40p}/rtl
CV=$CORE_V_VERIF/cv32e40p
export DV_UVMT_PATH=$CV/tb/uvmt DV_UVME_PATH=$CV/env/uvme TBSRC_HOME=$CV/tb
export DV_SVLIB_PATH=$CV/vendor_lib/verilab
L=$CORE_V_VERIF/lib
export DV_UVML_HRTBT_PATH=$L/uvm_libs/uvml_hrtbt DV_UVML_TRN_PATH=$L/uvm_libs/uvml_trn DV_UVML_LOGS_PATH=$L/uvm_libs/uvml_logs
export DV_UVML_SB_PATH=$L/uvm_libs/uvml_sb DV_UVML_MEM_PATH=$L/uvm_libs/uvml_mem
for a in clknrst interrupt debug obi_memory core_cntrl isacov rvfi rvvi pma fencei; do
    v=DV_UVMA_$(echo $a | tr a-z A-Z)_PATH; export "$v=$L/uvm_agents/uvma_$a"
done
export DV_OVPM_HOME=$CORE_V_VERIF/vendor_lib/imperas DV_OVPM_MODEL=$CORE_V_VERIF/vendor_lib/imperas/imperas_DV_COREV
export DV_OVPM_DESIGN=$CORE_V_VERIF/vendor_lib/imperas/design
V=$OCV/build/verilator/install/bin/verilator
VI=$(dirname "$V")/../share/verilator/include
OUT=${OUT:-$HERE/../build/uvm_fast}
T=${1:-}
mkdir -p "$OUT"
[ -x "$V" ] && export PATH="$(dirname "$V"):$PATH"

case $T in
    test) shift
          Z3=$(command -v z3 || ls "$EXT"/z3venv/bin/z3 2>/dev/null || true)
          [ -n "$Z3" ] && export VERILATOR_SOLVER="${VERILATOR_SOLVER:-$Z3 --in}"
          exec "$OUT/board_host/uvmt_cv32e40p_tb" +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c "$@" ;;
    host|aarch64) ;;
    *) sed -n '2,17p' "$0"; exit 1 ;;
esac

# the core under OCV: wrapper, channels, the model's header
python3 "$OCV/gen/cpu_wrap.py" "$HERE/../cv32e40p.bind" -o "$OUT/wrap" > "$OUT/wrap.log"
# shellcheck disable=SC1091
source "$OUT/wrap/wrap.env"

# the ISS component without the ISS (as vlt.sh), the clock interface with ocv_hold
python3 "$HERE/../no_iss/gen_no_iss.py" "$CORE_V_VERIF" "$OUT/no_iss"
mkdir -p "$OUT/inc"
python3 - "$DV_UVMA_CLKNRST_PATH/uvma_clknrst_if.sv" "$OUT/inc/uvma_clknrst_if.sv" <<'EOF'
import sys
s = open(sys.argv[1]).read()
a, b = "   bit       clk_active = 0;\n", "      forever begin\n         #(clk_period);\n"
assert a in s and b in s, "uvma_clknrst_if.sv: not the expected clock loop"
s = s.replace(a, a + "   bit       ocv_hold   = 0;   // OCV: the clock stands still while set (the core runs in the FPGA)\n")
s = s.replace(b, "      forever begin\n         if (ocv_hold) wait (!ocv_hold);   // OCV\n         #(clk_period);\n")
open(sys.argv[2], "w").write("// MADE by examples/cv32e40p/uvm_fast/run.sh from core-v-verif's uvma_clknrst_if.sv: + ocv_hold\n" + s)
EOF

# the testbench's file list without its DUT wrapper and top (the bridge and the top's copy come in their
# place); the core's packages (not its modules)
python3 "$HERE/tb_top.py" "$DV_UVMT_PATH/uvmt_cv32e40p_tb.sv" "$OUT/uvmt_cv32e40p_tb_ocv.sv"
sed '/uvmt_cv32e40p_dut_wrap\.sv/d; /uvmt_cv32e40p_tb\.sv/d' "$DV_UVMT_PATH/uvmt_cv32e40p.flist" > "$OUT/uvmt_cv32e40p_ocv.flist"
python3 "$OCV/uvm/flist.py" --modules-not-packages -f "$DESIGN_RTL_DIR/../cv32e40p_manifest.flist" > "$OUT/rtl_pkgs.f"
case $T in aarch64) TCC=aarch64-linux-gnu-gcc; TF="-mcpu=cortex-a72" ;; *) TCC=cc; TF= ;; esac
$TCC -std=gnu99 -O2 -w $TF -I"$VI" -I"$VI/vltstd" -Dio_printf=printf \
    -c "$DV_SVLIB_PATH/svlib/svlib/src/dpi/svlib_dpi.c" -o "$OUT/svlib_dpi_$T.o"
BOARD=$OUT/board_$T
export TB_VFLAGS="+incdir+$OUT/inc -Wno-BADSTDPRAGMA -Wno-SUPERNFIRST --error-limit 100000 +define+UVM +define+ISS
    -f $OUT/rtl_pkgs.f -f $OUT/uvmt_cv32e40p_ocv.flist -f $OUT/no_iss/no_iss.flist --vpi"
export TB_LDFLAGS="$OUT/svlib_dpi_$T.o -lpthread"
# the runner, the model and the bridge's C side, for the target
export TB_C="$OCV/sw/lib/ocv_runner.c $OCV/models/cpu/ocv_cpu_model.c $MODEL_SRCS $OCV/uvm/cpu/ocv_uvm_cpu.c"
export TB_CFLAGS="$MODEL_CFLAGS -I$BOARD/gen"
# the FPGA image for host: the wrapper and the core
export RTL="${RTL_SIM[*]}"
export RTL_DEFINES
# the hub as in the binding's FPGA image (hw/cpu/run.sh ... vd100): the runner drives it
OCV_HUB=plain OCV_OPT=${OCV_OPT:--Os} OCV_OPT_SLOW=${OCV_OPT_SLOW:--O0} OUT=$BOARD exec "$OCV/uvm/build_board.sh" "$T" "$DESC" \
    uvmt_cv32e40p_tb "$HERE/uvmt_cv32e40p_dut_wrap_ocv.sv" "$OUT/uvmt_cv32e40p_tb_ocv.sv"
