#!/usr/bin/env bash
# make_bootbin.sh - build a bootable Versal BOOT.BIN for the COMBINED design WITHOUT PetaLinux.
# Combines our design PDI (PLM + our NoC/PS + SCR1 PL + PSM) with the APU subsystem
# (bl31 + u-boot) extracted from an existing working ALINX BOOT.BIN.
#
# WHY the ELF wrap: `bootgen -dump` emits ELF partitions as raw .bin, losing the core=a72-0
# handoff metadata -> A72 never starts -> no U-Boot/Linux. We wrap the dumped bl31/u-boot
# .bin back into minimal AArch64 ELFs (correct load/entry) so bootgen restores core=a72-0.
#
# Usage: make_bootbin.sh <our_design.pdi> <reference_BOOT.BIN> [out_BOOT.BIN]
#   reference_BOOT.BIN = a known-good ALINX BOOT.BIN to source the APU (bl31/u-boot) from.
set -euo pipefail
PDI="${1:?our design .pdi}"; REF="${2:?reference BOOT.BIN}"; OUT="${3:-BOOT_scr1.BIN}"
command -v bootgen >/dev/null || { echo "source Vivado settings64.sh (need bootgen)"; exit 1; }
PDI=$(realpath "$PDI"); REF=$(realpath "$REF"); OUT=$(realpath -m "$OUT")   # absolutize before cd
WD=$(mktemp -d); cp "$PDI" "$WD/our_design.pdi"; cp "$REF" "$WD/ref.BIN"; cd "$WD"

echo ">>> dumping APU partitions from reference BOOT.BIN"
bootgen -arch versal -dump ref.BIN >/dev/null 2>&1
# APU load/exec addrs are standard for Versal petalinux: raw@0x1000, bl31@0xfffe0000, u-boot@0x08000000
python3 - <<'PY'
import struct
def elf(binf,out,addr):
    d=open(binf,'rb').read(); EH=64;PH=56;off=EH+PH
    ident=b'\x7fELF'+bytes([2,1,1,0])+b'\x00'*8
    eh=ident+struct.pack('<HHIQQQIHHHHHH',2,0xB7,1,addr,EH,0,0,EH,PH,1,0,0,0)
    ph=struct.pack('<IIQQQQQQ',1,7,off,addr,addr,len(d),len(d),0x10000)
    open(out,'wb').write(eh+ph+d)
elf('apu_subsystem.1.0.bin','bl31.elf',0xfffe0000)
elf('apu_subsystem.2.0.bin','u-boot.elf',0x08000000)
print("wrapped bl31.elf + u-boot.elf")
PY
cat > scr1.bif <<BIF
all:
{
  image { {type=bootimage, file=our_design.pdi} }
  image
  {
    id=0x1c000000, name=apu_subsystem
    partition { type=raw, load=0x00001000, file=apu_subsystem.0.0.bin }
    partition { core=a72-0, exception_level=el-3, trustzone, file=bl31.elf }
    partition { core=a72-0, exception_level=el-2, file=u-boot.elf }
  }
}
BIF
echo ">>> bootgen"
bootgen -arch versal -image scr1.bif -w -o out.BIN | grep -Ei "success|error"
# sanity: APU must show core:a72-0 type:elf (handoff restored)
bootgen -arch versal -read out.BIN 2>/dev/null | grep -A4 "apu_subsystem" | grep -E "core: a72-0|type: elf" >/dev/null \
  && echo ">>> APU handoff metadata OK (core:a72-0/elf)" || echo ">>> WARNING: APU handoff metadata missing"
cp out.BIN "$OUT"; echo ">>> wrote $OUT ($(wc -c < out.BIN) B)"
