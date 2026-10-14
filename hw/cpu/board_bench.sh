#!/bin/sh
# board_bench.sh - measurements of a core under OCV on the board (next to its run.sh; copied by make_sd.sh):
# the transport (outputs over the bus or the DMA ring), the squash window, the reference model, and the
# A72 clock - every run checks every instruction, so each line is also a PASS/FAIL.
#
#   sh board_bench.sh [programs (default 8)]
#
# Writes everything to results_<core>_<time>.txt next to itself (on the SD card: take the card to the PC) and
# prints a short table. Nothing on the board is reconfigured: the stock Linux as it boots (its CPU clock too).
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-8}
CORE=$(basename "$D")
OUTF="$D/results_${CORE}_$(date +%Y%m%d_%H%M%S).txt"
log() { echo "$*" | tee -a "$OUTF"; }

log "# board_bench $CORE, $N generated programs per run, $(date)"
log "## system"
for f in scaling_cur_freq scaling_max_freq cpuinfo_max_freq scaling_available_frequencies scaling_governor; do
    v=$(cat /sys/devices/system/cpu/cpu0/cpufreq/$f 2>/dev/null) && log "cpufreq $f: $v"
done
grep -i -E "^(MemTotal|HugePages_Total|HugePages_Free|Hugepagesize)" /proc/meminfo | while read -r l; do log "meminfo $l"; done
log "thp: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null)"
log "uname: $(uname -r)"
sh "$D/run.sh" --info >> "$OUTF" 2>&1
grep -E "INFO:" "$OUTF" | tail -1

# one run: label, runner options; the PASS line and the profile go to the file, the table gets the time
one() {
    l=$1; shift
    OCV_DMA_VERBOSE=1 sh "$D/run.sh" "$@" --profile > /tmp/bb.log 2>&1
    rc=$?
    { echo "### $l (exit $rc): run.sh $*"; cat /tmp/bb.log; } >> "$OUTF"
    t=$(grep -o "[0-9.]* s, [0-9]* status polls" /tmp/bb.log | tail -1 | cut -d' ' -f1)
    n=$(grep -o "issue=[0-9]*\|retire=[0-9]*" /tmp/bb.log | tail -1 | cut -d= -f2)
    st=$(grep -q " PASS - " /tmp/bb.log && echo PASS || echo FAIL)
    ring=$(grep -q "outputs over DMA rings" /tmp/bb.log && echo dma || echo bus)
    printf '%-34s %-4s %-4s %10s instr %8s s %10s instr/s\n' "$l" "$st" "$ring" "${n:-?}" "${t:-?}" \
        "$(awk -v n="${n:-0}" -v t="${t:-0}" 'BEGIN { if (t > 0) printf "%.0f", n / t; else print "?" }')" | tee -a "$OUTF"
}
G="--model-opt gen=directed --batches $N --reset-each-batch --max-cycles 50000000 --batch 1048576"

log "## runs"
for model in jit fast; do
    one "dma, squash 4096, $model"   $G --model-opt cpu=$model --squash 4096
    one "bus, squash 4096, $model"   $G --model-opt cpu=$model --squash 4096 --no-dma
done
one "dma, every record, jit"         $G --model-opt cpu=jit --squash 1
one "bus, every record, jit"         $G --model-opt cpu=jit --squash 1 --no-dma
one "dma, squash 4096, jit, mem 2/3" $G --model-opt cpu=jit --squash 4096 --model-opt lat=2,3
for p in "$D"/progs/*; do
    [ -f "$p" ] || continue
    one "$(basename "$p"), dma"      --model-opt program="$p" --squash 4096 --batch 1048576
    one "$(basename "$p"), bus"      --model-opt program="$p" --squash 4096 --batch 1048576 --no-dma
done

sync
echo "board_bench: all in $OUTF"
