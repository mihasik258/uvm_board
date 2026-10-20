#!/usr/bin/env bash
# run.sh - a processor core under OCV from its binding (gen/cpu_wrap.py): co-simulation on the PC or the
# VD100 build. Every instruction the core executes is compared with the reference model.
#
#   hw/cpu/run.sh <core.bind> cosim gen:random|gen:directed|<program.hex> [-- <cosim/runner options>]
#   hw/cpu/run.sh <core.bind> pc gen:directed|<program.hex> [-- --batches N]
#                                                           (OCV_PC_VCD=1: a build with -- --vcd FILE --vcd-from C --vcd-to C)
#                                                           the PC reference: the wrapper in Verilator (-O3),
#                                                           the same model, no hub (hw/cpu/pc/tb_pc.cpp)
#   hw/cpu/run.sh <core.bind> bench [-- --batches N --model-opt k=v]   the reference model path alone (no DUT):
#                                                           ns per instruction (OCV_BENCH_ARCH=aarch64: for the A72)
#   hw/cpu/run.sh <core.bind> vd100                     FPGA image + PS program (platforms/vd100/build.sh;
#                                                           its environment: VIVADO_SETTINGS, REF_BOOTBIN, ...)
#
# Generated programs: one per batch (--batches N --reset-each-batch). OUT: build directory (default
# build/cpu/<name>). On the board: run.sh --model-opt gen=directed --batches 6 --reset-each-batch
set -euo pipefail
OCV=$(cd "$(dirname "$0")/../.." && pwd)
[ $# -ge 2 ] || { sed -n '2,11p' "$0"; exit 1; }
BIND=$(realpath "$1"); MODE=$2; shift 2
NAME=$(awk '$1 == "name" { print $2; exit }' "$BIND")
OUT=$(realpath -m "${OUT:-$OCV/build/cpu/$NAME}")
mkdir -p "$OUT"
# OCV's Verilator (tools/get_verilator.sh): elaborates the core for the wrapper, simulates it
[ -x "$OCV/build/verilator/install/bin/verilator" ] && export PATH="$OCV/build/verilator/install/bin:$PATH"
python3 "$OCV/gen/cpu_wrap.py" "$BIND" -o "$OUT/wrap" > "$OUT/wrap.log" || { cat "$OUT/wrap.log"; exit 1; }
# shellcheck disable=SC1091
source "$OUT/wrap/wrap.env"
MODEL_CFLAGS="$MODEL_CFLAGS ${OCV_CFLAGS_EXTRA:-}"   # (OCV_CFLAGS_EXTRA: e.g. a test setting of the runner)
export RTL_DEFINES MODEL_SRCS MODEL_CFLAGS
case $MODE in
    cosim)
        [ $# -ge 1 ] || { echo "run.sh: cosim needs gen:random, gen:directed or a program"; exit 1; }
        case $1 in
            gen:*) PROG_OPT="gen=${1#gen:}"
                   # a generated program ends within a few million clocks: one that does not (a core
                   # looping in its trap handler) fails instead of running on
                   MAXC=(--max-cycles "${OCV_MAX_CYCLES:-50000000}") ;;
            *)     PROG_OPT="program=$(realpath "$1")"; MAXC=() ;;
        esac
        shift
        [ "${1:-}" = "--" ] && shift
        export RTL_DEFINES="$RTL_DEFINES -Wno-fatal"
        OUT=$OUT/cosim exec "$OCV/sim/cosim.sh" "$DESC" "$OCV/models/cpu/ocv_cpu_model.c" "${RTL_SIM[@]}" \
            -- --batch "$BATCH" --model-opt "$PROG_OPT" "${MAXC[@]}" "$@" ;;
    pc)
        [ $# -ge 1 ] || { echo "run.sh: pc needs gen:random, gen:directed or a program"; exit 1; }
        case $1 in
            gen:*) PROG_OPT="gen=${1#gen:}" ;;
            *)     PROG_OPT="program=$(realpath "$1")" ;;
        esac
        shift
        [ "${1:-}" = "--" ] && shift
        # OCV_VLT_THREADS=N: the core in a multi-threaded Verilator model (the PC baseline's best single run)
        # OCV_PC_VCD=1: a build that can write a VCD file (tb_pc --vcd FILE --vcd-from C --vcd-to C) - its own directory
        P=$OUT/pc${OCV_VLT_THREADS:+_t$OCV_VLT_THREADS}$([ "${OCV_PC_VCD:-0}" = 1 ] && echo _vcd || true)
        mkdir -p "$P/c"
        python3 "$OCV/gen/ocv_gen.py" "$DESC" -o "$P/gen" > "$P/gen.log"
        OBJS=()
        # shellcheck disable=SC2086
        for f in "$OCV/sw/lib/ocv.c" "$OCV/models/cpu/ocv_cpu_model.c" $MODEL_SRCS; do
            o=$P/c/$(basename "${f%.c}").o
            # shellcheck disable=SC2086
            cc -std=c99 -O2 -D_POSIX_C_SOURCE=200809L -I"$OCV/sw/include" -I"$P/gen" $MODEL_CFLAGS -c "$f" -o "$o"
            OBJS+=("$o")
        done
        if [ ! -x "$P/obj/tb_pc" ] || [ -n "$(find "$OUT/wrap" "$OCV/hw/cpu" -newer "$P/obj/tb_pc" -type f | head -1)" ]; then
            # shellcheck disable=SC2086
            # shellcheck disable=SC2046
            # (OCV_PC_ASSERT=1: with the RTL's own assertions - slower, for looking into a mismatch; own OUT)
            verilator --cc --exe --build -j "${OCV_MAKE_J:-6}" -O3 --x-assign fast --x-initial fast \
                $([ "${OCV_PC_ASSERT:-0}" = 1 ] && echo --assert || echo --noassert) \
                $([ -n "${OCV_VLT_THREADS:-}" ] && echo --threads "$OCV_VLT_THREADS") \
                $([ "${OCV_PC_VCD:-0}" = 1 ] && echo --trace) \
                -Wno-fatal -Wno-lint -Wno-style $RTL_DEFINES --top-module "${NAME}_dut" "${RTL_SIM[@]}" \
                "$OCV/hw/cpu/pc/tb_pc.cpp" -CFLAGS "-O2 -I$OUT/wrap -I$OCV/sw/include -I$P/gen $(sed -n 's/^#define CPU_STOP  *\(0x[0-9a-fA-F]*\)u.*/-DCPU_STOP_ADDR=\1u/p' "$OUT/wrap/ocv_cpu_wrap.h")" \
                -LDFLAGS "${OBJS[*]}" --Mdir "$P/obj" -o tb_pc > "$P/build.log" 2>&1 \
                || { tail -20 "$P/build.log"; exit 1; }
        fi
        # run in its build directory: files the core's RTL writes stay there; CVA6's Verilator tracer
        # (trace_hart_0.dasm, ~50 bytes per instruction - gigabytes on a long program) goes to /dev/null unless
        # OCV_PC_TRACE=1
        mkdir -p "$P/run"
        [ "${OCV_PC_TRACE:-0}" = 1 ] || { rm -f "$P/run/trace_hart_0.dasm"; ln -s /dev/null "$P/run/trace_hart_0.dasm"; }
        cd "$P/run" && exec "$P/obj/tb_pc" --model-opt "$PROG_OPT" "$@" ;;
    bench)
        # the reference model path alone (hw/cpu/pc/bench_model.c), the same flags as the board program;
        # OCV_BENCH_ARCH=aarch64: a static program for the board's A72 (no FPGA image needed to run it)
        A=${OCV_BENCH_ARCH:-host}
        P=$OUT/bench_$A
        mkdir -p "$P"
        python3 "$OCV/gen/ocv_gen.py" "$DESC" -o "$P/gen" > "$P/gen.log"
        if [ "$A" = aarch64 ]; then CC=aarch64-linux-gnu-gcc; F="-O3 -mcpu=cortex-a72 -flto -fno-stack-protector -fno-pie -no-pie -U_FORTIFY_SOURCE -static"
        else CC=cc; F="-O3 -march=native -flto -fno-stack-protector -U_FORTIFY_SOURCE"; fi
        F="$F ${OCV_BENCH_EXTRA:-}"            # (e.g. -g: lines for a profile; the code stays the same)
        # shellcheck disable=SC2086
        $CC -std=c99 $F -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -I"$OCV/sw/include" -I"$P/gen" $MODEL_CFLAGS \
            "$OCV/hw/cpu/pc/bench_model.c" "$OCV/sw/lib/ocv.c" "$OCV/models/cpu/ocv_cpu_model.c" $MODEL_SRCS \
            -o "$P/bench_model"
        [ "$A" = host ] || { echo "run.sh: $P/bench_model"; exit 0; }
        [ "${1:-}" = "--" ] && shift
        exec "$P/bench_model" "$@" ;;
    vd100)
        OUT=$OUT/vd100 OCV_CLK_MHZ=${OCV_CLK_MHZ:-50} exec "$OCV/platforms/vd100/build.sh" "$DESC" \
            "$OCV/models/cpu/ocv_cpu_model.c" "${RTL_FPGA[@]}" ;;
    *)  echo "run.sh: mode cosim, pc or vd100"; exit 1 ;;
esac
