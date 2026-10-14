#!/usr/bin/env bash
# get_qemu.sh - fetch and build qemu-aarch64 (user mode, static) to run the board's ARM code on the PC:
# the "jit" processor model (generated AArch64 code) is checked against "iss" under it.
#
#   ocv/tools/get_qemu.sh
#
# Result: ocv/build/qemu/qemu-aarch64. Needs ninja (pip install ninja into any venv on PATH) and python3.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
VER=${QEMU_VER:-9.2.0}                                         # pinned
TOP=$OCV/build/qemu
SRC=$TOP/qemu-$VER
mkdir -p "$TOP"
if [ ! -d "$SRC" ]; then
    curl -sSL "https://download.qemu.org/qemu-$VER.tar.xz" -o "$TOP/qemu-$VER.tar.xz"
    tar -C "$TOP" -xJf "$TOP/qemu-$VER.tar.xz"
fi
mkdir -p "$SRC/build-a64"
cd "$SRC/build-a64"
[ -f build.ninja ] || nice -n 10 ../configure --target-list=aarch64-linux-user --static --disable-docs --disable-tools \
    --disable-werror > configure.log 2>&1 || { tail -20 configure.log; exit 1; }
nice -n 10 make -j"${OCV_MAKE_J:-6}" > make.log 2>&1 || { tail -30 make.log; exit 1; }
cp qemu-aarch64 "$TOP/qemu-aarch64"
echo "get_qemu: $TOP/qemu-aarch64"
