#!/usr/bin/env bash
# get_verilator.sh - fetch and build Verilator (a release with UVM support) and the UVM library
# adapted to it, at pinned revisions, for UVM testbenches that run on the board's processor.
#
#   tools/get_verilator.sh
#
# Result: build/verilator/install/bin/verilator (runs on the PC: SystemVerilog -> C++; the C++
# and Verilator's runtime are then compiled for the board's ARM) and build/verilator/uvm/src
# (UVM sources). Kept out of the repository; the system Verilator is left alone.
# The runtime gets one OCV hook (tools/verilator/ocv_fast_random.patch): randomize() first tries
# OCV's in-process constraint solver (uvm/vlt/ocv_fast_random.cpp), the SMT solver only if needed.
# UVM: Verilator's single-file package, patched by tools/verilator/uvm_*.patch into build/verilator/uvm_ocv.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
VREV=${VERILATOR_REV:-v5.052}
UVM_REPO=https://github.com/chipsalliance/uvm-verilator
UVM_REV=${UVM_REV:-5d72b6618acfddece7f09382a032ccbc05862fdc}
TOP=$OCV/build/verilator
mkdir -p "$TOP"

if [ ! -d "$TOP/src/.git" ]; then
    git clone --quiet https://github.com/verilator/verilator "$TOP/src"
fi
git -C "$TOP/src" fetch --quiet --tags origin 2>/dev/null || true
git -C "$TOP/src" checkout --quiet "$VREV"
# OCV's changes: the runtime hook (an in-process solver is tried before the external SMT solver);
# other testbenches (core-v-verif): covergroup calling methods of its class, %b of a string, C macro
# names, randomize() with a null rand object handle (IEEE 18.5.9); the location text of each constraint
# built only for an unsatisfiable-constraint message, not on every randomize() (a third of a call on the A72)
for PATCH in "$OCV"/tools/verilator/ocv_fast_random.patch "$OCV"/tools/verilator/ocv_tb_compat.patch \
             "$OCV"/tools/verilator/ocv_lazy_constraint_lines.patch; do
    if ! git -C "$TOP/src" apply --reverse --check "$PATCH" 2>/dev/null; then
        git -C "$TOP/src" apply "$PATCH"
        rm -f "$TOP/install/.rev"                 # changed: build and install again
    fi
done
cd "$TOP/src"
if [ ! -x "$TOP/install/bin/verilator" ] || [ "$(cat "$TOP/install/.rev" 2>/dev/null)" != "$VREV" ]; then
    autoconf > "$TOP/autoconf.log" 2>&1
    ./configure --prefix="$TOP/install" > "$TOP/configure.log" 2>&1 || { tail -20 "$TOP/configure.log"; exit 1; }
    make -j"${OCV_MAKE_J:-6}" > "$TOP/make.log" 2>&1 || { tail -30 "$TOP/make.log"; exit 1; }
    make install > "$TOP/install.log" 2>&1
    echo "$VREV" > "$TOP/install/.rev"
fi

if [ ! -d "$TOP/uvm/.git" ]; then
    git clone --quiet "$UVM_REPO" "$TOP/uvm"
fi
git -C "$TOP/uvm" fetch --quiet origin "$UVM_REV" 2>/dev/null || true
git -C "$TOP/uvm" checkout --quiet "$UVM_REV"
# OCV's copy of Verilator's single-file UVM, with OCV's runtime fixes (tools/verilator/uvm_*.patch):
# a transaction's event pool is created on first use, not with every object
UVMF=uvm_pkg_all_v2020_3_2_nodpi.svh
mkdir -p "$TOP/uvm_ocv"
cp "$TOP/src/test_regress/t/uvm/$UVMF" "$TOP/uvm_ocv/$UVMF"
for p in "$OCV"/tools/verilator/uvm_*.patch; do patch -s -d "$TOP/uvm_ocv" "$UVMF" < "$p"; done
echo "verilator $("$TOP/install/bin/verilator" --version | cut -d' ' -f2) at $TOP/install; UVM at $TOP/uvm ($UVM_REV)"
