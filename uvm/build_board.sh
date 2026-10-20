#!/usr/bin/env bash
# build_board.sh - the board build of a UVM testbench on OCV agents: the testbench, as written for
# simulation, compiled by Verilator into a program for the board's processor; the DUT is in the
# FPGA (the hub built by ocv_gen.py --uvm), the agents reach it through ocv_uvm_dpi.c.
#
#   RTL="dut.sv ..." uvm/build_board.sh <target> <descriptor.json> <tb_top> <tb files ...>
#
#   target  aarch64  the program for the board (static, /dev/mem bus): run it there as
#                    ./<tb_top> +OCV_BASE=<hub address> [+UVM_TESTNAME=...] [plusargs]
#           host     the same program for this PC, the FPGA image simulated by Verilator inside
#                    it (needs RTL) - to check the board build without the board
#           pc       no board at all: the testbench driving the DUT's pins, testbench and RTL in one
#                    Verilator model (needs RTL) - the fastest way to run it on a PC, the baseline.
#                    Descriptor "-": a testbench that does not use OCV at all (plain simulation)
#           wave     pc with a waveform: the top wrapped by tbwave.py (<tb_top>_wave), traced; run it with
#                    the line the board printed on a failure (+OCV_WAVE=<channel>:<record>) - a VCD file
#                    around that record
#
# The testbench's DPI C code: TB_C="a.c b.cc", TB_CFLAGS="-Idir ..." (compiled for the target).
# More Verilator arguments for the testbench (file lists -f, defines, --vpi): TB_VFLAGS; more objects or
# linker flags: TB_LDFLAGS. Optimisation: OCV_OPT (default -O2), OCV_OPT_SLOW (code run once, default -O1).
# Output: $OUT (default build/uvm/<name>_board_<target> next to the descriptor)/<tb_top>.
# Verilator and UVM: tools/get_verilator.sh.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 4 ] || { sed -n '2,15p' "$0"; exit 1; }
TARGET=$1; DESC=$2; TOP=$3; shift 3
[ "$DESC" = - ] || DESC=$(realpath "$DESC")
TB=(); for f in "$@"; do TB+=("$(realpath "$f")"); done
read -r -a RTLS <<< "${RTL:-}"
for i in "${!RTLS[@]}"; do RTLS[$i]=$(realpath "${RTLS[$i]}"); done

VTOOL=$OCV/build/verilator/install
VERILATOR=$VTOOL/bin/verilator
[ -x "$VERILATOR" ] || { echo "build_board.sh: no Verilator - run tools/get_verilator.sh"; exit 1; }
UVM=$OCV/build/verilator/uvm_ocv/uvm_pkg_all_v2020_3_2_nodpi.svh     # patched copy (get_verilator.sh)
[ -f "$UVM" ] || { echo "build_board.sh: no $UVM - run tools/get_verilator.sh"; exit 1; }
case $TARGET in
    aarch64) CC=aarch64-linux-gnu-gcc; CXX=aarch64-linux-gnu-g++; STATIC=-static
             # the VD100's Cortex-A72 (ARMv8.0, no LSE): atomics inline, not through a helper call
             ARCH="-mcpu=cortex-a72 -mno-outline-atomics" ;;
    host|pc|wave) CC=cc; CXX=c++; STATIC=; ARCH=
             [ ${#RTLS[@]} -gt 0 ] || { echo "build_board.sh: target $TARGET simulates the DUT - give RTL"; exit 1; } ;;
    *)       echo "build_board.sh: target aarch64, host, pc or wave"; exit 1 ;;
esac
command -v "$CXX" >/dev/null || { echo "build_board.sh: $CXX not found"; exit 1; }

if [ "$DESC" = - ]; then
    case $TARGET in pc|wave) ;; *) echo "build_board.sh: no descriptor only for targets pc and wave"; exit 1 ;; esac
    NAME=$TOP
    OUT=$(realpath -m "${OUT:-build/uvm/${TOP}_$TARGET}")
