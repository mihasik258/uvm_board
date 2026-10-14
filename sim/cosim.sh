#!/usr/bin/env bash
# cosim.sh - build and run an OCV co-simulation for any DUT: the generated wrapper in Verilator,
# the generic runner + the DUT's reference model in C, talking over simulated AXI4-Lite.
#
#   sim/cosim.sh <descriptor.json> <model.c> <dut.sv> [<more rtl> ...] [-- <run options>]
#
# Run options go to the co-simulation (--axi-jitter N, --trace f.vcd) and the runner
# (--batches N, --batch N, --seed S, --reset-each-batch, ...). Build output: $OUT
# (default: build/cosim/<dut name> next to the descriptor). Set RTL_DEFINES="-DFOO -Idir ..." to
# pass defines/include dirs to Verilator (e.g. for fault injection), MODEL_SRCS="a.c b.c" for
# extra C sources of the model and MODEL_CFLAGS="-Idir ..." for their include paths.
# SANITIZE=thread|address builds the PS software with that sanitizer (e.g. to check --overlap).
# Model sources may be C++ (.cc/.cpp: MODEL_CXXFLAGS); MODEL_LIBS are linked in (e.g. Spike).
# COSIM_PREBUILT=1 reuses the binary already built in $OUT (runs of many programs, same build).
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)

[ $# -ge 3 ] || { sed -n '2,11p' "$0"; exit 1; }
DESC=$(realpath "$1"); MODEL=$(realpath "$2"); shift 2
RTL=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do RTL+=("$(realpath "$1")"); shift; done
[ $# -gt 0 ] && shift          # drop "--"

NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DESC")
OUT=$(realpath -m "${OUT:-$(dirname "$DESC")/build/cosim/$NAME}")
mkdir -p "$OUT"
[ "${COSIM_PREBUILT:-}" = 1 ] && [ -x "$OUT/obj/cosim" ] && exec "$OUT/obj/cosim" "$@"

# 1. wrapper + metadata (OCV_GEN_FLAGS: generator options, e.g. "--dma 128": outputs over DMA rings
#    into a "PS memory" the co-simulation provides - the board's path)
# shellcheck disable=SC2086
python3 "$OCV/gen/ocv_gen.py" ${OCV_GEN_FLAGS:-} "$DESC" -o "$OUT/gen" > "$OUT/gen.log"
DMA_DEF=""
if [[ " ${OCV_GEN_FLAGS:-} " =~ --dma[[:space:]]+([0-9]+) ]]; then DMA_DEF="-DOCV_DMA_DW=${BASH_REMATCH[1]}"; fi

# 2. PS software (plain C, same sources as on the board)
# shellcheck disable=SC2206
SAN=${SANITIZE:+-fsanitize=$SANITIZE -g}
# shellcheck disable=SC2206
CFLAGS=(-std=c99 -O2 -pthread ${SAN} -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -I"$OCV/sw/include" -I"$OUT/gen" ${MODEL_CFLAGS:-})
mkdir -p "$OUT/sw"
OBJS=()
# shellcheck disable=SC2086
for s in "$OCV/sw/lib/ocv.c" "$OCV/sw/lib/ocv_runner.c" "$MODEL" ${MODEL_SRCS:-}; do
    case $s in
        *.cc|*.cpp) o="$OUT/sw/$(basename "${s%.*}").o"
                    # shellcheck disable=SC2086
                    c++ ${MODEL_CXXFLAGS:-} -pthread ${SAN} -Wall -I"$OCV/sw/include" -I"$OUT/gen" -c "$s" -o "$o" ;;
        *)          o="$OUT/sw/$(basename "${s%.c}").o"
                    cc "${CFLAGS[@]}" -c "$s" -o "$o" ;;
    esac
    OBJS+=("$o")
done

# 3. Verilator model + co-simulation main. OCV's own RTL is kept lint-clean by hw/scripts/sim.sh;
#    warnings in the DUT's sources are reported but do not stop the run (third-party IP).
#    -j 1: Verilator 5.020 can crash on exit with a multi-threaded verilation (-j 0).
VTOP=V${NAME}_ocv
# the PS objects are not make's dependencies: a newer one means link again
for o in "${OBJS[@]}"; do [ "$o" -nt "$OUT/obj/cosim" ] && rm -f "$OUT/obj/cosim" && break; done
# shellcheck disable=SC2086
verilator --cc --exe --build -j 1 --build-jobs 0 -Wall -Wno-fatal --trace --top-module "${NAME}_ocv" ${RTL_DEFINES:-} \
    -F "$OCV/hw/rtl/ocv.f" "${RTL[@]}" "$OUT/gen/${NAME}_ocv.sv" "$OCV/sim/ocv_cosim_main.cpp" \
    -CFLAGS "-O2 -I$OCV/sw/include -DOCV_VTOP=$VTOP $DMA_DEF" \
    -LDFLAGS "${OBJS[*]} -pthread ${SAN} ${MODEL_LIBS:-}" \
    --Mdir "$OUT/obj" -o cosim > "$OUT/build.log" 2>&1 \
    || { echo "cosim.sh: Verilator build failed, see $OUT/build.log"; tail -20 "$OUT/build.log"; exit 1; }

nw=$(grep -c '^%Warning' "$OUT/build.log" || true)
[ "$nw" -gt 0 ] && echo "cosim.sh: note: $nw Verilator warning(s) in the sources, see $OUT/build.log"

# 4. run
exec "$OUT/obj/cosim" "$@"
