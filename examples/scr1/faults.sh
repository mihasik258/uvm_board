#!/usr/bin/env bash
# faults.sh - fault-injection campaign on the SCR1 core through OCV: each fault is a one-line
# change in a copy of scr1/src; the program (default: hello) runs through the co-simulation and
# the retire stream is compared with the RV32IMC model. Reports DETECT / ESCAPE per fault; an
# ESCAPE means the program never exercises the broken behaviour (a coverage gap of the test,
# not of the platform). The SCR1 sources themselves are never modified.
#   examples/scr1/faults.sh <program.hex>        (RUN_EXTRA="--overlap ..." adds runner options)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "${SCR1:-$HERE/../../ext/scr1}/src" && pwd)
WORK=${WORK:-$HERE/build/faults}
PROG=$(realpath "$1")
mkdir -p "$WORK"

# name | file (relative to scr1/src) | exact "old" ==> "new" (one source line)
FAULTS=$(cat <<'LIST'
sra-is-logical|core/pipeline/scr1_pipe_ialu.sv|2'b11   : shft_res = shft_op1 >>> shft_op2;==>2'b11   : shft_res = shft_op1 >> shft_op2;
sll-by-one-less|core/pipeline/scr1_pipe_ialu.sv|default : shft_res = shft_op1  << shft_op2;==>default : shft_res = shft_op1  << (shft_op2 == 5'd1 ? 5'd0 : shft_op2);
bge-ignores-overflow|core/pipeline/scr1_pipe_ialu.sv|ialu2exu_cmp_res_o  = ~(main_sum_flags.s ^ main_sum_flags.o);==>ialu2exu_cmp_res_o  = ~main_sum_flags.s;
bgeu-wrong-vs-max|core/pipeline/scr1_pipe_ialu.sv|ialu2exu_cmp_res_o  = ~main_sum_flags.c;==>ialu2exu_cmp_res_o  = ~main_sum_flags.c | (exu2ialu_main_op2_i == 32'hFFFF_FFFF);
mulhu-as-mulhsu|core/pipeline/scr1_pipe_ialu.sv|assign mul_cmd  = {((exu2ialu_cmd_i == SCR1_IALU_CMD_MULHU) | (exu2ialu_cmd_i == SCR1_IALU_CMD_MULHSU)),==>assign mul_cmd  = {((exu2ialu_cmd_i == SCR1_IALU_CMD_MULHSU)),
LIST
)

printf '%-22s %-8s %s\n' FAULT RESULT DETAIL
n=0
while IFS='|' read -r name file body; do
    old=${body%%==>*}; new=${body#*==>}
    n=$((n+1)); dir=$WORK/$n-$name; rm -rf "$dir"; mkdir -p "$dir"
    cp -r "$SRC" "$dir/src"
    if ! OLD="$old" NEW="$new" python3 -c '
import os, sys
p = sys.argv[1]; s = open(p).read(); old, new = os.environ["OLD"], os.environ["NEW"]
sys.exit(1) if s.count(old) != 1 else open(p, "w").write(s.replace(old, new, 1))
' "$dir/src/$file"; then
        echo "$name: pattern not found exactly once in $file"; continue
    fi
    SCR1_SRC=$dir/src OUT=$dir/build "$HERE/run_cosim.sh" "$PROG" -- --quiet ${RUN_EXTRA:-} > "$dir/run.log" 2>&1
    rc=$?
    # with --squash N a fused window is reported first, then the replay names the record: use it
    rep=$dir/run.log
    if grep -q '^REPLAY:' "$dir/run.log"; then sed -n '/^REPLAY:/,$p' "$dir/run.log" > "$dir/replay.log"; rep=$dir/replay.log; fi
    case $rc in
        0) printf '%-22s %-8s %s\n' "$name" ESCAPE "program never exercises it" ;;
        2) printf '%-22s %-8s %s\n' "$name" DETECT "$(grep -m1 -E '^(MISMATCH|FAIL)' "$rep")"
           grep -A2 -m1 '^MISMATCH' "$rep" | tail -2 | sed 's/^/                                /' ;;
        *) printf '%-22s %-8s %s\n' "$name" "ERR$rc" "see $dir/run.log" ;;
    esac
done <<< "$FAULTS"
echo "faults: $n run"
