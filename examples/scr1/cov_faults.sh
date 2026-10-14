#!/usr/bin/env bash
# cov_faults.sh - does coverage-directed generation find bugs sooner than random generation?
#
#   examples/scr1/cov_faults.sh [programs]        (default 6 programs per run)
#
# For every fault (a one-line change in a copy of scr1/src, as in faults.sh) the same budget of
# programs, generated on the PS during the run, is run twice: plain random (gen=random) and aimed
# at the coverage bins not hit yet (gen=directed). Reports, per fault and generator, how many
# executed instructions it took until the first mismatch - or ESCAPE if the budget ran out.
# Most faults here are corner bugs: wrong only for one combination of operand values.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCR1=$(cd "${SCR1:-$HERE/../../ext/scr1}" && pwd)
SRC=${SCR1_SRC:-$SCR1/src}
WORK=${WORK:-$HERE/build/cov_faults}
P=${1:-6}
mkdir -p "$WORK"

IALU=core/pipeline/scr1_pipe_ialu.sv
FAULTS=$(cat <<LIST
sra-is-logical|$IALU|2'b11   : shft_res = shft_op1 >>> shft_op2;==>2'b11   : shft_res = shft_op1 >> shft_op2;
bge-ignores-overflow|$IALU|ialu2exu_cmp_res_o  = ~(main_sum_flags.s ^ main_sum_flags.o);==>ialu2exu_cmp_res_o  = ~main_sum_flags.s;
bgeu-wrong-vs-max|$IALU|ialu2exu_cmp_res_o  = ~main_sum_flags.c;==>ialu2exu_cmp_res_o  = ~main_sum_flags.c | (exu2ialu_main_op2_i == 32'hFFFF_FFFF);
div-min-by-m1|$IALU|ialu2exu_main_res_o    = div_cmd_rem ? div_res_rem : div_res_quo;==>ialu2exu_main_res_o    = div_cmd_rem ? div_res_rem : div_res_quo ^ {31'b0, (exu2ialu_main_op1_i == 32'h8000_0000) & (exu2ialu_main_op2_i == 32'hFFFF_FFFF)};
rem-neg-by-1|$IALU|ialu2exu_main_res_o    = div_cmd_rem ? div_res_rem : div_res_quo;==>ialu2exu_main_res_o    = div_cmd_rem ? div_res_rem ^ {31'b0, exu2ialu_main_op1_i[31] & (exu2ialu_main_op2_i == 32'h1)} : div_res_quo;
mulh-min-min|$IALU|? mul_res[SCR1_MUL_RES_WIDTH-1:\`SCR1_XLEN]==>? mul_res[SCR1_MUL_RES_WIDTH-1:\`SCR1_XLEN] ^ {31'b0, (exu2ialu_main_op1_i == 32'h8000_0000) & (exu2ialu_main_op2_i == 32'h8000_0000)}
sltu-max-min|$IALU|ialu2exu_main_res_o = \`SCR1_XLEN'(main_sum_flags.c);==>ialu2exu_main_res_o = \`SCR1_XLEN'(main_sum_flags.c ^ ((exu2ialu_main_op1_i == 32'h7FFF_FFFF) & (exu2ialu_main_op2_i == 32'h8000_0000)));
LIST
)

# instructions executed before the first mismatch: those of the earlier programs + the slot
detect_at() {
    local log=$1 b s
    read -r b s < <(sed -n "s/^MISMATCH channel 'retire' record [0-9]* (batch \([0-9]*\), slot \([0-9]*\)).*/\1 \2/p" "$log" | head -n 1)
    [ -z "${b:-}" ] && { echo "-"; return; }
    local before=0
    [ "$b" -gt 0 ] && before=$(sed -n "s/^SCR1COV program $b: .* \([0-9]*\) instructions/\1/p" "$log" | head -n 1)
    echo $(( ${before:-0} + s ))
}

printf '%-22s %-26s %-26s\n' FAULT "RANDOM ($P programs)" "DIRECTED ($P programs)"
while IFS='|' read -r name file body; do
    [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $name "* ]] && continue   # ONLY="name ..." runs a subset
    old=${body%%==>*}; new=${body#*==>}
    dir=$WORK/$name; rm -rf "$dir"; mkdir -p "$dir"
    cp -r "$SRC" "$dir/src"
    if ! OLD="$old" NEW="$new" python3 -c '
import os, sys
p = sys.argv[1]; s = open(p).read(); old, new = os.environ["OLD"], os.environ["NEW"]
sys.exit(1) if s.count(old) != 1 else open(p, "w").write(s.replace(old, new, 1))
' "$dir/src/$file"; then
        echo "$name: pattern not found exactly once in $file"; continue
    fi
    cols=()
    for mode in random directed; do
        SCR1_SRC=$dir/src OUT=$dir/build "$HERE/run_cosim.sh" "gen:$mode" -- --batches "$P" --reset-each-batch \
            --quiet ${RUN_EXTRA:-} > "$dir/$mode.log" 2>&1
        case $? in
            0) cols+=("ESCAPE") ;;
            2) at=$(detect_at "$dir/$mode.log"); cols+=("found after $at insn") ;;
            *) cols+=("ERR (see $mode.log)") ;;
        esac
    done
    printf '%-22s %-26s %-26s\n' "$name" "${cols[0]}" "${cols[1]}"
done <<< "$FAULTS"
