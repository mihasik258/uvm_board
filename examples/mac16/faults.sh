#!/usr/bin/env bash
# faults.sh - fault-injection campaign for the mac16 demo IP: each fault is a one-line change
# to a copy of mac16.sv, run through the OCV co-simulation, and must end as expected:
#   DETECT  the runner reports a mismatch / missing / extra record (exit status 2)
#   PASS    the run passes (the fault only touches a field compared with rule "ignore")
#   ESCAPE  the run passes although the IP is wrong; listed next to the setting that catches it
# The IP source itself is never modified. RUN="..." overrides the runner options.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$HERE/build/faults}
RUN=${RUN:---batches 4}
mkdir -p "$WORK"

# name | expected | extra runner options | exact "old" ==> "new" (one source line)
FAULTS=$(cat <<'LIST'
rare-wrong-accumulate|DETECT||acc_q <= (clr1 ? 40'sd0 : acc_q) + 40'(prod1);==>acc_q <= (prod1 == 32'sd1073741824) ? (clr1 ? 40'sd0 : acc_q) - 40'(prod1) : (clr1 ? 40'sd0 : acc_q) + 40'(prod1);
operand-b-unsigned|DETECT||prod1 <= s_a * s_b;==>prod1 <= s_a * $unsigned(s_b);
clear-ignored|DETECT||m_acc <= (clr1 ? 40'sd0 : acc_q) + 40'(prod1);==>m_acc <= acc_q + 40'(prod1);
accumulator-32-bit|DETECT||logic signed [39:0] acc_q;==>logic signed [31:0] acc_q;
result-valid-glitch|DETECT||assign m_valid = v2;==>assign m_valid = v2 & (cycle_q[3:0] != 4'd7);
monitor-wrong-product|DETECT||assign dbg_prod  = prod1;==>assign dbg_prod  = prod1 + 32'd1;
timestamp-garbage|PASS||m_ts  <= cycle_q;==>m_ts  <= cycle_q ^ 16'hBEEF;
ready-ignores-full|ESCAPE||assign s_ready = r1;==>assign s_ready = 1'b1;
ready-ignores-full|DETECT|--throttle-out 128|assign s_ready = r1;==>assign s_ready = 1'b1;
output-overwritten-in-stall|ESCAPE||if (r2) begin==>if (1'b1) begin
output-overwritten-in-stall|DETECT|--throttle-out 128|if (r2) begin==>if (1'b1) begin
monitor-counts-stalled|ESCAPE||assign dbg_valid = v1 & r2;==>assign dbg_valid = v1;
monitor-counts-stalled|DETECT|--throttle-out 128|assign dbg_valid = v1 & r2;==>assign dbg_valid = v1;
LIST
)

printf '%-28s %-7s %-19s %-7s %s\n' FAULT EXPECT OPTIONS GOT RESULT
fails=0; n=0
while IFS='|' read -r name expect opts body; do
    old=${body%%==>*}; new=${body#*==>}
    n=$((n+1)); dir=$WORK/$n-$name; mkdir -p "$dir"
    if ! OLD="$old" NEW="$new" python3 -c '
import os, sys
s = open(sys.argv[1]).read(); old, new = os.environ["OLD"], os.environ["NEW"]
sys.exit(1) if old not in s else open(sys.argv[2], "w").write(s.replace(old, new, 1))
' "$HERE/mac16.sv" "$dir/mac16.sv"; then
        echo "$name: pattern not found in mac16.sv"; fails=$((fails+1)); continue
    fi
    # shellcheck disable=SC2086
    OUT=$dir/build "$OCV/sim/cosim.sh" "$HERE/mac16.json" "$HERE/mac16_model.c" "$dir/mac16.sv" -- $RUN $opts \
        > "$dir/run.log" 2>&1
    rc=$?
    case $rc in 0) got=PASS ;; 2) got=DETECT ;; *) got="ERR$rc" ;; esac
    want=$expect; [ "$expect" = ESCAPE ] && want=PASS
    if [ "$got" = "$want" ]; then res=ok; else res=UNEXPECTED; fails=$((fails+1)); fi
    printf '%-28s %-7s %-19s %-7s %s\n' "$name" "$expect" "${opts:--}" "$got" "$res"
    [ "$got" = DETECT ] && grep -m1 -E '^(MISMATCH|FAIL)' "$dir/run.log" | sed 's/^/      /'
done <<< "$FAULTS"
echo "faults: $n run, $fails unexpected"
[ $fails -eq 0 ]
