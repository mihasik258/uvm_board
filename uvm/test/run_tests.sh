#!/usr/bin/env bash
# run_tests.sh - checks of the UVM layer that need no simulator license and no board:
#   OCV's in-process constraint solver (t_fast_random.sv, Verilator from tools/get_verilator.sh):
#   every result satisfies its constraints, none goes to the SMT solver, the distribution is
#   uniform over the solutions
set -euo pipefail
OCV=$(cd "$(dirname "$0")/../.." && pwd)
V=$OCV/build/verilator/install/bin/verilator
[ -x "$V" ] || { echo "uvm tests: no Verilator (tools/get_verilator.sh) - skipped"; exit 0; }
OUT=${OUT:-$OCV/build/uvm_test}
mkdir -p "$OUT"
cd "$OUT"
"$V" --binary --timing -Wno-fatal -Wno-lint -Wno-style "$OCV/uvm/test/t_fast_random.sv" \
    "$OCV/uvm/vlt/ocv_fast_random.cpp" --top-module t --Mdir fr -j "${OCV_MAKE_J:-6}" > fr.log 2>&1 || { tail -20 fr.log; exit 1; }
OCV_FAST_RANDOM_DEBUG=1 fr/Vt +N=20000 > fr_run.log 2>&1
grep -E "^(RESULT|len|kind)" fr_run.log
grep -q "RESULT ok=20000 bad=0" fr_run.log || { echo "uvm tests: constraint violated"; exit 1; }
if grep -q "to the SMT solver" fr_run.log; then grep "to the SMT solver" fr_run.log | head -3; exit 1; fi
# uniform over the (len, en) solutions: len=3 1/28, len=64 2/28 of 20000 (714, 1428), +-15%
read -r l3 l64 < <(sed -n 's/^len: 3: \([0-9]*\) .*, 64: \([0-9]*\),.*/\1 \2/p' fr_run.log)
[ "$l3" -gt 607 ] && [ "$l3" -lt 821 ] && [ "$l64" -gt 1213 ] && [ "$l64" -lt 1643 ] \
    || { echo "uvm tests: distribution off (len=3 $l3, len=64 $l64)"; exit 1; }
# OCV's Verilator change: an embedded covergroup calling methods of its class (on its own object)
"$V" --binary --timing -Wno-fatal -Wno-lint -Wno-style "$OCV/tools/verilator/test/t_cg_method.sv" --top-module t \
    --Mdir cgm > cgm.log 2>&1 || { tail -20 cgm.log; exit 1; }
cgm/Vt | grep "RESULT" | tee cgm_run.log; grep -q "RESULT ok" cgm_run.log || { echo "uvm tests: covergroup methods FAILED"; exit 1; }
# soft constraints in OCV's solver, relaxed by priority as the SMT path does - no SMT solver asked
"$V" --binary --timing -Wno-fatal -Wno-lint -Wno-style "$OCV/uvm/test/t_soft.sv" \
    "$OCV/uvm/vlt/ocv_fast_random.cpp" +incdir+"$OCV/uvm/vlt" --top-module t --Mdir soft > soft.log 2>&1 \
    || { tail -20 soft.log; exit 1; }
