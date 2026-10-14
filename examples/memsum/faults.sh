#!/usr/bin/env bash
# faults.sh - fault-injection campaign for the memsum demo IP (reactive: the memory it reads is the
# reference model on the PS). Each fault is a one-line change to a copy of memsum.sv, run through
# the OCV co-simulation, and must end as expected:
#   DETECT  the runner reports a mismatch / missing / extra record (exit status 2)
#   PASS    the run passes (the fault only touches a field compared with rule "ignore")
#   ESCAPE  the run passes although the IP is wrong; listed next to the setting that catches it
# The IP source itself is never modified. RUN="..." overrides the runner options.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
WORK=${WORK:-$HERE/build/faults}
RUN=${RUN:---batches 3}
LAT="--throttle-stream 128 --model-opt check_wait=0"   # memory latency injected, wait taken from the IP
mkdir -p "$WORK"

# name | expected | extra runner options | exact "old" ==> "new" (one source line)
FAULTS=$(cat <<'LIST'
address-step-8|DETECT||assign m_req_addr  = addr_q + {14'b0, i_q, 2'b00};==>assign m_req_addr  = addr_q + {13'b0, i_q, 3'b000};
address-no-carry-4k|DETECT||assign m_req_addr  = addr_q + {14'b0, i_q, 2'b00};==>assign m_req_addr  = {addr_q[31:12], 12'(addr_q[11:0] + {i_q[9:0], 2'b00})};
checksum-no-rotate|DETECT||sum_q <= {sum_q[30:0], sum_q[31]} + s_rsp_data;==>sum_q <= sum_q + s_rsp_data;
last-word-dropped|DETECT||st_q  <= (i_q + 1'b1 == len_q) ? RES : REQ;==>st_q  <= (i_q + 16'd2 >= len_q) ? RES : REQ;
wait-not-cleared|DETECT||wait_q <= 32'd0;==>wait_q <= wait_q;
data-taken-without-valid|ESCAPE||if (s_rsp_valid) begin==>if (s_rsp_valid || wait_q[1:0] == 2'd1) begin
data-taken-without-valid|DETECT|LAT|if (s_rsp_valid) begin==>if (s_rsp_valid || wait_q[1:0] == 2'd1) begin
request-ignores-ready|ESCAPE||REQ:  if (m_req_ready) st_q <= WAIT;==>REQ:  st_q <= WAIT;
request-ignores-ready|DETECT|--throttle-out 128|REQ:  if (m_req_ready) st_q <= WAIT;==>REQ:  st_q <= WAIT;
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
' "$HERE/memsum.sv" "$dir/memsum.sv"; then
        echo "$name: pattern not found in memsum.sv"; fails=$((fails+1)); continue
    fi
    [ "$opts" = LAT ] && opts=$LAT
    # shellcheck disable=SC2086
    OUT=$dir/build "$OCV/sim/cosim.sh" "$HERE/memsum.json" "$HERE/memsum_model.c" "$dir/memsum.sv" -- $RUN $opts \
        > "$dir/run.log" 2>&1
    rc=$?
    case $rc in 0) got=PASS ;; 2) got=DETECT ;; *) got="ERR$rc" ;; esac
    want=$expect; [ "$expect" = ESCAPE ] && want=PASS
    if [ "$got" = "$want" ]; then res=ok; else res=UNEXPECTED; fails=$((fails+1)); fi
    printf '%-28s %-7s %-19s %-7s %s\n' "$name" "$expect" "$(echo "${opts:--}" | cut -c1-19)" "$got" "$res"
    [ "$got" = DETECT ] && grep -m1 -E '^(MISMATCH|FAIL)' "$dir/run.log" | sed 's/^/      /'
done <<< "$FAULTS"
echo "faults: $n run, $fails unexpected"
[ $fails -eq 0 ]
