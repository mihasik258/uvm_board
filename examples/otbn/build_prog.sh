#!/usr/bin/env bash
# build_prog.sh - OpenTitan's standalone ML-DSA-87 OTBN app (sw/otbn/crypto/mldsa87/run_mldsa87.s with the
# mldsa87 library, as its BUILD file links it) with OpenTitan's OTBN assembler and linker; then the test's load
# file and the symbols (otbn_prog.py): build/otbn/prog/run_mldsa87.{elf,load,sym}
# Needs build/otbn_venv (tools/otbn_venv.sh) and the xpack RISC-V toolchain in ext/ (its binutils under otbn_as.py).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
X=$(ls -d "$OCV"/ext/xpack-riscv-none-elf-gcc-*/bin | tail -1)
P=$OCV/build/otbn_venv/bin/python
OT=$OCV/ext/opentitan; C=$OT/sw/otbn/crypto; M=$C/mldsa87; U=$OT/hw/ip/otbn/util
OUT=$OCV/build/otbn/prog; mkdir -p "$OUT/obj"
SRCS=("$M/run_mldsa87.s" "$M"/mldsa87_{arith,encoding,expand,gadgets,ntt,ops,rounding,sample,utils}.s
      "$C/mai_gadgets.s" "$C/xof.s" "$M"/mldsa87_{keygen,mem,sign,verify}.s)
OBJS=()
for f in "${SRCS[@]}"; do
    o=$OUT/obj/$(basename "$f" .s).o
    RV32_TOOL_AS=$X/riscv-none-elf-as "$P" "$U/otbn_as.py" -I "$M" -I "$C" -o "$o" "$f"
    OBJS+=("$o")
done
RV32_TOOL_LD=$X/riscv-none-elf-ld "$P" "$U/otbn_ld.py" -o "$OUT/run_mldsa87.elf" "${OBJS[@]}"
"$P" "$HERE/otbn_prog.py" "$OUT/run_mldsa87.elf" "$OUT/run_mldsa87"
