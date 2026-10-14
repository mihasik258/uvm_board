#!/bin/sh
# measure3.sh - the jit model with cpu_retire_t.raw / src1 / src2 (gives_src) against fast, on the board, the
# cva6 image booted: the model path alone (bench), generated programs and Embench through the runner, test A
# (the three long Embench programs) - each with both models. Results: ocv/results3/cva6.txt on the card.
O=$(cd "$(dirname "$0")" && pwd)
C=$O/cpu/cva6
R=$O/results3; mkdir -p "$R"
OUT=$R/cva6.txt
now() { cut -d' ' -f1 /proc/uptime; }
t() {   # label, command...: one line (seconds, verdict), the whole output into the file
    l=$1; shift
    s=$(now); "$@" > /tmp/m3.log 2>&1; rc=$?; e=$(now)
    { echo "### $l (exit $rc, $(awk "BEGIN { print $e - $s }") s): $*"; cat /tmp/m3.log; } >> "$OUT"
    printf '%-44s %9s s  %s\n' "$l" "$(awk "BEGIN { print $e - $s }")" \
        "$(grep -E -m2 "PASS|FAIL|MISMATCH|bench_model:|jit:" /tmp/m3.log | tr '\n' ' ' | cut -c1-150)" | tee -a "$OUT"
}
echo "# measure3 cva6 $(date)" >> "$OUT"
if ! sh "$C/run.sh" --info > /tmp/info.log 2>&1 || ! grep -q "hub, endpoints and bus OK" /tmp/info.log; then
    echo "measure3: the booted image is not cva6 (cp BOOT_cva6.BIN BOOT.BIN, reboot)"; exit 1
fi
export OCV_JIT_STATS=1
B=$O/bench/bench_cva6
G="--model-opt gen=directed --batches 8 --reset-each-batch --batch 1048576 --max-cycles 50000000"
for m in fast jit; do
    t "bench $m: 200 programs"              "$B" --batches 200 --model-opt gen=directed --model-opt cpu=$m
    for p in nettle-aes picojpeg huffbench crc32; do
        t "bench $m: $p s1"                 "$B" --batches 1 --model-opt program="$C/embench/${p}_s1.hex" \
            --model-opt max=3000000000 --model-opt cpu=$m
    done
    t "runner $m: 8 programs"               sh "$C/run.sh" $G --squash 4096 --model-opt cpu=$m
done
for p in "$C"/embench/*_s1.hex; do
    for m in fast jit; do
        t "embench $m $(basename "$p" .hex)" sh "$C/run.sh" --model-opt program="$p" --batch 1048576 --squash 4096 \
            --model-opt max=3000000000 --max-cycles 6000000000 --model-opt cpu=$m
    done
done
for p in "$C"/embench/*_s100.hex; do
    for m in jit fast; do
        t "TEST A $m: $(basename "$p" .hex)" sh "$C/run.sh" --model-opt program="$p" --batch 1048576 --squash 4096 \
            --model-opt max=3000000000 --max-cycles 6000000000 --model-opt cpu=$m
    done
done
sync
echo "measure3: cva6 DONE - $OUT"