else
    NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DESC")
    OUT=$(realpath -m "${OUT:-$(dirname "$DESC")/build/uvm/${NAME}_board_$TARGET}")
fi
mkdir -p "$OUT/c"
VINC=$VTOOL/share/verilator/include
OPT="${OCV_OPT:--O2} $ARCH"
# the C run for every record (OCV library, checker, DPI layer, the testbench's C: reference model and
# board_ref) on the board: link-time optimisation across them (the model's DPI function is inlined into
# board_ref), no stack protector, no position-independent code. OCV_LTO=0: as the rest.
HOT=
if [ "$TARGET" = aarch64 ] && [ "${OCV_LTO:-1}" = 1 ]; then
    HOT="-flto=${OCV_MAKE_J:-6} -fno-stack-protector -fno-pie"
fi
OBJS=()
UVMGEN=$OUT/gen                                 # where the UVM package is (OCV_HUB below)

# 1. the OCV library, the DPI layer and the bus, in C (not for a testbench without OCV)
if [ "$DESC" != - ]; then
# OCV_HUB=plain: the hub as the runner drives it (sources load whole batches - a DUT under the OCV runner
# inside the testbench, e.g. examples/cv32e40p/uvm_fast); the UVM package then comes from gen_uvm
UVMGEN=$OUT/gen
# OCV_UVM_GEN: the generator options the FPGA image was built with besides --uvm (e.g. "--dma 128"), so the
# metadata (the hub window) matches it
# shellcheck disable=SC2086
if [ "${OCV_HUB:-uvm}" = plain ]; then
    python3 "$OCV/gen/ocv_gen.py" ${OCV_UVM_GEN:-} "$DESC" -o "$OUT/gen" > "$OUT/gen.log"
    python3 "$OCV/gen/ocv_gen.py" --uvm ${OCV_UVM_GEN:-} "$DESC" -o "$OUT/gen_uvm" >> "$OUT/gen.log"
    UVMGEN=$OUT/gen_uvm
else
    python3 "$OCV/gen/ocv_gen.py" --uvm ${OCV_UVM_GEN:-} "$DESC" -o "$OUT/gen" > "$OUT/gen.log"
fi
CF=(-std=c99 -D_POSIX_C_SOURCE=200809L $OPT $HOT -Wall -Wextra -Werror -pthread -I"$OCV/sw/include" -I"$OUT/gen"
    -include "$OUT/gen/${NAME}_ocv_meta.h")
"$CC" "${CF[@]}" -c "$OCV/sw/lib/ocv.c" -o "$OUT/c/ocv.o"
"$CC" "${CF[@]}" -I"$OCV/uvm" -DOCV_UVM_DUT="${NAME}_dut" -c "$OCV/uvm/ocv_uvm_check.c" -o "$OUT/c/ocv_uvm_check.o"
OBJS+=("$OUT/c/ocv.o" "$OUT/c/ocv_uvm_check.o")
if [ "$TARGET" != pc ] && [ "$TARGET" != wave ]; then
    "$CC" "${CF[@]}" -DOCV_UVM_DUT="${NAME}_dut" -c "$OCV/uvm/ocv_uvm_dpi.c" -o "$OUT/c/ocv_uvm_dpi.o"
    OBJS+=("$OUT/c/ocv_uvm_dpi.o")
fi
fi
# mimalloc in place of the C library's malloc (tools/get_mimalloc.sh): UVM allocates and frees a
# small object per transaction; OCV_MIMALLOC=0 keeps the C library's
MI=$OCV/build/mimalloc/src
if [ "${OCV_MIMALLOC:-1}" = 1 ]; then
    [ -f "$MI/src/static.c" ] || { echo "build_board.sh: no mimalloc - run tools/get_mimalloc.sh"; exit 1; }
    "$CC" -O3 $ARCH -DMI_MALLOC_OVERRIDE -DNDEBUG -I"$MI/include" -w -c "$MI/src/static.c" -o "$OUT/c/mimalloc.o"
    OBJS+=("$OUT/c/mimalloc.o")
