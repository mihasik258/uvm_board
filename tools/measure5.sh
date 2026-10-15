#!/bin/sh
# measure5.sh - the model takes a translated block whole (cpu_block_t: no cpu_retire_t per instruction) with
# its coverage plan cached (cov_plan) against without the plan (OCV_NO_PLAN=1) and without blocks
# (OCV_NO_BLOCKS=1: instruction by instruction, no folding), on the board, the cva6 image booted: the CVA6
# checks (generated programs, Embench, the reproducers must still fail) and test A, three ways.
# Results: ocv/results5/cva6.txt on the card.
O=$(cd "$(dirname "$0")" && pwd)
C=$O/cpu/cva6
R=$O/results5; mkdir -p "$R"
OUT=$R/cva6.txt
now() { cut -d' ' -f1 /proc/uptime; }
t() {   # label, command...: one line (seconds, verdict), the whole output into the file
    l=$1; shift
    s=$(now); "$@" > /tmp/m5.log 2>&1; rc=$?; e=$(now)
    { echo "### $l (exit $rc, $(awk "BEGIN { print $e - $s }") s): $*"; cat /tmp/m5.log; } >> "$OUT"
    printf '%-44s %9s s  %s\n' "$l" "$(awk "BEGIN { print $e - $s }")" \
        "$(grep -E -m2 "PASS|FAIL|MISMATCH|ERRATUM" /tmp/m5.log | tr '\n' ' ' | cut -c1-110)" | tee -a "$OUT"
}
echo "# measure5 cva6 $(date)" >> "$OUT"
if ! sh "$C/run.sh" --info > /tmp/info.log 2>&1 || ! grep -q "hub, endpoints and bus OK" /tmp/info.log; then
    echo "measure5: the booted image is not cva6 (cp BOOT_cva6.BIN BOOT.BIN, reboot)"; exit 1
fi
G="--model-opt gen=directed --batches 8 --reset-each-batch --batch 1048576 --max-cycles 50000000"
E="--batch 1048576 --squash 4096 --model-opt max=3000000000 --max-cycles 6000000000"
t "runner: 8 programs"                      sh "$C/run.sh" $G --squash 4096
t "runner: 8 programs, every record"        sh "$C/run.sh" $G --squash 1
t "runner: 8 programs, window 64"           sh "$C/run.sh" $G --squash 64
for p in "$C"/embench/*_s1.hex; do t "embench $(basename "$p" .hex)" sh "$C/run.sh" --model-opt program="$p" $E; done
RP="--batch 1048576 --squash 1 --max-cycles 2000000"
t "repro mie_disable (#3175)"   sh "$C/run.sh" --model-opt program="$C/repro/mie_disable.hex" --model-opt irq=0x80 $RP
t "repro flushed_load_min"      sh "$C/run.sh" --model-opt program="$C/repro/flushed_load_min.bin" $RP
for p in "$C"/embench/*_s100.hex; do
    t "TEST A blocks+plan: $(basename "$p" .hex)" sh "$C/run.sh" --model-opt program="$p" $E --profile
    t "TEST A blocks, no plan: $(basename "$p" .hex)" env OCV_NO_PLAN=1 sh "$C/run.sh" --model-opt program="$p" $E
    t "TEST A no blocks: $(basename "$p" .hex)" env OCV_NO_BLOCKS=1 sh "$C/run.sh" --model-opt program="$p" $E
done
sync
echo "measure5: cva6 DONE - $OUT"
