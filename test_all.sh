#!/usr/bin/env bash
# test_all.sh - full OCV regression, no hardware needed:
#   1. register contract (SV package vs C header)
#   2. hardware core testbench (hub + source + sinks) over several geometries
#   3. software core unit tests
#   4. generator: invalid descriptors are rejected
#   5. mac16 co-simulation: plain, throttled with AXI jitter, reset per batch
#   6. mac16 fault-injection campaign
#   7. SCR1 as a DUT: hello, dhrystone (self-timed) and a random program, with lossless drains
#   8. SCR1 fault-injection campaign on the random program (sequential and --overlap, must agree)
#   9. memsum, a reactive DUT (bus master; the model answers its reads during the run): co-simulation
#      plain, with throttles and AXI jitter, with injected answer latency; its fault campaign
#  10. (BRIDGE=1, needs Vivado) VD100 bridge: real SmartConnect in front of mac16, PS program over DPI
#  11. UVM layer: OCV's in-process constraint solver (Verilator from tools/get_verilator.sh), the
#      generator's --uvm output; with VIVADO_SETTINGS also the mac16 UVM test in simulation and
#      through the board's code path (the FPGA image simulated); the SCR1 UVM test translated by
#      uvm2board.py on the simulated board (engine A); the verifier-style testbenches (uvm_v) of SCR1
#      and mac16 without a description file, in their board form
# FAST=1 skips steps 6 and 8.
set -uo pipefail
OCV=$(cd "$(dirname "$0")" && pwd)
B=$OCV/build/test_all
mkdir -p "$B"
fails=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { if [ "$1" -eq 0 ]; then echo "  -> ok"; else echo "  -> FAILED"; fails=$((fails+1)); fi; }

step "1. register contract"
python3 "$OCV/hw/scripts/check_regs.py"; ok $?

step "2. hardware core testbench"
"$OCV/hw/scripts/sim.sh" 2>&1 | grep -E 'TB_OCV_HUB|SIM:'; ok "${PIPESTATUS[0]}"

step "3. software core unit tests"
CF=(-std=c99 -O2 -Wall -Wextra -Werror -I"$OCV/sw/include")
cc "${CF[@]}" "$OCV/sw/test/test_ocv.c" "$OCV/sw/lib/ocv.c" -o "$B/test_ocv" && "$B/test_ocv"; ok $?

step "4. generator rejects invalid descriptors"
gen_bad=0
while IFS='|' read -r what patch; do
    python3 - "$OCV/examples/mac16/mac16.json" "$B/bad.json" "$patch" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1])); exec(sys.argv[3]); json.dump(d, open(sys.argv[2], "w"))
EOF
    if python3 "$OCV/gen/ocv_gen.py" "$B/bad.json" -o "$B/bad" >/dev/null 2>&1; then
        echo "  accepted but should not: $what"; gen_bad=$((gen_bad+1))
    fi
done <<'LIST'
duplicate port|d["channels"][2]["fields"][0]["port"]="m_acc"
depth not a power of two|d["channels"][0]["depth"]=1000
ulp width mismatch|d["channels"][1]["fields"][0]["compare"]={"ulp":1,"fp":"fp32"}
unknown key|d["channels"][0]["colour"]="red"
compare rule on stimulus|d["channels"][0]["fields"][0]["compare"]="ignore"
ready on a monitor|d["channels"][2]["ready"]="dbg_ready"
bad identifier|d["channels"][1]["name"]="1results"
mask wider than field|d["channels"][1]["fields"][1]["compare"]={"mask":"0x1FFFF"}
field wider than 64|d["channels"][1]["fields"][0]["width"]=65
stream on a sink|d["channels"][1]["stream"]=True
freeze without ready|d["channels"][0].pop("ready"); d["channels"][0]["freeze_when_starved"]=True
squash on a source|d["channels"][0]["squash"]=True
squash with a tolerance rule|d["channels"][2]["lossless"]=True; d["channels"][2]["squash"]=True; d["channels"][2]["fields"][0]["compare"]={"abs":1}
squash on a monitor that may lose records|d["channels"][2]["squash"]=True
LIST
echo "  14 invalid descriptors, $gen_bad accepted"; ok $gen_bad

