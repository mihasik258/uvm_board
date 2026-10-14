#!/usr/bin/env bash
# run.sh - the SCR1 UVM testbench (scr1_tb_pkg.sv): one place for its RTL, defines and DPI model.
#
#   examples/scr1/uvm/run.sh sim|pcboard <program.hex> [plusargs]   xsim (uvm/run_uvm.sh)
#   examples/scr1/uvm/run.sh host|aarch64                            board build (build_board.sh),
#                                    translated by uvm2board.py (OCV_TRANSLATE=0: the testbench as is);
#                                    (the board top installs the overrides; +OCV_ASIS=1 runs it as is)
#   examples/scr1/uvm/run.sh pc                                      no board: testbench + SCR1 RTL
#                                    in one Verilator model (the PC baseline); run build/uvm/scr1_board_pc/tb_top
#
# SCR1_REF=iss|spike picks the reference model at run time (spike: build with TB_SPIKE=1).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
SCR1=$(cd "${SCR1:-$OCV/ext/scr1}" && pwd)
S=${SCR1_SRC:-$SCR1/src}                # SCR1_SRC: another copy (fault injection)
MODE=$1; shift
{ sed -e '$a\' "$S/core.files"; sed -e '$a\' "$S/axi_top.files"
  printf '%s\n' core/cache/scr1_icache.sv core/cache/scr1_dcache.sv core/cache/scr1_cache_wrapper.sv; } \
  | sed "s#^#$S/#" | grep -v '^\s*$' > /tmp/scr1_uvm_rtl.$$
RTL="$(tr '\n' ' ' < /tmp/scr1_uvm_rtl.$$) $HERE/../scr1_ocv_axi_mem.sv $HERE/../scr1_ocv_dut.sv"
rm -f /tmp/scr1_uvm_rtl.$$
export RTL
export RTL_DEFINES="-DSCR1_CFG_RV32IMC_MAX -DSCR1_RVFI_EN -I$S/includes"
export TB_C="$HERE/scr1_ref_dpi.c $OCV/models/cpu/cpu_model.c $OCV/models/cpu/iss/rv32_iss.c"
export XVLOG_FLAGS="--relax"            # SCR1 uses some signals before declaring them
export TB_CFLAGS="-I$OCV/uvm -I$OCV/models/cpu -I$OCV/models/cpu/iss"
TB=("${TB_PKG:-$HERE/scr1_tb_pkg.sv}" "$HERE/tb_top.sv")   # TB_PKG: a variant of the package (tests)
case $MODE in
    sim|pcboard)
        PROG=$(realpath "$1"); shift
        exec "$OCV/uvm/run_uvm.sh" "$MODE" "$HERE/../scr1.json" tb_top "${TB[@]}" -- "+PROG=$PROG" "$@" ;;
    host|aarch64)
        # the board form of the testbench: uvm2board.py writes an overlay (engine A for the retire
        # scoreboard, the program loaded as one block); OCV_TRANSLATE=0 builds the testbench as is
        if [ "${OCV_TRANSLATE:-1}" = 1 ]; then
            OVL=${OVL:-$HERE/../build/uvm/scr1_board_overlay}
            python3 "$OCV/uvm/uvm2board.py" "$HERE/../scr1.json" "${TB[@]}" -o "$OVL" --top tb_top
            export TB_C="$TB_C $OVL/board_ref.c"
            exec "$OCV/uvm/build_board.sh" "$MODE" "$HERE/../scr1.json" tb_top_board "${TB[@]}" "$OVL/board_overlay.sv"
        fi
        exec "$OCV/uvm/build_board.sh" "$MODE" "$HERE/../scr1.json" tb_top "${TB[@]}" ;;
    pc)
        exec "$OCV/uvm/build_board.sh" pc "$HERE/../scr1.json" tb_top "${TB[@]}" ;;
    *) sed -n '2,8p' "$0"; exit 1 ;;
esac
