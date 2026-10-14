#!/usr/bin/env bash
# pc_set.sh - the PC half of every board measurement (tools/measure.sh): the same tests, the same programs, on
# this PC as a verifier would run them without the board (Verilator). One results file, build/pc_set/results.txt.
#
#   tools/pc_set.sh            (LONG=1 also core-v-verif's plain UVM run of coremark: about 40 minutes)
#
# Rows (all checked, every instruction / transaction compared as on the board):
#   cores (hw/cpu, PC reference tb_pc): 8 generated programs in one process (as board_bench.sh: seed 1), the
#     same programs on all cores at once (baseline_pc.sh farm: throughput), and each benchmark program;
#   UVM testbenches as written (uvm_v ... pc): scr1 r1..r3, mac16 / sha256 N as on the board;
#   core-v-verif CV32E40P: the plain UVM testbench (vlt.sh) and its board form with the FPGA in Verilator (host).
set -uo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
B=$OCV/build/pc_set; mkdir -p "$B"
RES=$B/results.txt
P=$OCV/build/board_set/progs
CVP=$OCV/examples/cv32e40p/build/prog
export PATH="$OCV/build/verilator/install/bin:$PATH"
{ echo "# pc_set $(date), $(lscpu | sed -n 's/^Model name: *//p'), $(nproc) CPUs"; } > "$RES"
t() {   # label, command...: one line with the wall time and the verdict
    local l=$1; shift
    local s e; s=$(date +%s.%N); "$@" > "$B/last.log" 2>&1; local rc=$?; e=$(date +%s.%N)
    { echo "### $l (exit $rc): $*"; cat "$B/last.log"; } >> "$B/full.log"
    printf '%-46s %9.2f s  %s\n' "$l" "$(python3 -c "print($e - $s)")" \
        "$(grep -E -m2 "PASS|FAIL|MISMATCH|UVM_ERROR :|\[SB\]|ERRATUM|SIMULATION" "$B/last.log" | tr '\n' ' ' | cut -c1-120)" | tee -a "$RES"
}

# cores
for c in cv32e40p scr1 cva6; do
    OUT=$OCV/build/baseline/$c "$OCV/hw/cpu/run.sh" "$OCV/examples/$c/$c.bind" pc gen:directed -- --batches 1 > /dev/null 2>&1
    TB=$OCV/build/baseline/$c/pc/obj/tb_pc
    t "$c 8 programs, 1 process (P-core)" taskset -c 1 "$TB" --model-opt gen=directed --batches 8 --reset-each-batch --max-cycles 400000000
    case $c in scr1) progs="$OCV/examples/scr1/programs/hello.hex $OCV/examples/scr1/programs/dhrystone21.hex $P/r1.hex $P/r2.hex $P/r3.hex" ;;
               *) progs="$CVP/hello-world.hex $CVP/dhrystone.hex $CVP/coremark.hex" ;; esac
    for p in $progs; do t "$c $(basename "$p"), 1 process" taskset -c 1 "$TB" --model-opt program="$p"; done
    FARMS="1 22" THREADS="" "$OCV/tools/baseline_pc.sh" "$OCV/examples/$c/$c.bind" 8 | grep -E "farm" | sed "s/^/$c /" | tee -a "$RES"
done

# UVM testbenches as written
"$OCV/examples/scr1/uvm_v/run.sh" pc > "$B/build_scr1_v.log" 2>&1
for r in r1 r2 r3; do
    t "scr1 UVM $r (Verilator, as written)" bash -c "cd $OCV/examples/scr1/build/uvm/scr1_v_pc && ./tb_top +UVM_TESTNAME=prog_test +PROG=$P/$r.hex +UVM_NO_RELNOTES"
done
for x in "mac16 rand_test 20000 200000" "sha256 sha_test 10000 100000"; do
    read -r n tst n1 n2 <<< "$x"
    "$OCV/examples/$n/uvm_v/run.sh" pc > "$B/build_${n}_v.log" 2>&1
    for k in $n1 $n2; do
        t "$n UVM N=$k (Verilator, as written)" bash -c "cd $OCV/examples/$n/build/uvm/${n}_v_pc && ./tb_top +UVM_TESTNAME=$tst +N=$k +UVM_NO_RELNOTES"
    done
done

# core-v-verif CV32E40P: plain UVM, and its board form with the FPGA simulated
"$OCV/examples/cv32e40p/vlt.sh" build > "$B/build_cvv.log" 2>&1
for p in hello-world dhrystone $([ "${LONG:-0}" = 1 ] && echo coremark); do
    t "core-v-verif plain UVM $p" "$OCV/examples/cv32e40p/vlt.sh" run +firmware="$CVP/$p.hex"
done
OCV_UVM_GEN="--dma 128" "$OCV/examples/cv32e40p/uvm_fast/run.sh" host > "$B/build_uvm_fast.log" 2>&1
for p in hello-world dhrystone coremark; do
    t "core-v-verif board form on PC (FPGA in Verilator) $p" "$OCV/examples/cv32e40p/uvm_fast/run.sh" test +firmware="$CVP/$p.hex"
done
echo "pc_set: $RES"