OCV_FAST_RANDOM_DEBUG=1 VERILATOR_SOLVER=/bin/false soft/Vt > soft_run.log 2>&1
grep -q "RESULT ok" soft_run.log || { cat soft_run.log; echo "uvm tests: soft constraints FAILED"; exit 1; }
if grep -q 'to the SMT solver' soft_run.log; then cat soft_run.log; echo "uvm tests: soft constraints went to the SMT solver"; exit 1; fi
echo "soft constraints: ok"
# ... and randomize() of an object whose rand class handle is null (needs an SMT solver: z3 in PATH,
# or pvo_scr1/ext/z3venv from 'python3 -m venv z3venv && z3venv/bin/pip install z3-solver')
Z3=$(command -v z3 || ls "$OCV"/ext/z3venv/bin/z3 2>/dev/null || true)
if [ -n "$Z3" ]; then
    "$V" --binary --timing -Wno-fatal -Wno-lint -Wno-style "$OCV/tools/verilator/test/t_rand_null_member.sv" \
        "$OCV/uvm/vlt/ocv_fast_random.cpp" +incdir+"$OCV/uvm/vlt" --top-module t --Mdir rnm > rnm.log 2>&1 \
        || { tail -20 rnm.log; exit 1; }
    VERILATOR_SOLVER="$Z3 --in" rnm/Vt | grep "RESULT" | tee rnm_run.log
    grep -q "RESULT ok" rnm_run.log || { echo "uvm tests: randomize with a null rand member FAILED"; exit 1; }
else
    echo "uvm tests: no z3 - randomize with a null rand member skipped"
fi
python3 "$OCV/uvm/test/t_uvm2board.py" > u2b.log 2>&1 || { cat u2b.log; echo "uvm tests: uvm2board FAILED"; exit 1; }
grep "uvm2board tests" u2b.log
python3 "$OCV/uvm/test/t_uvm2board_own.py" > u2bo.log 2>&1 || { cat u2bo.log; echo "uvm tests: uvm2board (own agents) FAILED"; exit 1; }
grep "own-agent tests" u2bo.log
python3 "$OCV/uvm/test/t_tbparse.py" > tbp.log 2>&1 || { cat tbp.log; echo "uvm tests: tbparse FAILED"; exit 1; }
grep "tbparse tests" tbp.log
# the "fast" processor model against "iss", retirement by retirement (models/cpu/t_fast.c)
cc -std=c99 -O2 -I"$OCV/models/cpu" -I"$OCV/models/cpu/iss" "$OCV/models/cpu/t_fast.c" "$OCV/models/cpu/cpu_model.c" \
    "$OCV/models/cpu/iss/rv32_iss.c" -o t_fast
for p in dhrystone21 hello random_s1 writes; do ./t_fast "$OCV/examples/scr1/programs/$p.hex" > tfast.log || { cat tfast.log; echo "uvm tests: fast model FAILED"; exit 1; }; done
echo "fast model: identical to iss"
# the "jit" model (AArch64 code): under qemu-aarch64 (tools/get_qemu.sh) with an aarch64 cross compiler
QEMU=$OCV/build/qemu/qemu-aarch64
if [ -x "$QEMU" ] && command -v aarch64-linux-gnu-gcc > /dev/null; then
    aarch64-linux-gnu-gcc -std=c99 -O2 -static -I"$OCV/models/cpu" -I"$OCV/models/cpu/iss" "$OCV/models/cpu/t_fast.c" \
        "$OCV/models/cpu/cpu_model.c" "$OCV/models/cpu/iss/rv32_iss.c" -o t_fast_a64
    for p in "$OCV/models/cpu/jitcheck.hex" "$OCV/examples/scr1/programs/"{dhrystone21,hello,random_s1,writes}.hex; do
        "$QEMU" -cpu cortex-a72 ./t_fast_a64 "$p" 50000000 jit > tjit.log || { cat tjit.log; echo "uvm tests: jit model FAILED"; exit 1; }
    done
    echo "jit model: identical to iss (qemu-aarch64)"
else
    echo "jit model: SKIPPED (no build/qemu/qemu-aarch64 or aarch64-linux-gnu-gcc)"
fi
bash "$OCV/uvm/test/t_board_ref.sh" > bref.log 2>&1 || { cat bref.log; echo "uvm tests: board_ref layout FAILED"; exit 1; }
tail -1 bref.log
python3 "$OCV/uvm/test/t_tbwave.py" "$V" "$OUT/tbwave" > tbw.log 2>&1 || { cat tbw.log; echo "uvm tests: tbwave FAILED"; exit 1; }
grep "tbwave tests" tbw.log
echo "uvm tests: PASS"
