#!/usr/bin/env bash
# files.sh - the RTL of the OTBN+KMAC DUT (otbn_kmac_ocv.core) as FuseSoC resolves OpenTitan's cores: a Verilator
# argument file (files, include directories, OpenTitan's lint waivers) in build/otbn/rtl/<target>/ - OpenTitan's
# files only: the wrapper otbn_kmac_ocv.sv goes with them (FuseSoC's copy of it is left out)
#
#   examples/otbn/files.sh [default|fpga]      (default: simulation's generic primitives; fpga: Xilinx's)
# Needs build/otbn_venv (tools/otbn_venv.sh: FuseSoC and OpenTitan's Python packages).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
T=${1:-default}
OUT=$OCV/build/otbn/rtl/$T
mkdir -p "$OUT"
cd "$OUT"
PATH=$OCV/build/otbn_venv/bin:$PATH fusesoc --cores-root="$OCV/ext/opentitan" --cores-root="$HERE" \
    run --setup --target="$T" --build-root="$OUT/fs" ocv:dut:otbn_kmac_ocv > fusesoc.log 2>&1 || { tail -20 fusesoc.log; exit 1; }
VC=$(ls "$OUT"/fs/*/*/ocv_dut_otbn_kmac_ocv_0.1.vc)
# (paths in the argument file are the FuseSoC work directory's)
sed -e "s#^src/#$(dirname "$VC")/src/#; s#+incdir+src/#+incdir+$(dirname "$VC")/src/#; s#-I src/#-I$(dirname "$VC")/src/#; s#-Isrc/#-I$(dirname "$VC")/src/#" \
    -e '/\/otbn_kmac_ocv\.sv$/d' -e '/^--Mdir/d' -e '/^--top-module/d' -e '/^--lint-only/d' -e '/^--exe$/d' "$VC" > "$OUT/otbn_kmac_ocv.f"
echo "files.sh: $OUT/otbn_kmac_ocv.f ($(grep -c '\.sv$' "$OUT/otbn_kmac_ocv.f") SystemVerilog files)"
