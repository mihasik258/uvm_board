#!/bin/sh
# measure.sh - every board measurement of the diploma, one image after another (tools/board_set.sh puts it on
# the card). Run it as root after each boot:
#   sh /run/media/FAT-mmcblk1p1/ocv/measure.sh          (measure.sh redo: the current image again)
# It measures the image that booted, makes the next image the one that boots and asks for a reboot; after
# the last one it says ALL DONE. Everything goes to ocv/results/ on the card (take the card to the PC).
# Nothing on the board is reconfigured (stock Linux, its clock as it is).
O=$(cd "$(dirname "$0")" && pwd)          # .../ocv
F=$(dirname "$O")                        # the FAT partition
R=$O/results; mkdir -p "$R"
STEPS="cv32e40p scr1 cva6 scr1_v mac16_v sha256_v mac16"
STATE=$R/state
[ -f "$STATE" ] || echo 1 > "$STATE"
[ "${1:-}" = redo ] && echo $(( $(cat "$STATE") - 1 > 0 ? $(cat "$STATE") - 1 : 1 )) > "$STATE"
i=$(cat "$STATE")
step=$(echo $STEPS | cut -d' ' -f"$i")
[ -n "$step" ] || { echo "measure: ALL DONE - results in $R"; exit 0; }
OUT=$R/${i}_$step.txt
echo "measure: step $i of $(echo $STEPS | wc -w): $step -> $OUT"

now() { cut -d' ' -f1 /proc/uptime; }
# a timed command: label, command...; one line in the results: label, seconds, verdict lines
t() {
    l=$1; shift
    s=$(now); "$@" > /tmp/m.log 2>&1; rc=$?; e=$(now)
    { echo "### $l (exit $rc, $(awk "BEGIN { print $e - $s }") s): $*"; cat /tmp/m.log; } >> "$OUT"
    printf '%-46s %8s s  %s\n' "$l" "$(awk "BEGIN { print $e - $s }")" \
        "$(grep -E -m2 "PASS|FAIL|MISMATCH|UVM_ERROR :|\[SB\]|ERRATUM" /tmp/m.log | tr '\n' ' ' | cut -c1-120)" | tee -a "$OUT"
}

{ echo "# $step, $(date)"; uname -a; cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null
  grep -i huge /proc/meminfo; } >> "$OUT"
# the image must be the one this step expects: its hub says so (DUT_ID) - else boot it
check() {   # run.sh of the step
    if ! sh "$1" --info > /tmp/info.log 2>&1 || ! grep -q "INFO: hub, endpoints and bus OK" /tmp/info.log; then
        echo "measure: the booted image is not '$step' (or the hub does not answer): see /tmp/info.log"
        echo "         to boot it: cp $F/BOOT_$step.BIN $F/BOOT.BIN && sync && reboot"
        exit 1
    fi
}
U=+UVM_NO_RELNOTES
case $step in
cv32e40p|scr1|cva6)
    C=$O/cpu/$step
    check "$C/run.sh"
    [ "$step" = cv32e40p ] && t "busbench (PS->hub bus, ns per access)" "$O/ocv_busbench" --base 0x80000000 --span 0x800000 --slot 2
    sh "$C/board_bench.sh" 8 >> "$OUT" 2>&1; tail -n 25 "$OUT" | grep -E "^(dma|bus|[a-z0-9_-]+\.(hex|bin))"
    if [ "$step" = cva6 ]; then
        # (the whole program in one batch; window 1: a looping program never closes a window of 4096)
        R="--batch 1048576 --squash 1 --max-cycles 2000000"
        t "cva6 repro mie_disable (#3175)" sh "$C/run.sh" --model-opt program="$C/repro/mie_disable.hex" --model-opt irq=0x80 $R
        for r in flushed_load_min stale_load_min stale_load_min_v5; do   # a6 = 1 / 5 (another load's data), lat 0,0
            for l in 0,0 2,3 4,4; do
                t "cva6 repro $r lat $l" sh "$C/run.sh" --model-opt program="$C/repro/$r.bin" --model-opt lat=$l $R
            done
        done
    fi
    if [ "$step" = cv32e40p ]; then
        for p in "$C"/uvm_fast/progs/*.hex; do
            n=$(basename "$p")
            t "core-v-verif UVM $n, dma" sh -c "cd $C/uvm_fast && OCV_BASE=0x80000000 ./uvmt_cv32e40p_tb +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c +firmware=$p"
            t "core-v-verif UVM $n, bus" sh -c "cd $C/uvm_fast && OCV_NO_DMA=1 OCV_BASE=0x80000000 ./uvmt_cv32e40p_tb +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c +firmware=$p"
        done
    fi ;;
scr1_v)
    D=$O/scr1_v
    for r in r1 r2 r3; do
        for dma in "" "OCV_NO_DMA=1"; do
            m=${dma:+bus}; m=${m:-dma}
            t "scr1 UVM $r as is, $m"       env $dma sh "$D/run.sh" +UVM_TESTNAME=prog_test +PROG=$r.hex +OCV_ASIS $U
            t "scr1 UVM $r window 1, $m"    env $dma sh "$D/run.sh" +UVM_TESTNAME=prog_test +PROG=$r.hex +OCV_SQUASH=1 $U
            t "scr1 UVM $r window 4096, $m" env $dma sh "$D/run.sh" +UVM_TESTNAME=prog_test +PROG=$r.hex +OCV_SQUASH=4096 $U
        done
    done ;;
mac16_v|sha256_v)
    D=$O/$step; tst=rand_test; N1=20000; N2=200000
    [ "$step" = sha256_v ] && { tst=sha_test; N1=10000; N2=100000; }
    for n in $N1 $N2; do
        for dma in "" "OCV_NO_DMA=1"; do
            m=${dma:+bus}; m=${m:-dma}
            t "$step N=$n as is, $m"  env $dma sh "$D/run.sh" +UVM_TESTNAME=$tst +N=$n +OCV_ASIS $U
            t "$step N=$n, $m"        env $dma sh "$D/run.sh" +UVM_TESTNAME=$tst +N=$n $U
        done
    done ;;
mac16)
    D=$O/mac16
    check "$D/run.sh"
    for x in "" "--throttle-out 128"; do
        t "mac16 runner 64 batches $x, dma" sh "$D/run.sh" --batches 64 $x --profile
        t "mac16 runner 64 batches $x, bus" sh "$D/run.sh" --batches 64 $x --profile --no-dma
    done ;;
esac
sync

next=$((i + 1)); echo $next > "$STATE"
nstep=$(echo $STEPS | cut -d' ' -f"$next")
if [ -z "$nstep" ]; then echo "measure: ALL DONE - results in $R"; sync; exit 0; fi
cp "$F/BOOT_$nstep.BIN" "$F/BOOT.BIN" && sync
echo "measure: '$step' done. Next: '$nstep' - its image boots next: reboot, then run measure.sh again"
