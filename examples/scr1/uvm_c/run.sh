#!/usr/bin/env bash
# run.sh - the SCR1 UVM testbench written by the OCV contract (scr1_c_pkg.sv): nothing but the testbench and the RTL -
# uvm/ocv_contract.py derives the DUT's description and the record packing from its classes.
#
#   examples/scr1/uvm_c/run.sh pc        simulation: testbench + SCR1 RTL in one Verilator model
#   examples/scr1/uvm_c/run.sh host      the board build, the FPGA image simulated inside the program (no board)
#   examples/scr1/uvm_c/run.sh aarch64   the board build for the VD100's A72
# then: $OUT/tb_top +PROG=<program.hex> [+OCV_BASE=0x80000000 on the board]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../../.." && pwd)
SCR1=$(cd "${SCR1:-$OCV/ext/scr1}" && pwd)
S=${SCR1_SRC:-$SCR1/src}                # SCR1_SRC: another copy (fault injection)
MODE=${1:-pc}
OUT=$(realpath -m "${OUT:-$OCV/build/uvm/scr1_c_$MODE}")
TB=("$HERE/../uvm_v/scr1_if.sv" "$HERE/scr1_c_pkg.sv" "$HERE/tb_top.sv")
python3 "$OCV/uvm/ocv_contract.py" "${TB[@]}" --top tb_top -o "$OUT/contract" ${OCV_UVM_GEN:+--gen-flags "$OCV_UVM_GEN"}
{ sed -e '$a\' "$S/core.files"; sed -e '$a\' "$S/axi_top.files"
  printf '%s\n' core/cache/scr1_icache.sv core/cache/scr1_dcache.sv core/cache/scr1_cache_wrapper.sv; } \
  | sed "s#^#$S/#" | grep -v '^\s*$' > "$OUT/rtl.f"
RTL="$(tr '\n' ' ' < "$OUT/rtl.f") $HERE/../scr1_ocv_axi_mem.sv $HERE/../scr1_ocv_dut.sv"
export RTL
export RTL_DEFINES="-DSCR1_CFG_RV32IMC_MAX -DSCR1_RVFI_EN -I$S/includes"
export TB_C="$HERE/../uvm/scr1_ref_dpi.c $OCV/models/cpu/cpu_model.c $OCV/models/cpu/iss/rv32_iss.c"
export TB_CFLAGS="-I$OCV/uvm -I$OCV/models/cpu -I$OCV/models/cpu/iss"
OUT=$OUT OCV_CONTRACT=$OUT/contract exec "$OCV/uvm/build_board.sh" "$MODE" "$OUT/contract/desc.json" tb_top "${TB[@]}"
