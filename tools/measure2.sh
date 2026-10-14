#!/bin/sh
# measure2.sh [core] - the reference-model round (13-14.10.2026) on the board, the core's image booted (default
# cva6): the model path alone (bench), generated programs through the runner, Embench (real programs; the long
# ones are test A: one test of hundreds of millions of instructions), the CVA6 reproducers. Results:
# ocv/results2/<core>.txt on the card. Nothing on the board is reconfigured.
O=$(cd "$(dirname "$0")" && pwd)
CORE=${1:-cva6}
C=$O/cpu/$CORE
R=$O/results2; mkdir -p "$R"
OUT=$R/$CORE.txt
now() { cut -d' ' -f1 /proc/uptime; }
t() {   # label, command...: one line (seconds, verdict), the whole output into the file
    l=$1; shift
    s=$(now); "$@" > /tmp/m2.log 2>&1; rc=$?; e=$(now)
    { echo "### $l (exit $rc, $(awk "BEGIN { print $e - $s }") s): $*"; cat /tmp/m2.log; } >> "$OUT"
    printf '%-44s %9s s  %s\n' "$l" "$(awk "BEGIN { print $e - $s }")" \
        "$(grep -E -m2 "PASS|FAIL|MISMATCH|bench_model:|ERRATUM" /tmp/m2.log | tr '\n' ' ' | cut -c1-120)" | tee -a "$OUT"
}
echo "# measure2 $CORE $(date)" >> "$OUT"
if ! sh "$C/run.sh" --info > /tmp/info.log 2>&1 || ! grep -q "hub, endpoints and bus OK" /tmp/info.log; then
    echo "measure2: the booted image is not '$CORE' (cp BOOT_$CORE.BIN BOOT.BIN, reboot)"; exit 1
fi
B=$O/bench/bench_$CORE
G="--model-opt gen=directed --batches 8 --reset-each-batch --batch 1048576 --max-cycles 50000000"
# 1. the model path alone (no FPGA): ns per instruction on the A72
t "bench: model fast, 200 programs"        "$B" --batches 200 --model-opt gen=directed
t "bench: model fast, 200 programs, no CRC" "$B" --batches 200 --crc-off --model-opt gen=directed
t "bench: model jit, 200 programs"         "$B" --batches 200 --model-opt gen=directed --model-opt cpu=jit
# 2. generated programs through the runner (full check)
t "runner: 8 programs, fast, dma"          sh "$C/run.sh" $G --squash 4096 --profile
t "runner: 8 programs, fast, bus"          sh "$C/run.sh" $G --squash 4096 --no-dma --profile
t "runner: 8 programs, jit, dma"           sh "$C/run.sh" $G --squash 4096 --model-opt cpu=jit --profile
t "runner: 8 programs, fast, every record" sh "$C/run.sh" $G --squash 1 --profile
# 3. Embench: every program, then the long ones (test A)
for p in "$C"/embench/*_s1.hex; do
    t "embench $(basename "$p" .hex)" sh "$C/run.sh" --model-opt program="$p" --batch 1048576 --squash 4096 \
        --model-opt max=3000000000 --max-cycles 6000000000
done
for p in "$C"/embench/*_s100.hex; do
    t "TEST A: $(basename "$p" .hex)" sh "$C/run.sh" --model-opt program="$p" --batch 1048576 --squash 4096 \
        --model-opt max=3000000000 --max-cycles 6000000000 --profile
done
# 4. the CVA6 reproducers (they must still fail - the core's bugs)
if [ "$CORE" = cva6 ]; then
    RP="--batch 1048576 --squash 1 --max-cycles 2000000"
    t "repro mie_disable (#3175)"   sh "$C/run.sh" --model-opt program="$C/repro/mie_disable.hex" --model-opt irq=0x80 $RP
    t "repro flushed_load_min"      sh "$C/run.sh" --model-opt program="$C/repro/flushed_load_min.bin" $RP
    t "repro stale_load_min lat 0"  sh "$C/run.sh" --model-opt program="$C/repro/stale_load_min.bin" --model-opt lat=0,0 $RP
fi
sync
echo "measure2: $CORE DONE - $OUT"
