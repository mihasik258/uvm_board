#!/usr/bin/env bash
# ckpt_replay.sh - a failure the board found deep in a long test, looked at on the PC in minutes instead of
# simulating the RTL all the way there (PRODUCT_PLAN 4g):
#   1. the model alone (hw/cpu/run.sh ... bench) runs the program up to a margin before the failing window and
#      writes a checkpoint program (--model-opt ckpt=..., models/cpu/ocv_cpu_model.c ckpt_write): the RAM and a
#      loader that restores the registers and the machine-mode CSRs;
#   2. the core in Verilator and the model run that program from reset, every record compared (tb_pc): the
#      first mismatch, as a record of the whole run (the checkpoint's counts + what the PC run made);
#   3. with OCV_PC_VCD=1 (or --vcd): the same run again, the waveform around that mismatch's clock.
#
#   tools/ckpt_replay.sh <core.bind> <program.hex> <channel>:<record> [margin]   the window the board named
#   tools/ckpt_replay.sh <core.bind> <program.hex> @<instruction>                 a checkpoint at an instruction
# Options (environment): VCD=1 also the waveform (VCD_BEFORE / VCD_AFTER clocks around it, default 2000 / 200),
# MAX_CYCLES for the RTL run (default 4e9: the cause may lie far before what reads it),
# OUT (default build/ckpt/<name>), and what hw/cpu/run.sh takes (CVA6=..., a core copy). Model options of the
# board's run (irq=, lat=, gen=...) follow after --. Inputs the DUT gave the model during the run (interrupt
# times, device answers) are not replayed: for a program that has none the checkpoint is exact.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 3 ] || { sed -n '2,16p' "$0"; exit 1; }
BIND=$(realpath "$1"); PROG=$(realpath "$2"); AT=$3; MARGIN=${4:-2048}
shift 3; [ $# -gt 0 ] && [ "$1" != -- ] && shift; [ "${1:-}" = -- ] && shift
NAME=$(awk '$1 == "name" { print $2; exit }' "$BIND")
OUT=$(realpath -m "${OUT:-$OCV/build/ckpt/$NAME}"); mkdir -p "$OUT"
MO=(); for o in "$@"; do MO+=(--model-opt "$o"); done
case $AT in
    @*) CK=(--model-opt "ckpt_order=${AT#@}") ;;
    *:*) CK=(--model-opt "ckpt=$AT" --model-opt "ckpt_margin=$MARGIN") ;;
    *) echo "ckpt_replay: <channel>:<record> or @<instruction>"; exit 1 ;;
esac
MAXC=${MAX_CYCLES:-4000000000}
t0=$(date +%s)
echo "ckpt_replay: 1. the model alone up to the checkpoint"
OUT=$OUT/core "$OCV/hw/cpu/run.sh" "$BIND" bench -- --model-opt "program=$PROG" --model-opt max=100000000000 \
    "${MO[@]}" "${CK[@]}" --model-opt "ckpt_file=$OUT/ckpt" 2>&1 | grep -E "checkpoint|rror" || true
[ -f "$OUT/ckpt.hex" ] || { echo "ckpt_replay: no checkpoint written"; exit 1; }
t1=$(date +%s)
echo "ckpt_replay: 2. the core in Verilator from the checkpoint, every record compared"
rc=0
OUT=$OUT/core "$OCV/hw/cpu/run.sh" "$BIND" pc "$OUT/ckpt.hex" -- --model-opt max=100000000000 "${MO[@]}" --max-cycles "$MAXC" \
    > "$OUT/pc.log" 2>&1 || rc=$?
t2=$(date +%s)
grep -E "^tb_pc: (cva6|cv32e40p|scr1|[a-z0-9_]+) (PASS|FAIL)" "$OUT/pc.log" | tail -1 | sed 's/^/  /'
mm=$(grep -m1 "^tb_pc: MISMATCH channel" "$OUT/pc.log" || true)
if [ -z "$mm" ]; then
    echo "ckpt_replay: no mismatch after the checkpoint (rc $rc) - the cause lies before it: a larger margin, or"
    echo "             a checkpoint at an instruction before the cause (@N)"
    echo "ckpt_replay: model $((t1 - t0)) s, RTL $((t2 - t1)) s"
    exit 3
fi
ch=$(sed -n "s/^tb_pc: MISMATCH channel '\([^']*\)' record \([0-9]*\).*/\1/p" <<< "$mm")
rec=$(sed -n "s/^tb_pc: MISMATCH channel '\([^']*\)' record \([0-9]*\).*/\2/p" <<< "$mm")
clk=$(sed -n 's/.*(by clock \([0-9]*\)).*/\1/p' <<< "$mm")
read -r at ld < <(awk -v c="$ch" '$1 == "channel" && $2 == c { print $4, $6 }' "$OUT/ckpt.txt")
echo "  $mm"
grep -A2 -m1 "^tb_pc: MISMATCH channel" "$OUT/pc.log" | tail -2 | sed 's/^/  /' || true
echo "ckpt_replay: the run's record: channel '$ch' record $((at + rec - ld)) (checkpoint at $at, loader $ld, PC record $rec, clock $clk)"
echo "ckpt_replay: model $((t1 - t0)) s, RTL $((t2 - t1)) s"
if [ "${VCD:-0}" = 1 ] && [ -n "$clk" ]; then
    from=$(( clk > ${VCD_BEFORE:-2000} ? clk - ${VCD_BEFORE:-2000} : 0 )); to=$(( clk + ${VCD_AFTER:-200} ))
    echo "ckpt_replay: 3. the waveform, clocks $from..$to"
    OCV_PC_VCD=1 OUT=$OUT/core "$OCV/hw/cpu/run.sh" "$BIND" pc "$OUT/ckpt.hex" -- --model-opt max=100000000000 "${MO[@]}" --max-cycles "$to" \
        --vcd "$OUT/ckpt.vcd" --vcd-from "$from" --vcd-to "$to" > "$OUT/vcd.log" 2>&1 || true
    ls -la "$OUT/ckpt.vcd" | awk '{ print "ckpt_replay: " $NF " (" $5 " bytes)" }'
fi