step "5. mac16 co-simulation"
M=$OCV/examples/mac16
run_cosim() { OUT=$B/cosim "$OCV/sim/cosim.sh" "$M/mac16.json" "$M/mac16_model.c" "$M/mac16.sv" -- --quiet "$@"; }
run_cosim --info > "$B/info_mac16.log"; ok $?; grep "^INFO" "$B/info_mac16.log"
run_cosim --batches 8; ok $?
run_cosim --batches 8 --throttle-in 100 --throttle-out 150 --axi-jitter 3 --seed 7; ok $?
run_cosim --batches 4 --reset-each-batch --batch 300 --seed 11; ok $?
run_cosim --batches 8 --overlap --throttle-out 128 --seed 3; ok $?          # model in its own thread (forced)

if [ "${FAST:-0}" != 1 ]; then
    step "6. mac16 fault-injection campaign"
    WORK=$B/faults "$M/faults.sh"; ok $?
fi

step "7. SCR1 co-simulation (program as stimulus, lossless retire monitor)"
S1=$OCV/examples/scr1
"$S1/gen_random_prog.py" --seed 1 -o "$B/random_s1.hex" >/dev/null
OUT=$B/cosim_scr1 "$S1/run_cosim.sh" "$B/random_s1.hex" -- --info > "$B/info_scr1.log"; ok $?
grep "^INFO" "$B/info_scr1.log"
for p in "$S1/programs/hello.hex" "$S1/programs/dhrystone21.hex" "$B/random_s1.hex"; do
    OUT=$B/cosim_scr1 "$S1/run_cosim.sh" "$p" -- --quiet 2>&1 | grep -E '^(OCV|FAIL|MISMATCH|WARNING)'
    ok "${PIPESTATUS[0]}"
done
# squash: the retire stream fused in windows of 256, signatures compared
OUT=$B/cosim_scr1 "$S1/run_cosim.sh" "$B/random_s1.hex" -- --quiet --squash 256 2>&1 | grep -E '^(OCV|FAIL|MISMATCH|REPLAY)'
ok "${PIPESTATUS[0]}"
OUT=$B/cosim_scr1 "$S1/run_cosim.sh" gen:directed -- --batches 2 --reset-each-batch --model-opt ops=1500 \
    --quiet 2>&1 | grep -E '^(OCV|FAIL|MISMATCH|WARNING|SCR1COV total)'; ok "${PIPESTATUS[0]}"   # programs made on the PS
if [ -f "$OCV/build/spike/host/build/libriscv.a" ]; then      # Spike as the reference model (tools/get_spike.sh)
    for p in "$S1/programs/hello.hex" "$S1/programs/dhrystone21.hex"; do
        ( source "$OCV/models/cpu/spike.env"; export CPU_SRCS CPU_CFLAGS MODEL_CXXFLAGS MODEL_LIBS
          OUT=$B/cosim_scr1_spike "$S1/run_cosim.sh" "$p" -- --quiet --model-opt cpu=spike 2>&1 ) \
            | grep -E '^(OCV|FAIL|MISMATCH|scr1 model: reference)'; ok "${PIPESTATUS[0]}"
    done
    # riscv-tests ISA suite: traps, CSRs, mret - checked instruction by instruction against Spike
    OUT=$B/isa "$S1/run_isa.sh" spike 2>&1 | grep -E '^(ISA|.* FAIL)'; ok "${PIPESTATUS[0]}"
else
    echo "  (Spike not built: tools/get_spike.sh - skipping cpu=spike)"
fi
OUT=$B/cosim_scr1 "$S1/run_cosim.sh" "$S1/programs/dhrystone21.hex" -- --quiet --no-overlap 2>&1 \
    | grep -E '^(OCV|FAIL|MISMATCH|WARNING)'; ok "${PIPESTATUS[0]}"

if [ "${FAST:-0}" != 1 ]; then
    step "8. SCR1 fault-injection campaign (random program)"
    RUN_EXTRA=--no-overlap WORK=$B/faults_scr1 "$S1/faults.sh" "$B/random_s1.hex" | tee "$B/faults_scr1.log" | grep -E '^[a-z]|faults:'
    esc=$(grep -cE ' (ESCAPE|ERR)' "$B/faults_scr1.log"); echo "  escapes/errors: $esc"; ok "$esc"
    echo "  the same campaign with the model in its own thread (--overlap):"
    RUN_EXTRA=--overlap WORK=$B/faults_scr1_ovl "$S1/faults.sh" "$B/random_s1.hex" > "$B/faults_scr1_ovl.log"
    # same faults found at the same instructions as in sequential mode
    diff <(grep -E '^[a-z]' "$B/faults_scr1.log") <(grep -E '^[a-z]' "$B/faults_scr1_ovl.log") \
        && echo "  identical to the sequential campaign"; ok $?
    echo "  the same campaign with the retire stream squashed (--squash 256, replay locates the record):"
    RUN_EXTRA="--no-overlap --squash 256" WORK=$B/faults_scr1_sq "$S1/faults.sh" "$B/random_s1.hex" > "$B/faults_scr1_sq.log"
    diff <(grep -E '^[a-z]' "$B/faults_scr1.log") <(grep -E '^[a-z]' "$B/faults_scr1_sq.log") \
        && echo "  identical to the unsquashed campaign"; ok $?
