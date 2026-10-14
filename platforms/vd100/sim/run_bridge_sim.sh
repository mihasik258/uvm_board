#!/usr/bin/env bash
# run_bridge_sim.sh - the VD100 PS -> hub path in simulation, before the board: the platform's real
# SmartConnect in front of a generated environment, driven by the unmodified PS program (runner +
# model over DPI) through an AXI4 master that accesses the bus like the A72 does via mmap.
#
#   platforms/vd100/sim/run_bridge_sim.sh <descriptor.json> <model.c> <dut.sv> [...] [-- <runner options>]
#
# Same arguments and environment as sim/cosim.sh (RTL_DEFINES, MODEL_SRCS, MODEL_CFLAGS).
# BRIDGE_JITTER=<0..100> random master stalls (default 30). Default runner options: --info.
# Needs Vivado 2023.2 (VIVADO_SETTINGS or vivado in PATH). Prints BRIDGE_RESULT: PASS|FAIL.
set -euo pipefail
SIM=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$SIM/../../.." && pwd)

[ $# -ge 3 ] || { sed -n '2,11p' "$0"; exit 1; }
DESC=$(realpath "$1"); MODEL=$(realpath "$2"); shift 2
RTL=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do RTL+=("$(realpath "$1")"); shift; done
[ $# -gt 0 ] && shift
ARGS="${*:---info}"; ARGS="${ARGS// /,}"          # one plusarg token: options joined by commas

NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DESC")
OUT=$(realpath -m "${OUT:-$(dirname "$DESC")/build/bridge_sim/$NAME}")
mkdir -p "$OUT"
python3 "$OCV/gen/ocv_gen.py" "$DESC" -o "$OUT/gen" > "$OUT/gen.log"
AW=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["addr_w"])' "$OUT/gen/${NAME}_ocv_meta.json")
{ sed "s#^#$OCV/hw/rtl/#" "$OCV/hw/rtl/ocv.f"; printf '%s\n' "${RTL[@]}" "$OUT/gen/${NAME}_ocv.sv"; } > "$OUT/rtl.f"

DEFS=(); INCS=(); CINC=("$OCV/sw/include" "$OUT/gen")
for a in ${RTL_DEFINES:-}; do
    case "$a" in -D*) DEFS+=("${a#-D}") ;; -I*) INCS+=("$(realpath "${a#-I}")") ;; esac
done
for a in ${MODEL_CFLAGS:-}; do case "$a" in -I*) CINC+=("$(realpath "${a#-I}")") ;; esac; done
# the PS program as a DPI library (system compiler; SV tasks resolved when xsim loads it)
# shellcheck disable=SC2046,SC2086
cc -std=c99 -O2 -fPIC -shared -pthread -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L $(printf -- '-I%s ' "${CINC[@]}") \
    "$SIM/bridge_dpi.c" "$OCV/sw/lib/ocv.c" "$OCV/sw/lib/ocv_runner.c" "$MODEL" ${MODEL_SRCS:-} \
    -Wl,--unresolved-symbols=ignore-all -o "$OUT/libocvdpi.so"

[ -n "${VIVADO_SETTINGS:-}" ] && source "$VIVADO_SETTINGS"
( cd "$OUT" && LC_ALL=C BR_OUT="$OUT" BR_ENV="${NAME}_ocv" BR_AW="$AW" BR_RTL_F="$OUT/rtl.f" \
    BR_DPI="$OUT/libocvdpi.so" BR_DEFINES="${DEFS[*]:-}" BR_INCDIRS="${INCS[*]:-}" \
    BR_ARGS="$ARGS" BR_JITTER="${BRIDGE_JITTER:-30}" \
    vivado -mode batch -notrace -source "$SIM/bridge_sim.tcl" > "$OUT/vivado.log" 2>&1 ) || true
LOG=$(ls "$OUT"/vivado/bridge.sim/sim_1/behav/xsim/simulate.log 2>/dev/null || true)
if [ -z "$LOG" ]; then grep -E "ERROR" "$OUT/vivado.log" | head -20; echo "BRIDGE_RESULT: FAIL (no simulation)"; exit 1; fi
grep -vE "^(INFO: \[|WARNING: \[|Time resolution|source |## |\s*$)" "$LOG" | grep -vE "^(run|exit|quit)" || true
grep -q "BRIDGE_RESULT: PASS" "$LOG"