fi
# sampling profiler, idle unless OCV_PROF=<file> is set when the program runs (tools/prof_report.py)
"$CC" -O2 -c "$OCV/uvm/vlt/ocv_prof.c" -o "$OUT/c/ocv_prof.o"
OBJS+=("$OUT/c/ocv_prof.o")
# shellcheck disable=SC2086
for f in ${TB_C:-}; do
    o="$OUT/c/tb_$(basename "${f%.*}").o"
    case $f in
        *.cc|*.cpp) "$CXX" -std=c++17 $OPT -I"$OCV/sw/include" -I"$OCV/uvm" ${TB_CFLAGS:-} -c "$f" -o "$o" ;;
        *)          "$CC" -std=c99 $OPT $HOT -D_POSIX_C_SOURCE=200809L -I"$OCV/sw/include" -I"$OCV/uvm" ${TB_CFLAGS:-} -c "$f" -o "$o" ;;
    esac
    OBJS+=("$o")
done
if [ "$TARGET" = aarch64 ]; then
    "$CC" "${CF[@]}" -c "$OCV/sw/lib/ocv_bus_mmap.c" -o "$OUT/c/ocv_bus_mmap.o"
    "$CC" "${CF[@]}" -c "$OCV/uvm/ocv_uvm_bus_mmap.c" -o "$OUT/c/ocv_uvm_bus_mmap.o"
    OBJS+=("$OUT/c/ocv_bus_mmap.o" "$OUT/c/ocv_uvm_bus_mmap.o")
elif [ "$TARGET" = host ]; then
    # the FPGA image (hub + endpoints + DUT) as a Verilator model, linked into the program
    VFPGA=V${NAME}_ocv
    # --x-initial-edge: a reset low from time 0 still fires 'negedge rst_n' (as in hardware, where an
    # asynchronous reset acts on its level)
    "$VERILATOR" --cc --trace --x-initial-edge -Wno-fatal -Wno-lint -Wno-style --top-module "${NAME}_ocv" ${RTL_DEFINES:-} \
        -F "$OCV/hw/rtl/ocv.f" "${RTLS[@]}" "$OUT/gen/${NAME}_ocv.sv" --Mdir "$OUT/fpga" > "$OUT/fpga.log" 2>&1 \
        || { tail -20 "$OUT/fpga.log"; exit 1; }
    make -s -C "$OUT/fpga" -f "$VFPGA.mk" OPT="$OPT" "${VFPGA}__ALL.a" >> "$OUT/fpga.log" 2>&1 \
        || { tail -20 "$OUT/fpga.log"; exit 1; }
    "$CXX" -std=c++17 $OPT -I"$OCV/sw/include" -I"$OCV/sim" -I"$OUT/fpga" -I"$VINC" -I"$VINC/vltstd" \
        -DOCV_VTOP="$VFPGA" -DVL_NO_LEGACY -c "$OCV/uvm/ocv_uvm_bus_vlt.cpp" -o "$OUT/c/ocv_uvm_bus_vlt.o"
    "$CXX" -std=c++17 $OPT -I"$VINC" -I"$VINC/vltstd" -c "$VINC/verilated_vcd_c.cpp" -o "$OUT/c/verilated_vcd_c.o"
    OBJS+=("$OUT/c/ocv_uvm_bus_vlt.o" "$OUT/c/verilated_vcd_c.o" "$OUT/fpga/${VFPGA}__ALL.a")
fi

# Verilator rewrites every generated file on each run, so make would recompile all of them (thousands
# for UVM). Generate into <dir>.new and copy only what changed: unchanged files keep their dates and
# their objects are reused.
sync_gen() {
    python3 - "$1.new" "$1" <<'PYEOF'
import filecmp, os, shutil, sys
new, cur = sys.argv[1], sys.argv[2]
os.makedirs(cur, exist_ok=True)
names = set(os.listdir(new))
for n in names:
    a, b = os.path.join(new, n), os.path.join(cur, n)
    if not os.path.exists(b) or not filecmp.cmp(a, b, shallow=False):
        shutil.copy2(a, b)
gone = [n for n in os.listdir(cur) if n not in names and n.endswith((".cpp", ".h", ".mk", ".dat"))]
if gone:                                        # the set of files changed: dependency files would
    for n in os.listdir(cur):                   # name the vanished ones - build everything anew
        if n not in names:
            os.remove(os.path.join(cur, n))
shutil.rmtree(new)
PYEOF
}

