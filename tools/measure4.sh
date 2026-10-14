#!/bin/sh
# measure4.sh - a translated block's issue records folded as one piece (ocv_fold_t) against record by record
# (OCV_NO_FOLD=1), on the board, the cva6 image booted: the CVA6 checks (generated programs, Embench, the
# reproducers must still fail) and test A (the three long Embench programs), both ways.
# Results: ocv/results4/cva6.txt on the card.
O=$(cd "$(dirname "$0")" && pwd)
C=$O/cpu/cva6
R=$O/results4; mkdir -p "$R"
OUT=$R/cva6.txt
now() { cut -d' ' -f1 /proc/uptime; }
t() {   # label, command...: one line (seconds, verdict), the whole output into the file
    l=$1; shift
    s=$(now); "$@" > /tmp/m4.log 2>&1; rc=$?; e=$(now)
    { echo "### $l (exit $rc, $(awk "BEGIN { print $e - $s }") s): $*"; cat /tmp/m4.log; } >> "$OUT"
    printf '%-44s %9s s  %s\n' "$l" "$(awk "BEGIN { print $e - $s }")" \
        "$(grep -E -m2 "PASS|FAIL|MISMATCH|ERRATUM" /tmp/m4.log | tr '\n' ' ' | cut -c1-110)" | tee -a "$OUT"
}
echo "# measure4 cva6 $(date)" >> "$OUT"
if ! sh "$C/run.sh" --info > /tmp/info.log 2>&1 || ! grep -q "hub, endpoints and bus OK" /tmp/info.log; then
    echo "measure4: the booted image is not cva6 (cp BOOT_cva6.BIN BOOT.BIN, reboot)"; exit 1
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
    t "TEST A fold: $(basename "$p" .hex)"    sh "$C/run.sh" --model-opt program="$p" $E --profile
    t "TEST A no fold: $(basename "$p" .hex)" env OCV_NO_FOLD=1 sh "$C/run.sh" --model-opt program="$p" $E
done
sync
echo "measure4: cva6 DONE - $OUT"
