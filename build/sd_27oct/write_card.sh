#!/usr/bin/env bash
# write_card.sh - OTBN+KMAC and cv64a6 UVM tests onto the SD card's FAT partition (/media/toast/FAT), next to
# what is already there (nothing is deleted; BOOT.BIN becomes OTBN's - the old one is kept as BOOT_before_27oct.BIN)
set -euo pipefail
OCV=/home/toast/verif-diplom
C=${1:-/media/toast/FAT}
[ -d "$C" ] || { echo "write_card: no $C - is the card mounted?"; exit 1; }
B=$OCV/build
for f in $B/vd100/otbn/sdcard/BOOT.BIN $B/vd100/otbn_fault22/sdcard/BOOT.BIN $B/cva6_64/vd100/sdcard/BOOT.BIN \
         $B/cva6_64_fault/vd100/sdcard/BOOT.BIN $B/vd100/otbn/sdcard/image.ub $B/vd100/otbn/sdcard/boot.scr \
         $B/uvm/otbn_c_aarch64/tb_top $B/uvm/cva6_64_c_aarch64/tb_top $B/otbn/prog/run_mldsa87.load \
         $B/otbn/prog/run_mldsa87.sym $B/cva6_64/tests/rv64_basic.hex $B/cva6_64/tests/minstret64.hex \
         $B/embench/rv64/nettle-aes_s1_rv64.hex $B/embench/rv64/nettle-aes_s1100_instret_rv64.hex; do
    [ -f "$f" ] || { echo "write_card: missing $f"; exit 1; }
done
# the testbenches without their debug information (the cv64a6 one, static with Spike: 332 MB -> a fraction)
mkdir -p $B/sd_27oct/bin
aarch64-linux-gnu-strip -o $B/sd_27oct/bin/tb_top_otbn $B/uvm/otbn_c_aarch64/tb_top
aarch64-linux-gnu-strip -o $B/sd_27oct/bin/tb_top_cva6_64 $B/uvm/cva6_64_c_aarch64/tb_top
ls -la $B/sd_27oct/bin
echo "card before:"; df -h "$C" | tail -1
# the images
[ -f "$C/BOOT.BIN" ] && [ ! -f "$C/BOOT_before_27oct.BIN" ] && cp "$C/BOOT.BIN" "$C/BOOT_before_27oct.BIN"
cp $B/vd100/otbn/sdcard/BOOT.BIN          "$C/BOOT_otbn.BIN"
cp $B/vd100/otbn_fault22/sdcard/BOOT.BIN  "$C/BOOT_otbn_fault22.BIN"
cp $B/cva6_64/vd100/sdcard/BOOT.BIN       "$C/BOOT_cva6_64.BIN"
cp $B/cva6_64_fault/vd100/sdcard/BOOT.BIN "$C/BOOT_cva6_64_fault.BIN"
cp $B/vd100/otbn/sdcard/BOOT.BIN          "$C/BOOT.BIN"
[ -f "$C/image.ub" ] || cp $B/vd100/otbn/sdcard/image.ub "$C/"
[ -f "$C/boot.scr" ] || cp $B/vd100/otbn/sdcard/boot.scr "$C/"
# the tests
mkdir -p "$C/ocv/otbn" "$C/ocv/cva6_64/progs"
cp $B/sd_27oct/ocv/use.sh $B/sd_27oct/ocv/README.txt "$C/ocv/"
echo otbn > "$C/ocv/booted"
cp $B/sd_27oct/bin/tb_top_otbn "$C/ocv/otbn/tb_top"
cp $OCV/examples/otbn/board_run.sh $B/otbn/prog/run_mldsa87.load \
   $B/otbn/prog/run_mldsa87.sym "$C/ocv/otbn/"
cp $B/sd_27oct/bin/tb_top_cva6_64 "$C/ocv/cva6_64/tb_top"
cp $OCV/examples/cva6_64/board_run.sh "$C/ocv/cva6_64/"
cp $B/cva6_64/tests/rv64_basic.hex $B/cva6_64/tests/minstret64.hex $B/embench/rv64/nettle-aes_s1_rv64.hex \
   $B/embench/rv64/nettle-aes_s1100_instret_rv64.hex "$C/ocv/cva6_64/progs/"
sync
echo "card after:"; df -h "$C" | tail -1
ls -la "$C" "$C/ocv" "$C/ocv/otbn" "$C/ocv/cva6_64" "$C/ocv/cva6_64/progs"
echo "write_card: done - BOOT.BIN is OTBN's; safe to eject"
