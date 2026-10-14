#!/usr/bin/env bash
# run_uvm.sh - run a UVM testbench built on OCV agents (ocv_gen.py --uvm).
#
#   RTL="dut.sv ..." uvm/run_uvm.sh <mode> <descriptor.json> <tb_top> <tb files ...> [-- <plusargs>]
#
#   mode  sim      simulation as usual: the testbench drives the DUT's pins (Vivado xsim)
#         pcboard  the board's code path on a PC: the testbench is built with OCV_BOARD (no DUT in
#                  it) and talks through ocv_uvm_dpi.c + the OCV library to the FPGA image (hub +
#                  DUT) simulated by Verilator in the same process - exactly what runs on the board,
#                  where the bus is /dev/mem instead
#
# The testbench's own C code for DPI (reference models): TB_C="a.c b.cc", TB_CFLAGS="-Idir ...".
# The DUT's defines/include dirs, Verilator style: RTL_DEFINES="-DFOO -Idir" (also given to xvlog);
# XVLOG_FLAGS="--relax" etc. for sources that only Verilator/synthesis accept.
# Build output in $OUT (default: build/uvm/<name>_<mode> next to the descriptor). Needs Vivado
# 2023.2 (VIVADO_SETTINGS or xvlog in PATH) and, for pcboard, Verilator.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 4 ] || { sed -n '2,13p' "$0"; exit 1; }
MODE=$1; DESC=$(realpath "$2"); TOP=$3; shift 3
TB=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do TB+=("$(realpath "$1")"); shift; done
[ $# -gt 0 ] && shift
PLUS=("$@")
read -r -a RTLS <<< "${RTL:-}"
for i in "${!RTLS[@]}"; do RTLS[$i]=$(realpath "${RTLS[$i]}"); done
case $MODE in sim|pcboard) ;; *) echo "run_uvm.sh: mode sim or pcboard"; exit 1 ;; esac

NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DESC")
OUT=$(realpath -m "${OUT:-$(dirname "$DESC")/build/uvm/${NAME}_$MODE}")
mkdir -p "$OUT"
python3 "$OCV/gen/ocv_gen.py" --uvm "$DESC" -o "$OUT/gen" > "$OUT/gen.log"

[ -n "${VIVADO_SETTINGS:-}" ] && source "$VIVADO_SETTINGS"
command -v xvlog >/dev/null || { echo "run_uvm.sh: xvlog not found (set VIVADO_SETTINGS)"; exit 1; }
export LC_ALL=C

DEFS=(); XEL=(); XDEFS=()
# shellcheck disable=SC2086
for t in ${RTL_DEFINES:-}; do
    case $t in -D*) XDEFS+=(-d "${t#-D}") ;; -I*) XDEFS+=(-i "${t#-I}") ;; esac
done
# the testbench's DPI C code and OCV's checker engine, compiled into one object list
mkdir -p "$OUT/tbc"
MCF=(-std=c99 -O2 -fPIC -D_POSIX_C_SOURCE=200809L -I"$OCV/sw/include" -I"$OCV/uvm" -I"$OUT/gen"
     -include "$OUT/gen/${NAME}_ocv_meta.h" -DOCV_UVM_DUT="${NAME}_dut")
cc "${MCF[@]}" -c "$OCV/uvm/ocv_uvm_check.c" -o "$OUT/tbc/ocv_uvm_check.o"
TBO=("$OUT/tbc/ocv_uvm_check.o")
# shellcheck disable=SC2086
for f in ${TB_C:-}; do
    o="$OUT/tbc/$(basename "${f%.*}").o"
    case $f in
        *.cc|*.cpp) c++ -std=c++17 -O2 -fPIC -I"$OCV/sw/include" -I"$OCV/uvm" ${TB_CFLAGS:-} -c "$f" -o "$o" ;;
        *)          cc -std=c99 -O2 -fPIC -D_POSIX_C_SOURCE=200809L -I"$OCV/sw/include" -I"$OCV/uvm" ${TB_CFLAGS:-} -c "$f" -o "$o" ;;
    esac
    TBO+=("$o")
done
SV=("$OCV/uvm/ocv_uvm_pkg.sv" "$OUT/gen/${NAME}_ocv_uvm_pkg.sv" "$OUT/gen/${NAME}_ocv_uvm_harness.sv")
if [ "$MODE" = sim ]; then
    SV=("${RTLS[@]}" "${SV[@]}")
    # simulation needs the OCV library only for the checker engine (record layout, compare rules)
    cc "${MCF[@]}" -c "$OCV/sw/lib/ocv.c" -o "$OUT/tbc/ocv_lib.o"
    mkdir -p "$OUT/dpi"
    c++ -shared -o "$OUT/dpi/libocv_tb.so" "${TBO[@]}" "$OUT/tbc/ocv_lib.o" -static-libstdc++ -static-libgcc
    XEL=(-sv_root "$OUT/dpi" -sv_lib libocv_tb)
