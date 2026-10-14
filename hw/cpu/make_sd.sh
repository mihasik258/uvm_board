#!/usr/bin/env bash
# make_sd.sh - one SD-card folder for several cores under OCV (each built by `hw/cpu/run.sh <bind> vd100`):
#
#   hw/cpu/make_sd.sh -o <dir> <core.bind> [program ...] [-- <core.bind> [program ...]] ...
#
# <dir>: BOOT.BIN (the first core's), BOOT_<name>.BIN of each, image.ub, boot.scr, ocv/cpu/<name>/ (the PS
# program, run.sh, board_run.sh, progs/), use.sh. Copy all of <dir> to the card's FAT partition. On the board:
#   sh /run/media/FAT-mmcblk1p1/ocv/cpu/use.sh <name>     (makes <name>'s image the one that boots; reboot)
#   sh /run/media/FAT-mmcblk1p1/ocv/cpu/<name>/board_run.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
[ "${1:-}" = -o ] && [ $# -ge 3 ] || { sed -n '2,10p' "$0"; exit 1; }
OUT=$(realpath -m "$2"); shift 2
mkdir -p "$OUT/ocv/cpu"
first=
while [ $# -gt 0 ]; do
    bind=$(realpath "$1"); shift
    name=$(awk '$1 == "name" { print $2; exit }' "$bind")
    sd=$OCV/build/cpu/$name/vd100/sdcard
    [ -f "$sd/BOOT.BIN" ] || { echo "make_sd: no $sd/BOOT.BIN - build it: hw/cpu/run.sh $bind vd100"; exit 1; }
    cp "$sd/BOOT.BIN" "$OUT/BOOT_$name.BIN"
    [ -n "$first" ] || { first=$name; cp "$sd/BOOT.BIN" "$OUT/BOOT.BIN"; cp "$sd/image.ub" "$sd/boot.scr" "$OUT/"; }
    d=$OUT/ocv/cpu/$name
    mkdir -p "$d/progs"
    cp "$sd/ocv/"* "$d/"
    cp "$HERE/board_run.sh" "$HERE/board_bench.sh" "$d/"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do cp "$1" "$d/progs/"; shift; done
    [ "${1:-}" = -- ] && shift
    echo "make_sd: $name ($(ls "$d/progs" | wc -l) programs)"
done
cat > "$OUT/ocv/cpu/use.sh" <<'USE'
#!/bin/sh
# use.sh <name> - the FPGA image of core <name> boots next (then: reboot)
F=$(cd "$(dirname "$0")/../.." && pwd)
[ -f "$F/BOOT_$1.BIN" ] || { echo "use.sh: no BOOT_$1.BIN"; ls "$F" | grep BOOT_; exit 1; }
cp "$F/BOOT_$1.BIN" "$F/BOOT.BIN" && sync && echo "use.sh: $1 boots next - reboot"
USE
echo "make_sd: $OUT (boots $first; copy all of it to the FAT partition)"
