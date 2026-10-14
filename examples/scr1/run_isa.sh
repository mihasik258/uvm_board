#!/usr/bin/env bash
# run_isa.sh - the riscv-tests ISA suite (SCR1 build: rv32ui/um/uc/mi) through OCV: every test is
# loaded as the program, every instruction the core retires - including traps, CSR accesses and
# returns from handlers - is compared with the reference processor model.
#
#   examples/scr1/run_isa.sh [cpu] [test ...]        cpu: spike (default) | iss
#
# RISCV_TESTS: riscv-tests checkout (default: the scr1 dependency).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
SCR1=$(cd "${SCR1:-$OCV/ext/scr1}" && pwd)
CPU=${1:-spike}; shift || true
OUT=${OUT:-$HERE/build/isa}
RT=${RISCV_TESTS:-$SCR1/dependencies/riscv-tests}
[ -d "$RT/isa" ] || { echo "run_isa.sh: riscv-tests not found (set RISCV_TESTS)"; exit 1; }

mkdir -p "$OUT/tests"
make -s -C "$SCR1/sim/tests/riscv_isa" bld_dir="$OUT/tests" inc_dir="$SCR1/sim/tests/common" ARCH=IMC \
    RISCV_TESTS="$RT/" RISCV_GCC=riscv64-unknown-elf-gcc RISCV_OBJCOPY="riscv64-unknown-elf-objcopy -O verilog" \
    RISCV_OBJDUMP=riscv64-unknown-elf-objdump > "$OUT/build_tests.log" 2>&1
if [ "$CPU" = spike ]; then
    # shellcheck disable=SC1091
    source "$OCV/models/cpu/spike.env"; export CPU_SRCS CPU_CFLAGS MODEL_CXXFLAGS MODEL_LIBS
fi
unset COSIM_PREBUILT
tests=("$@"); [ ${#tests[@]} -eq 0 ] && mapfile -t tests < <(ls "$OUT/tests"/*.hex | xargs -n1 basename | sed 's/\.hex$//')
pass=0; fail=0
for t in "${tests[@]}"; do
    OUT=$OUT/cosim_$CPU "$HERE/run_cosim.sh" "$OUT/tests/$t.hex" -- --quiet --model-opt "cpu=$CPU" \
        > "$OUT/$t.$CPU.log" 2>&1
    rc=$?
    export COSIM_PREBUILT=1                       # built by the first test: the rest reuse it
    if [ $rc -eq 0 ]; then
        pass=$((pass+1)); printf '%-10s PASS  %s\n' "$t" "$(grep -oE 'retire=[0-9]+' "$OUT/$t.$CPU.log")"
    else
        fail=$((fail+1)); printf '%-10s FAIL  %s\n' "$t" "$(grep -m1 -E '^(MISMATCH|FAIL)' "$OUT/$t.$CPU.log")"
    fi
done
echo "ISA ($CPU): $pass passed, $fail failed of $((pass+fail))"
[ $fail -eq 0 ]
