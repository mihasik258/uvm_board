#!/usr/bin/env bash
# farm_long.sh - the PC baseline for the long tests (test A: Embench x100 on CVA6, hundreds of millions of
# instructions each, full check of every record): N tb_pc processes at once, the long programs round robin,
# one per CPU (taskset). Throughput = all instructions / wall time until the last one ends - what this PC
# does with a set of long tests, against the board running them one after another.
#
#   tools/farm_long.sh [N (default 6: one per P-core)]
# Environment: CPUS="1 3 0 6 8 10" CPU list (default: the 6 P-cores of this Core Ultra 7 155H, one per core),
# PROGS="nettle-aes picojpeg huffbench". Needs build/farm_long/pc/obj/tb_pc
# (OUT=build/farm_long hw/cpu/run.sh examples/cva6/cva6.bind pc <program>) and build/embench/*_s100.hex
# (tools/embench.sh 100 ...). Output: build/farm_long/farm_<N>/ (a log per process) and a summary on stdout.
set -uo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
N=${1:-6}
read -r -a cpus <<< "${CPUS:-1 3 0 6 8 10}"
read -r -a progs <<< "${PROGS:-nettle-aes picojpeg huffbench}"
TB=$OCV/build/farm_long/pc/obj/tb_pc
[ -x "$TB" ] || { echo "farm_long: no $TB"; exit 1; }
D=$OCV/build/farm_long/farm_$N
rm -rf "$D"; mkdir -p "$D"
echo "farm_long: $N process(es) on CPUs ${cpus[*]}, $(lscpu | sed -n 's/^Model name: *//p'), $(date)"
t0=$(date +%s.%N)
for ((k = 0; k < N; k++)); do
    p=${progs[$((k % ${#progs[@]}))]}
    mkdir -p "$D/run$k"; ln -s /dev/null "$D/run$k/trace_hart_0.dasm"   # (CVA6's tracer: gigabytes otherwise)
    ( cd "$D/run$k" && ulimit -v 1500000 && exec taskset -c "${cpus[$((k % ${#cpus[@]}))]}" /usr/bin/time -f "time: %e s, RSS %M KB" \
        "$TB" --model-opt program="$OCV/build/embench/${p}_s100.hex" --model-opt max=3000000000 --max-cycles 6000000000 ) \
        > "$D/p${k}_$p.log" 2>&1 &
done
wait
t1=$(date +%s.%N)
tot=0
for f in "$D"/p*.log; do
    i=$(sed -n 's/^COV total: .*, \([0-9]*\) instructions.*/\1/p' "$f" | tail -1)
    tot=$((tot + ${i:-0}))
    printf '%-28s %11s instructions  %s  %s\n' "$(basename "$f" .log)" "${i:-?}" \
        "$(grep -m1 -oE 'PASS|FAIL|MISMATCH' "$f")" "$(grep -m1 '^time:' "$f")"
done
awk -v t="$tot" -v s="$(echo "$t1 - $t0" | bc)" -v n="$N" 'BEGIN {
    printf "farm_long: %d processes, %d instructions in %.0f s wall = %.0f checked instructions/s\n", n, t, s, t / s }'
