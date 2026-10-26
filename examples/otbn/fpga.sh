#!/usr/bin/env bash
# fpga.sh - the VD100 FPGA image of the OTBN+KMAC DUT for its UVM test (examples/otbn/uvm_c): OpenTitan's RTL with
# Xilinx primitives (files.sh fpga), the hub as the test's runner drives it (as run.sh: --dma 128); Vivado.
#
#   examples/otbn/fpga.sh                 the DUT as it is
#   OCV_OTBN_FAULT_BITS=22 examples/otbn/fpga.sh   with the injected bug (examples/otbn/fault/), OUT ..._fault22
#   OCV_STOP=synth examples/otbn/fpga.sh  only synthesis: does it fit (reports/utilization)
# The test's description is run.sh's (build/uvm/otbn_c_aarch64/contract/desc.json: run.sh aarch64 first).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
DESC=$OCV/build/uvm/otbn_c_aarch64/contract/desc.json
[ -f "$DESC" ] || { echo "fpga.sh: no $DESC - run examples/otbn/uvm_c/run.sh aarch64 first"; exit 1; }
"$HERE/files.sh" fpga > /dev/null
F=$OCV/build/otbn/rtl/fpga/otbn_kmac_ocv.f
SV=(); INC=()
while read -r l; do
    case $l in
        +incdir+*) INC+=("-I${l#+incdir+}") ;;
        *.sv)      SV+=("$l") ;;
    esac
done < "$F"
DEF=()
if [ -n "${OCV_OTBN_FAULT_BITS:-}" ]; then
    for i in "${!SV[@]}"; do
        [ "$(basename "${SV[$i]}")" = otbn_mod_result_selector.sv ] && SV[$i]=$HERE/fault/otbn_mod_result_selector.sv
    done
    DEF=("-DOCV_OTBN_FAULT_BITS=$OCV_OTBN_FAULT_BITS")
fi
NAME=otbn${OCV_OTBN_FAULT_BITS:+_fault$OCV_OTBN_FAULT_BITS}
export RTL_DEFINES="${INC[*]} ${DEF[*]:-}"
# 45 MHz: OTBN closes timing there (at 50 MHz: WNS -0.001 ns inside OTBN - its 256-bit adder path)
export OCV_GEN_FLAGS="${OCV_GEN_FLAGS:---dma 128}" OCV_CLK_MHZ="${OCV_CLK_MHZ:-45}"
export OUT="${OUT:-$OCV/build/vd100/$NAME}"
exec "$OCV/platforms/vd100/build.sh" "$DESC" - "${SV[@]}" "$HERE/otbn_kmac_ocv.sv"
