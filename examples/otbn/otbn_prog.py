#!/usr/bin/env python3
"""otbn_prog.py - an OTBN program (the ELF of OpenTitan's otbn_ld.py) as the OCV test loads it over the DUT's bus:
<out>.load - one "<bus address> <word>" line (hex) per 32-bit word of IMEM, then DMEM (the bus addresses of
otbn_kmac_ocv.sv: IMEM at 0x4000, DMEM at 0x8000), the words of the ELF's sections;
<out>.sym - one "<name> <DMEM byte offset>" line (hex) per DMEM symbol: where the program's buffers are, for the
test (inputs, outputs) and the model.

    build/otbn_venv/bin/python examples/otbn/otbn_prog.py <program.elf> <out>
"""
import os
import sys

OT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ext", "opentitan")
sys.path.insert(0, os.path.join(OT, "hw", "ip", "otbn", "util"))
sys.path.insert(0, OT)
from shared.elf import read_elf  # noqa: E402
from elftools.elf.elffile import ELFFile  # noqa: E402
from elftools.elf.sections import SymbolTableSection  # noqa: E402

IMEM_BUS, DMEM_BUS = 0x4000, 0x8000


def main():
    elf, out = sys.argv[1], sys.argv[2]
    imem, dmem = read_elf(elf)[:2]
    with open(out + ".load", "w") as f:
        for base, data in ((IMEM_BUS, imem), (DMEM_BUS, dmem)):
            data = data + b"\0" * (-len(data) % 4)
            for i in range(0, len(data), 4):
                f.write(f"{base + i:08x} {int.from_bytes(data[i:i + 4], 'little'):08x}\n")
    # DMEM's symbols: those of sections that are not executable (their values are DMEM offsets)
    syms = []
    with open(elf, "rb") as h:
        e = ELFFile(h)
        for st in e.iter_sections():
            if not isinstance(st, SymbolTableSection):
                continue
            for sym in st.iter_symbols():
                sh = sym["st_shndx"]
                if sym.name and isinstance(sh, int) and not e.get_section(sh)["sh_flags"] & 4:   # (SHF_EXECINSTR)
                    syms.append((sym["st_value"], sym.name))
    with open(out + ".sym", "w") as f:
        for v, name in sorted(set(syms)):
            f.write(f"{name} {v:x}\n")
    print(f"otbn_prog: {out}.load (IMEM {len(imem)} bytes, DMEM {len(dmem)} bytes), {out}.sym")


if __name__ == "__main__":
    main()
