#!/usr/bin/env bash
# baseline_pc.sh - the PC side of the board-vs-PC comparison: how many instructions per second this
# PC checks for a core, at its best, without the board. The same generated programs and the same
# reference model as on the board (hw/cpu/run.sh <bind> pc: the core's wrapper in Verilator -O3,
# every record compared in the process), measured as
#   - one process on the fastest P-core (taskset), single-threaded Verilator;
#   - one process, Verilator --threads T (the best a single long test can get);
#   - a farm: N independent processes (different program seeds) at once - generated programs are
#     independent, so a regression spreads over all cores; throughput = all instructions / wall time.
#
#   tools/baseline_pc.sh <core.bind> [programs per process (default 4)]
# Environment: FARMS="1 6 12 22" process counts, THREADS="2 4" Verilator thread counts,
# CPUS_<N>="list" CPU list for N processes (default: P-cores first, see below).
# Output: a table on stdout and build/baseline/<core>/results.txt.
#
# This laptop (Intel Core Ultra 7 155H): CPUs 0-11 are the 6 P-cores with HT (1-4 boost to 4.8 GHz,
# the rest 4.5), 12-19 the 8 E-cores (3.8 GHz), 20-21 the 2 LP E-cores (2.5 GHz).
set -uo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 1 ] || { sed -n '2,17p' "$0"; exit 1; }
BIND=$(realpath "$1"); PROGS=${2:-4}
NAME=$(awk '$1 == "name" { print $2; exit }' "$BIND")
B=$OCV/build/baseline/$NAME
mkdir -p "$B"
FARMS=${FARMS:-"1 6 12 22"}
THREADS=${THREADS:-"2 4"}
# one process per physical P-core first (fastest), then their HT siblings, then E-cores, LP E-cores
ORDER=(1 3 0 6 8 10 2 4 5 7 9 11 12 13 14 15 16 17 18 19 20 21)

# instructions and seconds of one tb_pc log: the model's coverage line counts instructions
parse() {   # file -> "instructions seconds"
    python3 - "$1" <<'EOF'
import re, sys
t = open(sys.argv[1]).read()
i = re.search(r"COV total: .*?, (\d+) instructions", t)
s = re.search(r"tb_pc: .* ([0-9.]+) s\s*$", t, re.M)
ok = re.search(r"tb_pc: \S+ PASS", t)
print(i.group(1) if i else 0, s.group(1) if s else 0, "ok" if ok else "FAIL")
EOF
}

echo "baseline_pc: $NAME, $PROGS generated program(s) per process, $(nproc) CPUs: $(lscpu | sed -n 's/^Model name: *//p')"
# build once (and warm the caches)
OUT=$B "$OCV/hw/cpu/run.sh" "$BIND" pc gen:directed -- --batches 1 --reset-each-batch > "$B/build_run.log" 2>&1 \
    || { tail -20 "$B/build_run.log"; exit 1; }
TB=$B/pc/obj/tb_pc
{
printf '%-26s %6s %12s %10s %14s\n' "run" "procs" "instructions" "wall, s" "instr/s"
for n in $FARMS; do
    v=CPUS_$n; read -r -a cpus <<< "${!v:-${ORDER[*]:0:$n}}"
    t0=$(date +%s.%N)
    for ((k = 0; k < n; k++)); do
        # (each process at most 1 GB: a run away model must not take the PC down with it)
        ( ulimit -v 1000000; exec taskset -c "${cpus[$((k % ${#cpus[@]}))]}" "$TB" --model-opt gen=directed \
            --model-opt "seed=$((k + 1))" --batches "$PROGS" --reset-each-batch ) > "$B/farm_${n}_$k.log" 2>&1 &
    done
    wait
    t1=$(date +%s.%N)
    tot=0; bad=0
    for ((k = 0; k < n; k++)); do
        read -r ins _ st < <(parse "$B/farm_${n}_$k.log"); tot=$((tot + ins)); [ "$st" = ok ] || bad=$((bad + 1))
    done
    wall=$(python3 -c "print(f'{$t1 - $t0:.2f}')")
    printf '%-26s %6d %12d %10s %14.0f%s\n' "farm (seeds 1..$n)" "$n" "$tot" "$wall" \
        "$(python3 -c "print($tot / ($t1 - $t0))")" "$([ $bad = 0 ] || echo "  ($bad FAILED)")"
done
for t in $THREADS; do
    OUT=$B OCV_VLT_THREADS=$t "$OCV/hw/cpu/run.sh" "$BIND" pc gen:directed -- --batches 1 --reset-each-batch \
        > "$B/build_t$t.log" 2>&1 || { echo "threads $t: build failed ($B/build_t$t.log)"; continue; }
    t0=$(date +%s.%N)
    taskset -c "$(IFS=,; echo "${ORDER[*]:0:$t}")" "$B/pc_t$t/obj/tb_pc" --model-opt gen=directed --model-opt seed=1 \
        --batches "$PROGS" --reset-each-batch > "$B/threads_$t.log" 2>&1
    t1=$(date +%s.%N)
    read -r ins _ st < <(parse "$B/threads_$t.log")
    printf '%-26s %6d %12d %10s %14.0f%s\n' "verilator --threads $t" 1 "$ins" "$(python3 -c "print(f'{$t1 - $t0:.2f}')")" \
        "$(python3 -c "print($ins / ($t1 - $t0))")" "$([ "$st" = ok ] || echo "  (FAILED)")"
done
} | tee "$B/results.txt"