# 2. the testbench: SystemVerilog -> C++ (on this PC), then compiled for the target; with OCV's
#    in-process constraint solver (uvm/vlt/ocv_fast_random.cpp), the SMT solver only as a fallback
#    (pc: without OCV_BOARD - the harness instantiates the DUT, whose RTL is compiled in)
# board form: time advances only with the DUT's clocks, so a frozen DUT (e.g. a program load, one
# record per item with +OCV_ASIS) makes many zero-time handshakes in one evaluation - not a loop
VTRACE=()
if [ "$TARGET" = wave ]; then                   # the top as written, inside the wrapper that dumps the window
    python3 "$OCV/uvm/tbwave.py" "${TB[@]}" --top "$TOP" -o "$OUT/${TOP}_wave.sv"
    TB+=("$OUT/${TOP}_wave.sv"); TOP=${TOP}_wave; VTRACE=(--trace)
fi
if [ "$TARGET" = pc ] || [ "$TARGET" = wave ]; then VDUT=(${RTL_DEFINES:-} "${RTLS[@]}")
else VDUT=(+define+OCV_BOARD --converge-limit 2000000000); fi
OCVSV=("$OCV/uvm/ocv_uvm_pkg.sv" "$UVMGEN/${NAME}_ocv_uvm_pkg.sv" "$UVMGEN/${NAME}_ocv_uvm_harness.sv")
[ "$DESC" = - ] && OCVSV=()
# (main: uvm/vlt/ocv_main.cpp - the exit code says whether UVM reported an error)
"$VERILATOR" --cc --exe --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style \
    "${VTRACE[@]}" "${VDUT[@]}" +incdir+"$OCV/uvm/vlt" "$OCV/uvm/vlt/ocv_fast_random.cpp" \
    "$OCV/uvm/vlt/ocv_main.cpp" -CFLAGS "-DOCV_VTOP=V$TOP" \
    "$UVM" "${OCVSV[@]}" \
    "${TB[@]}" ${TB_VFLAGS:-} --top-module "$TOP" --Mdir "$OUT/tb.new" -o "$TOP" > "$OUT/tb.log" 2>&1 \
    || { grep -E "^%Error" -A3 "$OUT/tb.log" | head -30; exit 1; }
sync_gen "$OUT/tb"
rm -f "$OUT/tb/$TOP" "$OUT/$TOP"   # our objects are not make dependencies (and VPATH finds the copy): relink
# (OPT_GLOBAL: Verilator's runtime - scheduler, randomize - is otherwise built -Os: a third slower on the A72;
#  make does not see a flag change - the runtime objects go when the flags differ from the last build)
[ "$(cat "$OUT/tb/.opt" 2>/dev/null)" = "$OPT" ] || rm -f "$OUT"/tb/verilated*.o
echo "$OPT" > "$OUT/tb/.opt"
make -s -j"${OCV_MAKE_J:-6}" -C "$OUT/tb" -f "V$TOP.mk" CXX="$CXX" LINK="$CXX" OPT="$OPT" OPT_FAST="$OPT" OPT_GLOBAL="$OPT" OPT_SLOW="${OCV_OPT_SLOW:--O1} $ARCH" \
    LDFLAGS="${OBJS[*]} ${TB_LDFLAGS:-} -pthread $STATIC ${HOT:+$HOT $OPT}" > "$OUT/tb_make.log" 2>&1 \
    || { grep -E "error|Error" "$OUT/tb_make.log" | head -20; exit 1; }
cp "$OUT/tb/$TOP" "$OUT/$TOP"
echo "build_board: $OUT/$TOP ($(file -b "$OUT/$TOP" | cut -d, -f1-2))"