fi

step "8a. DMA rings: the same DUTs with their outputs written into PS memory (--dma 128)"
# the board's fast path: no bus reads per record. Random AXI handshakes and late responses.
DMA_F="--dma 128"
OUT=$B/cosim_mac16_dma OCV_GEN_FLAGS=$DMA_F "$OCV/sim/cosim.sh" "$M/mac16.json" "$M/mac16_model.c" "$M/mac16.sv" -- \
    --quiet --batches 8 --throttle-out 100 --dma-ready 60 2>&1 | grep -E '^(OCV|FAIL|MISMATCH|COSIM: FAIL)'; ok "${PIPESTATUS[0]}"
OUT=$B/cosim_scr1_dma OCV_GEN_FLAGS=$DMA_F "$S1/run_cosim.sh" "$S1/programs/dhrystone21.hex" -- --quiet --dma-ready 70 \
    2>&1 | grep -E '^(OCV|FAIL|MISMATCH|COSIM: FAIL)'; ok "${PIPESTATUS[0]}"
OUT=$B/cosim_scr1_dma COSIM_PREBUILT=1 "$S1/run_cosim.sh" "$B/random_s1.hex" -- --quiet --squash 256 \
    2>&1 | grep -E '^(OCV|FAIL|MISMATCH|COSIM: FAIL)'; ok "${PIPESTATUS[0]}"
OUT=$B/cosim_memsum_dma OCV_GEN_FLAGS=$DMA_F "$OCV/sim/cosim.sh" "$OCV/examples/memsum/memsum.json" \
    "$OCV/examples/memsum/memsum_model.c" "$OCV/examples/memsum/memsum.sv" -- --quiet --batches 3 --dma-ready 50 \
    2>&1 | grep -E '^(OCV|FAIL|MISMATCH|COSIM: FAIL)'; ok "${PIPESTATUS[0]}"
if [ "${FAST:-0}" != 1 ]; then
    echo "  SCR1 fault campaign with the retire stream over DMA: same detections as over the bus"
    OCV_GEN_FLAGS=$DMA_F WORK=$B/faults_scr1_dma "$S1/faults.sh" "$B/random_s1.hex" > "$B/faults_scr1_dma.log"
    diff <(grep -E '^[a-z]' "$B/faults_scr1.log") <(grep -E '^[a-z]' "$B/faults_scr1_dma.log") \
        && echo "  identical"; ok $?
fi

step "9. memsum: reactive DUT (the model answers its memory reads during the run)"
MS=$OCV/examples/memsum
run_ms() { OUT=$B/cosim_memsum "$OCV/sim/cosim.sh" "$MS/memsum.json" "$MS/memsum_model.c" "$MS/memsum.sv" -- --quiet "$@" \
             2>&1 | grep -E '^(OCV|FAIL|MISMATCH)'; return "${PIPESTATUS[0]}"; }
run_ms --batches 4; ok $?                                   # wait = len: the reaction is hidden from the DUT
run_ms --batches 3 --throttle-in 100 --throttle-out 150 --axi-jitter 3 --seed 9; ok $?
run_ms --batches 3 --throttle-stream 128 --model-opt check_wait=0 --seed 3; ok $?   # answer latency injected
if [ "${FAST:-0}" != 1 ]; then
    WORK=$B/faults_memsum "$MS/faults.sh" | grep -E '^[a-z]|faults:'; ok "${PIPESTATUS[0]}"
fi

if [ "${BRIDGE:-0}" = 1 ]; then
    step "10. VD100 bridge: real SmartConnect + mac16, PS program over DPI (Vivado)"
    BR=$OCV/platforms/vd100/sim/run_bridge_sim.sh
    OUT=$B/bridge "$BR" "$M/mac16.json" "$M/mac16_model.c" "$M/mac16.sv" | grep -E '^(INFO|BRIDGE)'
    ok "${PIPESTATUS[0]}"
    OUT=$B/bridge "$BR" "$M/mac16.json" "$M/mac16_model.c" "$M/mac16.sv" -- --batches 2 --throttle-out 128 \
        | grep -E '^(OCV|BRIDGE)'
    ok "${PIPESTATUS[0]}"
