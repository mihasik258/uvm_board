#!/usr/bin/env bash
# board_set.sh - everything we measure on the board in one SD-card folder, built once.
#
#   tools/board_set.sh            build what is missing (Vivado strictly one at a time), then assemble
#   tools/board_set.sh assemble   only assemble from what is built
#
# Images (all with the outputs over DMA rings, ocv_gen.py --dma 128; the bus path stays: --no-dma / OCV_NO_DMA=1):
#   cv32e40p, scr1, cva6   hw/cpu wrapper: generated programs (full check), benchmarks, CVA6 directed tests;
#                          cv32e40p also core-v-verif's UVM testbench (test 1, uvm_fast)
#   scr1_v, mac16_v, sha256_v   the verifier-style UVM testbenches (uvm/make_sd.sh), as before plus DMA
#   mac16                  an IP block under the plain runner
# Result: build/board_set/sdcard - copy all of it to the card's FAT partition. On the board (root):
#   sh /run/media/FAT-mmcblk1p1/ocv/measure.sh        (repeat after each reboot until it says ALL DONE)
# Results: ocv/results/*.txt on the card.
set -euo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
S=$OCV/build/board_set
SD=$S/sdcard
export VIVADO_SETTINGS=${VIVADO_SETTINGS:-$HOME/Vivado_2023/Vivado/2023.2/settings64.sh}
export OCV_GEN_FLAGS="--dma 128" OCV_UVM_GEN="--dma 128"
log() { echo "board_set: $* ($(date +%T))"; }
wait_vivado() { while pgrep -x vivado > /dev/null || pgrep -f "unwrapped/lnx64.o/vivado" > /dev/null; do sleep 30; done; }

# programs
P=$S/progs; mkdir -p "$P"
[ -f "$P/r3.hex" ] || {
    "$OCV/examples/scr1/gen_random_prog.py" --seed 1 -o "$P/r1.hex" > /dev/null
    "$OCV/examples/scr1/gen_random_prog.py" --seed 1 --loops 100 -o "$P/r2.hex" > /dev/null
    "$OCV/examples/scr1/gen_random_prog.py" --seed 1 --loops 1000 -o "$P/r3.hex" > /dev/null; }
CVP=$OCV/examples/cv32e40p/build/prog

if [ "${1:-}" != assemble ]; then
    # 1. hw/cpu images
    for c in cv32e40p scr1 cva6; do
        if [ ! -f "$OCV/build/cpu/$c/vd100/sdcard/BOOT.BIN" ] || ! grep -q '"dma_dw": 128' "$OCV/build/cpu/$c/vd100/gen/"*_meta.json 2>/dev/null; then
            wait_vivado; log "image $c"
            J=; [ $c = cva6 ] && J=2
            OCV_JOBS=${J:-8} "$OCV/hw/cpu/run.sh" "$OCV/examples/$c/$c.bind" vd100 > "$S/build_$c.log" 2>&1
        fi
    done
    # 2. UVM testbenches (image + aarch64 program each)
    for t in scr1 mac16 sha256; do
        wait_vivado; log "UVM $t"
        PAYLOAD="$P/r1.hex $P/r2.hex $P/r3.hex" OUT=$S/uvm_$t "$OCV/examples/$t/uvm_v/run.sh" sd > "$S/build_uvm_$t.log" 2>&1
    done
    # 3. core-v-verif's UVM testbench for the cv32e40p image (no Vivado: the hw/cpu image)
    log "uvm_fast (core-v-verif) for aarch64"
    "$OCV/examples/cv32e40p/uvm_fast/run.sh" aarch64 > "$S/build_uvm_fast.log" 2>&1
    # 4. mac16 under the plain runner
    if [ ! -f "$S/mac16/sdcard/BOOT.BIN" ]; then
        wait_vivado; log "image mac16 (runner)"
        OUT=$S/mac16 "$OCV/platforms/vd100/build.sh" "$OCV/examples/mac16/mac16.json" "$OCV/examples/mac16/mac16_model.c" \
            "$OCV/examples/mac16/mac16.sv" > "$S/build_mac16.log" 2>&1
    fi
    # 5. the bus benchmark for the A72
    aarch64-linux-gnu-gcc -O2 -static -I"$OCV/sw/include" "$OCV/sw/board/ocv_busbench.c" "$OCV/sw/lib/ocv_bus_mmap.c" \
        -o "$S/ocv_busbench"
fi

# ---- assemble ----
log "assemble $SD"
rm -rf "$SD"; mkdir -p "$SD"
"$OCV/hw/cpu/make_sd.sh" -o "$SD" \
    "$OCV/examples/cv32e40p/cv32e40p.bind" "$CVP/hello-world.hex" "$CVP/dhrystone.hex" "$CVP/coremark.hex" -- \
    "$OCV/examples/scr1/scr1.bind" "$OCV/examples/scr1/programs/hello.hex" "$OCV/examples/scr1/programs/dhrystone21.hex" \
        "$P/r1.hex" "$P/r2.hex" "$P/r3.hex" -- \
    "$OCV/examples/cva6/cva6.bind" "$CVP/hello-world.hex" "$CVP/dhrystone.hex" "$CVP/coremark.hex" > "$S/assemble.log"
"$OCV/examples/cv32e40p/uvm_fast/sd.sh" "$SD" >> "$S/assemble.log"
# CVA6 directed tests (not in progs/: they need their own options)
R=$SD/ocv/cpu/cva6/repro; mkdir -p "$R"
"$OCV/examples/cva6/repro/run.sh" mie_disable > /dev/null 2>&1 || true
cp "$OCV/build/repro/cva6/mie_disable.hex" "$OCV/examples/cva6/repro/flushed_load_min.bin" \
    "$OCV/examples/cva6/repro/stale_load_min.bin" "$OCV/examples/cva6/repro/stale_load_min_v5.bin" "$R/"
for t in scr1 mac16 sha256; do
    u=$S/uvm_$t/sdcard
    cp "$u/BOOT_$t.BIN" "$SD/BOOT_${t}_v.BIN"
    mkdir -p "$SD/ocv/${t}_v"; cp -r "$u/ocv/$t/." "$SD/ocv/${t}_v/"
done
cp "$S/mac16/sdcard/BOOT.BIN" "$SD/BOOT_mac16.BIN"
mkdir -p "$SD/ocv/mac16"; cp -r "$S/mac16/sdcard/ocv/." "$SD/ocv/mac16/"
cp "$S/ocv_busbench" "$SD/ocv/"
cp "$OCV/tools/measure.sh" "$SD/ocv/measure.sh"
mkdir -p "$SD/ocv/results"
log "done: $SD ($(du -sh "$SD" | cut -f1)) - copy all of it to the SD card; on the board: sh /run/media/FAT-mmcblk1p1/ocv/measure.sh"
