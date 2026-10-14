#!/usr/bin/env bash
# synth_ooc.sh - cost/timing check: synthesize a generated OCV wrapper out of context on the
# target part (default: Versal VD100), and split the cost between DUT and platform.
#
#   hw/scripts/synth_ooc.sh [<descriptor.json> <dut.sv> ...]     (default: examples/mac16)
#
# Needs Vivado on PATH, or VIVADO_SETTINGS pointing at settings64.sh.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/../.." && pwd)
if [ $# -ge 2 ]; then DESC=$(realpath "$1"); shift; DUT_SRCS=(); for f in "$@"; do DUT_SRCS+=("$(realpath "$f")"); done
else DESC=$OCV/examples/mac16/mac16.json; DUT_SRCS=("$OCV/examples/mac16/mac16.sv"); fi
NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DESC")
OUT=$(realpath -m "${OUT:-$OCV/hw/build/synth_ooc/$NAME}")
PERIOD=${PERIOD:-5.0}          # ns; 200 MHz, well above the DUT clocks in use
PARTS=${PARTS:-"xcve2302-sfva784-1LP-e-S"}   # VD100; other boards only when we move to them

if ! command -v vivado >/dev/null; then
    : "${VIVADO_SETTINGS:?vivado not on PATH; set VIVADO_SETTINGS to settings64.sh}"
    source "$VIVADO_SETTINGS"
fi
export LC_ALL=C

rm -rf "$OUT"; mkdir -p "$OUT"
python3 "$OCV/gen/ocv_gen.py" "$DESC" -o "$OUT/gen" > "$OUT/gen.log"
{ sed "s#^#$OCV/hw/rtl/#" "$OCV/hw/rtl/ocv.f"; printf '%s\n' "${DUT_SRCS[@]}" "$OUT/gen/${NAME}_ocv.sv"; } > "$OUT/files.f"
echo "part,family,lut,ff,bram_tiles,dsp,dut_lut,dut_ff,dut_bram,dut_dsp,wns_ns" > "$OUT/summary.csv"
cd "$OUT"
# shellcheck disable=SC2086
vivado -mode batch -nojournal -nolog -source "$OCV/hw/scripts/synth_ooc.tcl" \
    -tclargs "$OUT" "${NAME}_ocv" "$PERIOD" "$OUT/files.f" $PARTS > synth.log 2>&1 \
    || { echo "vivado failed, see $OUT/synth.log"; exit 1; }
grep '^OCV_SYNTH' synth.log
column -s, -t "$OUT/summary.csv"