else
    DEFS=(-d OCV_BOARD)
    # the FPGA image (generated wrapper: hub + endpoints + DUT) as a Verilator model, the OCV
    # library and the DPI layer: one shared library for the simulator
    VTOP=V${NAME}_ocv
    verilator --cc -Wno-fatal -Wno-lint -Wno-style --trace --top-module "${NAME}_ocv" ${RTL_DEFINES:-} \
        -F "$OCV/hw/rtl/ocv.f" "${RTLS[@]}" "$OUT/gen/${NAME}_ocv.sv" \
        --Mdir "$OUT/vlt" > "$OUT/verilate.log" 2>&1 || { tail -20 "$OUT/verilate.log"; exit 1; }
    make -s -C "$OUT/vlt" -f "$VTOP.mk" OPT="-O2 -fPIC" "${VTOP}__ALL.a" libverilated.a > "$OUT/vlt_make.log" 2>&1 \
        || make -s -C "$OUT/vlt" -f "$VTOP.mk" OPT="-O2 -fPIC" > "$OUT/vlt_make.log" 2>&1 \
        || { tail -20 "$OUT/vlt_make.log"; exit 1; }
    VINC=$(verilator --getenv VERILATOR_ROOT)/include
    CF=(-O2 -fPIC -pthread -I"$OCV/sw/include" -I"$OUT/gen" -include "$OUT/gen/${NAME}_ocv_meta.h")
    mkdir -p "$OUT/dpi"
    cc -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror "${CF[@]}" -c "$OCV/sw/lib/ocv.c" -o "$OUT/dpi/ocv.o"
    cc -std=c99 -D_POSIX_C_SOURCE=200809L -Wall -Wextra -Werror "${CF[@]}" -DOCV_UVM_DUT="${NAME}_dut" \
        -c "$OCV/uvm/ocv_uvm_dpi.c" -o "$OUT/dpi/ocv_uvm_dpi.o"
    c++ -std=c++17 -O2 -fPIC -I"$OCV/sw/include" -I"$OCV/sim" -I"$OUT/vlt" -I"$VINC" -I"$VINC/vltstd" \
        -DOCV_VTOP="$VTOP" -c "$OCV/uvm/ocv_uvm_bus_vlt.cpp" -o "$OUT/dpi/ocv_uvm_bus_vlt.o"
    # libstdc++ linked in: the simulator may bring an older one than this compiler's
    c++ -shared -o "$OUT/dpi/libocv_uvm.so" "$OUT/dpi/"*.o "${TBO[@]}" "$OUT/vlt/${VTOP}__ALL.a" "$OUT/vlt/libverilated.a" \
        -static-libstdc++ -static-libgcc -pthread
    XEL=(-sv_root "$OUT/dpi" -sv_lib libocv_uvm)
fi

cd "$OUT"
# shellcheck disable=SC2086
xvlog -sv -L uvm ${XVLOG_FLAGS:-} "${DEFS[@]}" "${XDEFS[@]}" "${SV[@]}" "${TB[@]}" > xvlog.log 2>&1 || { grep -E "ERROR|error" xvlog.log | head -20; exit 1; }
xelab -L uvm -timescale 1ns/1ps "${DEFS[@]}" "${XEL[@]}" "$TOP" -s "${TOP}_snap" > xelab.log 2>&1 \
    || { grep -E "ERROR|error" xelab.log | head -20; exit 1; }
args=()
for p in "${PLUS[@]}"; do args+=(-testplusarg "${p#+}"); done
t0=$(date +%s.%N)
xsim "${TOP}_snap" -R "${args[@]}" > xsim.log 2>&1 || true
t1=$(date +%s.%N)
grep -E "UVM_(ERROR|FATAL) [^:]|\[SB\]|\[OCV\]|UVM_ERROR :|UVM_FATAL :" xsim.log | grep -v "^UVM_INFO .*RNTST" || true
printf 'run_uvm: %s %s wall %.2f s\n' "$NAME" "$MODE" "$(echo "$t1 - $t0" | bc)"
e=$(awk '/^UVM_ERROR :/{print $3}' xsim.log); f=$(awk '/^UVM_FATAL :/{print $3}' xsim.log)
[ "${e:-1}" = 0 ] && [ "${f:-1}" = 0 ] && { echo "UVM_RESULT: PASS"; exit 0; }
echo "UVM_RESULT: FAIL (see $OUT/xsim.log)"; exit 1
