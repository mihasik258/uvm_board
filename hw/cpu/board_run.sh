#!/bin/sh
# board_run.sh - a core under OCV on the board (next to its run.sh, from `hw/cpu/run.sh <bind> vd100`): the
# generated test (models jit and fast; memory with and without random delays) and every program in progs/.
# One line per run: PASS/FAIL, what was compared, the time; then the coverage.
#   sh board_run.sh [programs for the generated test]      (default 6; 30 more with jit for throughput)
D=$(cd "$(dirname "$0")" && pwd)
N=${1:-6}
B="--batch 1048576 --squash 4096"
one() {   # label, options...
    l=$1; shift
    echo "== $l"
    sh "$D/run.sh" $B "$@" > /tmp/br.log 2>&1
    grep -E "PASS|FAIL|MISMATCH|COV total" /tmp/br.log | sed 's/; [0-9]* status polls//' | cut -c1-260
}
for m in jit fast; do
    one "gen $m $N programs" --model-opt gen=directed --model-opt cpu=$m --batches $N --reset-each-batch --max-cycles 50000000
done
one "gen jit $N programs, memory delays 2/3" --model-opt gen=directed --model-opt lat=2,3 --batches $N --reset-each-batch --max-cycles 50000000
one "gen jit 30 programs" --model-opt gen=random --model-opt seed=7 --batches 30 --reset-each-batch --max-cycles 50000000
for p in "$D"/progs/*; do
    [ -f "$p" ] || continue
    one "$(basename "$p") jit" --model-opt program="$p"
done
echo "DONE board_run"
