#!/usr/bin/env bash
# faults.sh - does the generated test find bugs in CV32E40P? Each fault is one change in a copy of the
# core's RTL; the test (cv32e40p.bind through hw/cpu/run.sh, directed generation, N programs) must fail
# on every one, and pass on the unchanged core.
#
#   examples/cv32e40p/gen/faults.sh [programs]      (default 4)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
CV=$(cd "${CV32E40P:-$OCV/ext/cv32e40p}" && pwd)
N=${1:-4}
W=$HERE/../build/faults
mkdir -p "$W"

# name ~ file (under rtl/) ~ text ~ replacement [~ last: change the last occurrence, not the first]
FAULTS=(
  "sra_logical~cv32e40p_alu.sv~assign shift_arithmetic = (operator_i == ALU_SRA)  ||~assign shift_arithmetic = 1'b0 ||"
  "lh_sign_bit~cv32e40p_load_store_unit.sv~else rdata_h_ext = {{16{resp_rdata[31]}}, resp_rdata[31:16]};~else rdata_h_ext = {{16{resp_rdata[30]}}, resp_rdata[31:16]};"
  "cmp_sign_b~cv32e40p_alu.sv~{operand_b_i[8*i+7] & cmp_signed[i], operand_b_i[8*i+7:i*8]}~{operand_b_i[8*i+6] & cmp_signed[i], operand_b_i[8*i+7:i*8]}"
  "ecall_cause~cv32e40p_controller.sv~EXC_CAUSE_ECALL_UMODE : EXC_CAUSE_ECALL_MMODE}~EXC_CAUSE_ECALL_UMODE : EXC_CAUSE_BREAKPOINT}"
  "mepc_trap~cv32e40p_cs_registers.sv~mepc_n         = exception_pc;~mepc_n         = exception_pc + 32'd4;~last"
  "irq_ignore_mie~cv32e40p_int_controller.sv~assign global_irq_enable = m_ie_i;~assign global_irq_enable = 1'b1;"
  "irq_wrong_id~cv32e40p_int_controller.sv~irq_id_ctrl_o = 5'd30;~irq_id_ctrl_o = 5'd29;"
)

run() {   # $1 = core copy, $2 = build dir
    (CV32E40P=$1 OUT=$2 "$OCV/hw/cpu/run.sh" "$HERE/../cv32e40p.bind" cosim gen:directed -- --batches "$N" \
        --reset-each-batch 2>&1 || true) \
        | grep -E "PASS|FAIL|MISMATCH" | head -2 || true
}

echo "== unchanged"
run "$CV" "$W/clean"
for f in "${FAULTS[@]}"; do
    IFS='~' read -r name file from to where <<< "$f"
    C=$W/src_$name
    rm -rf "$C"; mkdir -p "$C"; cp -r "$CV/rtl" "$CV/bhv" "$CV/cv32e40p_manifest.flist" "$C/"
    python3 - "$C/rtl/$file" "$from" "$to" "${where:-first}" <<'EOF'
import sys
p, a, b, where = sys.argv[1:5]
s = open(p).read()
if a not in s: sys.exit(f"faults.sh: '{a}' not found in {p}")
i = s.rfind(a) if where == "last" else s.find(a)
open(p, 'w').write(s[:i] + b + s[i + len(a):])
EOF
    echo "== $name"
    run "$C" "$W/build_$name"
done