fi

step "10a. CVA6 (hw/cpu wrapper, PC reference): generated programs, and the directed test of erratum #3175"
if [ -d "$OCV/ext/cva6" ]; then
    for sd in 1 2 4; do                                  # 2: an interrupt within the #3175 window; 4: mstatus.MPP
        OUT=$B/cpu_cva6 "$OCV/hw/cpu/run.sh" "$OCV/examples/cva6/cva6.bind" pc gen:directed -- --batches 2 \
            --reset-each-batch --max-cycles 20000000 --model-opt seed=$sd 2>&1 | grep -E "^tb_pc: (cva6|FAIL)"
        ok "${PIPESTATUS[0]}"
    done
    "$OCV/examples/cva6/repro/run.sh" mie_disable > "$B/repro_mie.log" 2>&1
    grep -E "tb_pc: cva6 PASS" "$B/repro_mie.log" && grep -q "ERRATUM: 7 " "$OCV/build/repro/cva6/mie_disable.log"; ok $?
else
    echo "  (no ext/cva6: tools/get_cores.sh)"
fi

step "11. UVM layer: in-process constraint solver, generated agents, one testbench in simulation and board path"
OUT=$B/uvm_test "$OCV/uvm/test/run_tests.sh" | grep -E '^(RESULT|uvm tests)'; ok "${PIPESTATUS[0]}"
python3 "$OCV/gen/ocv_gen.py" --uvm "$M/mac16.json" -o "$B/uvm_gen" | grep -q "mac16_ocv_uvm_pkg.sv"; ok $?
# the verifier's own testbenches (examples/*/uvm_v: own interface, agents, top - no description file),
# read by uvm2board.py/tbparse.py and run in their board form, FPGA image simulated:
# SCR1 - scoreboard -> engine A, squashed retire windows; mac16 - scoreboard as is, all transport
OVL=$B/uvm_v_scr1_overlay OUT=$B/uvm_v_scr1_host timeout 3000 "$S1/uvm_v/run.sh" host > "$B/uvm_v_scr1_build.log" 2>&1 && \
    timeout 300 "$B/uvm_v_scr1_host/tb_top_board" +PROG="$B/random_s1.hex" +UVM_TESTNAME=prog_test +OCV_SQUASH=256 \
        +UVM_NO_RELNOTES > "$B/uvm_v_scr1.log" 2>&1
grep -E '\[SB\] .*compared|retire=' "$B/uvm_v_scr1.log" | sed 's/.*\(\[SB\]\|\[OCV\]\)/  \1/' | cut -c1-110
python3 - "$B/uvm_v_scr1.log" <<'EOF2'
import re, sys
t = open(sys.argv[1]).read()
c = re.search(r"\[SB\] (\d+) instructions compared, 0 errors\s*$", t, re.M)
r = re.search(r"retire=(\d+) records", t)
sys.exit(0 if c and r and int(r.group(1)) * 100 < int(c.group(1)) else 1)   # passed, and squashed
EOF2
ok $?
OVL=$B/uvm_v_mac16_overlay OUT=$B/uvm_v_mac16_host timeout 3000 "$M/uvm_v/run.sh" host > "$B/uvm_v_mac16_build.log" 2>&1 && \
    timeout 300 "$B/uvm_v_mac16_host/tb_top_board" +UVM_TESTNAME=rand_test +N=2000 +UVM_NO_RELNOTES > "$B/uvm_v_mac16.log" 2>&1
grep -E '\[SB\] .*compared' "$B/uvm_v_mac16.log" | sed 's/.*\[SB\]/  [SB]/'
grep -qE '\[SB\] 2000 results, 2000 products compared, 0 errors' "$B/uvm_v_mac16.log"; ok $?
if [ -n "${VIVADO_SETTINGS:-}" ]; then
    for mode in sim pcboard; do
        OUT=$B/uvm_$mode RTL=$M/mac16.sv "$OCV/uvm/run_uvm.sh" $mode "$M/mac16.json" tb_top \
            "$M/uvm/mac16_tb_pkg.sv" "$M/uvm/tb_top.sv" -- +N=2000 | grep -E '\[SB\] |UVM_RESULT'
        ok "${PIPESTATUS[0]}"
    done
else
    echo "  (VIVADO_SETTINGS not set - skipping the xsim runs of the mac16 UVM test)"
fi

printf '\nTEST_ALL: %s\n' "$([ $fails -eq 0 ] && echo PASS || echo "$fails FAILED")"
[ $fails -eq 0 ]
