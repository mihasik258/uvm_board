#!/usr/bin/env bash
# get_spike.sh - fetch and build Spike (riscv-isa-sim), the RISC-V reference ISA model, at a pinned
# revision, as a library for OCV processor models.
#
#   tools/get_spike.sh [host|aarch64]        (default host)
#
# Result: build/spike/<target>/install/{bin/spike, lib/libriscv.a ..., include/...}
# The source is kept in build/spike/src (not part of the repository).
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
TARGET=${1:-host}
REPO=https://github.com/riscv-software-src/riscv-isa-sim
REV=${SPIKE_REV:-0bff12123b1fd510e19e19634dd997dbade70e54}      # pinned: results must be reproducible
TOP=$OCV/build/spike
SRC=$TOP/src
BLD=$TOP/$TARGET/build
INST=$TOP/$TARGET/install
mkdir -p "$TOP"

if [ ! -d "$SRC/.git" ]; then
    git clone --quiet "$REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$REV" 2>/dev/null || true
git -C "$SRC" checkout --quiet "$REV"

mkdir -p "$BLD"
cd "$BLD"
case $TARGET in
    host)    CONF=() ;;
    aarch64) command -v aarch64-linux-gnu-g++ >/dev/null || {
                 echo "get_spike.sh: aarch64-linux-gnu-g++ not found (apt install g++-aarch64-linux-gnu)"; exit 1; }
             CONF=(--host=aarch64-linux-gnu CC=aarch64-linux-gnu-gcc CXX=aarch64-linux-gnu-g++) ;;
    *)       echo "get_spike.sh: target host or aarch64"; exit 1 ;;
esac
if [ ! -f Makefile ]; then
    "$SRC/configure" --prefix="$INST" --without-boost --without-boost-asio --without-boost-regex \
        "${CONF[@]}" > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
fi
make -j"$(nproc)" > make.log 2>&1 || { tail -30 make.log; exit 1; }
make install > install.log 2>&1
echo "spike ($TARGET) at $REV: $INST"
