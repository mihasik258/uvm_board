#!/usr/bin/env bash
# make_sd.sh - one command from a UVM testbench to a folder for the VD100's SD card.
#
#   RTL="dut.sv ..." uvm/make_sd.sh <name> <tb_top> <tb files ...>
#
#   1. uvm2board.py     the board form of the testbench and the DUT's channels, read from it
#   2. vd100/build.sh   the FPGA image (BOOT.BIN); skipped when nothing it is built from changed
#                       (the channels, the RTL and its defines, OCV's hub, the platform, the clock)
#   3. build_board.sh   the testbench as a program for the board's A72
#   4. $OUT/sdcard      BOOT.BIN (and a copy BOOT_<name>.BIN), image.ub, boot.scr, ocv/<name>/: the
#                       program, PAYLOAD files, run.sh - copy all of it to the card's FAT partition
#
# On the board (as root):  sh /run/media/FAT-mmcblk1p1/ocv/<name>/run.sh +UVM_TESTNAME=<test> [plusargs]
#
# Environment: RTL, RTL_DEFINES (as for build_board.sh), TB_C / TB_CFLAGS (the testbench's DPI C code),
# PAYLOAD (files the tests read, e.g. programs), OCV_UVM_GEN (more generator options, e.g. "--dma 128": the
# outputs over DMA rings; the testbench uses them by itself, OCV_NO_DMA=1 on the board: over the bus),
# OCV_CLK_MHZ (default 100), OUT (default
# build/sd/<name>), and for BOOT.BIN: VIVADO_SETTINGS, REF_BOOTBIN, LINUX_DIR (see vd100/build.sh).
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 3 ] || { sed -n '2,20p' "$0"; exit 1; }
NAME=$1; TOP=$2; shift 2
TB=(); for f in "$@"; do TB+=("$(realpath "$f")"); done
read -r -a RTLS <<< "${RTL:-}"
[ ${#RTLS[@]} -gt 0 ] || { echo "make_sd: give the DUT's RTL (RTL=\"...\")"; exit 1; }
for i in "${!RTLS[@]}"; do RTLS[$i]=$(realpath "${RTLS[$i]}"); done
OUT=$(realpath -m "${OUT:-build/sd/$NAME}")
mkdir -p "$OUT"
log() { echo "make_sd: $* ($(date +%T))"; }

# 1. the board form
log "1/4 testbench -> board form"
python3 "$OCV/uvm/uvm2board.py" "${TB[@]}" -o "$OUT/overlay" --top "$TOP"
DESC=$OUT/overlay/desc.json

# 2. the FPGA image, unless it is already built from the same inputs
STAMP=$( { cat "$DESC" "${RTLS[@]}" "$OCV"/hw/rtl/*.sv "$OCV"/hw/rtl/ocv.f "$OCV"/gen/ocv_gen.py \
             "$OCV"/platforms/vd100/tcl/* "$OCV"/platforms/vd100/constrs/* 2>/dev/null
           echo "${RTL_DEFINES:-} ${OCV_CLK_MHZ:-100} ${REF_BOOTBIN:-} ${LINUX_DIR:-} ${OCV_UVM_GEN:-}"; } | sha256sum | cut -c1-16)
IMG=$OUT/vd100
mkdir -p "$IMG"; echo "$STAMP" > "$IMG/stamp.want"
if [ -f "$IMG/sdcard/BOOT.BIN" ] && [ "$(cat "$IMG/stamp" 2>/dev/null)" = "$STAMP" ]; then
    log "2/4 FPGA image: up to date ($IMG/sdcard/BOOT.BIN)"
else
    log "2/4 FPGA image: Vivado build (about an hour), log $IMG/vivado.log"
    rm -f "$IMG/stamp"
    OCV_GEN_FLAGS="--uvm ${OCV_UVM_GEN:-}" OUT=$IMG "$OCV/platforms/vd100/build.sh" "$DESC" - "${RTLS[@]}"
    [ -f "$IMG/sdcard/BOOT.BIN" ] || { echo "make_sd: no BOOT.BIN (set REF_BOOTBIN and LINUX_DIR)"; exit 1; }
    echo "$STAMP" > "$IMG/stamp"
fi

# 3. the testbench for the A72
log "3/4 testbench -> aarch64 program"
REF=; [ -f "$OUT/overlay/board_ref.c" ] && REF=$OUT/overlay/board_ref.c   # the scoreboard's checks in C
TB_C="${TB_C:-} $REF" OUT=$OUT/aarch64 \
    "$OCV/uvm/build_board.sh" aarch64 "$DESC" "${TOP}_board" "${TB[@]}" "$OUT/overlay/board_overlay.sv"

# 4. the folder for the card
log "4/4 SD card folder"
SD=$OUT/sdcard; D=$SD/ocv/$NAME
rm -rf "$SD"; mkdir -p "$D"
cp "$IMG/sdcard/BOOT.BIN" "$SD/BOOT.BIN"
cp "$IMG/sdcard/BOOT.BIN" "$SD/BOOT_$NAME.BIN"        # to switch back to it later: cp BOOT_<name>.BIN BOOT.BIN
cp "$IMG/sdcard/image.ub" "$IMG/sdcard/boot.scr" "$SD/"
cp "$OUT/aarch64/${TOP}_board" "$D/${NAME}_tb"
for f in ${PAYLOAD:-}; do cp "$f" "$D/"; done
cat > "$D/run.sh" <<EOF
#!/bin/sh
# run.sh [plusargs] - the '$NAME' testbench on this board, its DUT in the FPGA (BOOT.BIN of '$NAME' booted).
# It runs in this folder: its files are given by name (+PROG=<file>).
cd "\$(dirname "\$0")"
exec ./${NAME}_tb +OCV_BASE=0x80000000 +UVM_NO_RELNOTES "\$@"   # (from the card: no copy - 0.15 s a run)
EOF
chmod +x "$D/run.sh"
log "done: copy $SD/* to the SD card's FAT partition; on the board:"
echo "    sh /run/media/FAT-mmcblk1p1/ocv/$NAME/run.sh +UVM_TESTNAME=<test> [plusargs]"
