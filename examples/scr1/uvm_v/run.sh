#!/usr/bin/env bash
# run.sh - the SCR1 UVM testbench written the usual way (scr1_if, scr1_pkg, tb_top): no OCV
# description, no generated agents.
#
#   examples/scr1/uvm_v/run.sh pc       plain simulation: testbench + SCR1 RTL in one Verilator model
#                                           (build/uvm/scr1_v_pc/tb_top +PROG=<hex> +UVM_TESTNAME=prog_test)
#   examples/scr1/uvm_v/run.sh wave +PROG=<hex> +OCV_WAVE=<channel>:<record>   the same simulation,
#                                           a VCD file around the record the board named on a failure
#   examples/scr1/uvm_v/run.sh sd       everything for the board in one folder (uvm/make_sd.sh): FPGA image
#                                           (rebuilt only if needed), the testbench program, the programs
#   examples/scr1/uvm_v/run.sh host|aarch64   the board form: uvm2board.py reads the testbench (the
#                                           DUT's channels from its interface, driver and monitor - no
#                                           description file), writes the overlay; build_board.sh builds
#                                           tb_top_board for this PC (FPGA image simulated) or the board
#   examples/scr1/uvm_v/run.sh vd100    the FPGA image for it (platforms/vd100/build.sh, from the same
#                                           derived description; VIVADO_SETTINGS, REF_BOOTBIN, LINUX_DIR)
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
export TB_C="$HERE/../uvm/scr1_ref_dpi.c $OCV/models/cpu/cpu_model.c $OCV/models/cpu/iss/rv32_iss.c"
export TB_CFLAGS="-I$OCV/uvm -I$OCV/models/cpu -I$OCV/models/cpu/iss"
TB=("$HERE/scr1_if.sv" "${TB_PKG:-$HERE/scr1_pkg.sv}" "$HERE/tb_top.sv")
case $MODE in
    pc) OUT=${OUT:-$HERE/../build/uvm/scr1_v_pc} exec "$OCV/uvm/build_board.sh" pc - tb_top "${TB[@]}" ;;
    wave)                               # the waveform of a failure the board found: the line it printed
        OUT=${OUT:-$HERE/../build/uvm/scr1_v_wave}
        "$OCV/uvm/build_board.sh" wave - tb_top "${TB[@]}"
        cd "$OUT" && exec ./tb_top_wave +UVM_TESTNAME=prog_test "$@" ;;
    sd) PAYLOAD="${PAYLOAD:-$(ls "$HERE"/../programs/*.hex | tr '\n' ' ')}" OCV_CLK_MHZ=${OCV_CLK_MHZ:-80} \
            OUT=${OUT:-$HERE/../build/sd/scr1_v} exec "$OCV/uvm/make_sd.sh" scr1 tb_top "${TB[@]}" ;;
    host|aarch64)
        OVL=${OVL:-$HERE/../build/uvm/scr1_v_overlay}
        python3 "$OCV/uvm/uvm2board.py" "${TB[@]}" -o "$OVL" --top tb_top
        export TB_C="$TB_C $OVL/board_ref.c"
        OUT=${OUT:-$HERE/../build/uvm/scr1_v_$MODE} exec "$OCV/uvm/build_board.sh" "$MODE" "$OVL/desc.json" tb_top_board \
            "${TB[@]}" "$OVL/board_overlay.sv" ;;
    vd100)
        OVL=${OVL:-$HERE/../build/uvm/scr1_v_overlay}
        python3 "$OCV/uvm/uvm2board.py" "${TB[@]}" -o "$OVL" --top tb_top
        read -r -a R <<< "$RTL"
        OCV_GEN_FLAGS=--uvm OCV_CLK_MHZ=${OCV_CLK_MHZ:-80} OUT=${OUT:-$HERE/../build/vd100/scr1_v} \
            exec "$OCV/platforms/vd100/build.sh" "$OVL/desc.json" - "${R[@]}" ;;
    *)  sed -n '2,13p' "$0"; exit 1 ;;
esac
