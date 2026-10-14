#!/usr/bin/env bash
# build.sh - build one OCV environment for the ALINX VD100: FPGA image and PS program.
#
#   platforms/vd100/build.sh <descriptor.json> <model.c | -> <dut.sv> [<more rtl> ...]
#   (model "-": no runner program - the image is for a UVM testbench, built by uvm/build_board.sh)
#
# Same arguments and environment as sim/cosim.sh, so a DUT that passes co-simulation is built
# for the board without changes:
#   RTL_DEFINES   "-DFOO -DBAR=1 -Idir"  defines and include directories of the DUT sources
#   MODEL_SRCS    extra C sources of the model;  MODEL_CFLAGS  their include paths
# Platform options:
#   OCV_CLK_MHZ   PL clock, MHz (default 100)
#   OCV_STOP      sw | bd | synth | impl (default impl; sw = only the PS program)
#   OCV_DEBUG     1 = debug build: ILA on the hub bus (default OUT gets a _debug suffix)
#   OCV_PS_CFLAGS optimisation flags of the PS program (default -O3 -mcpu=cortex-a72, the VD100 APU)
#   OCV_GEN_FLAGS generator options, e.g. --uvm (hub for a UVM testbench on the PS: uvm/build_board.sh)
#   PAYLOAD       extra files to put next to the PS program (e.g. test programs)
#   OUT           build directory (default: build/vd100/<name> next to the descriptor)
#   VIVADO_SETTINGS  Vivado 2023.2 settings64.sh (or have vivado in PATH)
#   REF_BOOTBIN   a working VD100 BOOT.BIN (source of the A72 firmware: bl31, u-boot) - default sd/BOOT_ref.BIN
#   LINUX_DIR     directory with image.ub and boot.scr of the SD-card PetaLinux - default sd/
#                 (sd/: from the ALINX SD card the board shipped with, the PetaLinux of this work)
#
# Result in $OUT:
#   sdcard/          BOOT.BIN, image.ub, boot.scr, ocv/ -> copy to the SD card FAT partition
#   sdcard/ocv/      ocv_<name> (static aarch64), run.sh, payload
#   reports/         utilization, timing, summary.txt
#   ocv_vd100.ltx    ILA probes (debug build), for tools/ila_capture.tcl
set -euo pipefail
PLAT=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$PLAT/../.." && pwd)
BASE=0x80000000                       # hub window in the PS address map (tcl/create_bd.tcl)

[ $# -ge 3 ] || { sed -n '2,25p' "$0"; exit 1; }
DESC=$(realpath "$1"); MODEL=$2; shift 2
[ "$MODEL" = - ] || MODEL=$(realpath "$MODEL")    # "-": no runner (a UVM testbench is the PS program)
RTL=(); for f in "$@"; do RTL+=("$(realpath "$f")"); done

NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$DESC")
OUT=$(realpath -m "${OUT:-$(dirname "$DESC")/build/vd100/$NAME$([ "${OCV_DEBUG:-0}" = 1 ] && echo _debug)}")
mkdir -p "$OUT"
log() { echo "vd100: $*"; }

# 1. wrapper + metadata
# shellcheck disable=SC2086
python3 "$OCV/gen/ocv_gen.py" ${OCV_GEN_FLAGS:-} "$DESC" -o "$OUT/gen" > "$OUT/gen.log"
read -r AW EXPORTS DMA_DW DMA_N < <(python3 -c '
import json,sys
m=json.load(open(sys.argv[1])); d=json.load(open(sys.argv[2]))
print(m["addr_w"], len(d.get("export", [])), m.get("dma_dw", 0), m.get("dma_channels", 0))' "$OUT/gen/${NAME}_ocv_meta.json" "$DESC")
# DMA rings (OCV_GEN_FLAGS="--dma 128"): the wrapper's AXI4 master goes to the DDR through the NoC
[ "$DMA_DW" = 0 ] || [ "$DMA_N" -le 16 ] || { echo "vd100: more than 16 DMA channels (AXI ID width 4)"; exit 1; }
[ "$EXPORTS" = 0 ] || { echo "vd100: descriptor exports DUT ports; this platform has no pins for them"; exit 1; }
SPAN=$(( 1 << (AW < 12 ? 12 : AW) ))
log "$NAME: hub window $BASE + $(printf 0x%X $SPAN), clock ${OCV_CLK_MHZ:-100} MHz$([ "$DMA_DW" = 0 ] || echo ", DMA $DMA_N channel(s) x $DMA_DW bit to DDR")"

# 2. PS program: generic runner + the DUT model, static for the minimal PetaLinux rootfs
BOARD=$OUT/sdcard/ocv
mkdir -p "$BOARD"
if [ "$MODEL" != - ]; then
CC=${CROSS_CC:-aarch64-linux-gnu-gcc}
# shellcheck disable=SC2086
# shellcheck disable=SC2086
# the sampling profiler (OCV_PROF=<file> on the board; nothing without it), reported on the PC with the
# unstripped copy $OUT/ocv_$NAME.debug: tools/prof_report.py $OUT/ocv_$NAME.debug <file>
"$CC" -O2 -c "$OCV/uvm/vlt/ocv_prof.c" -o "$OUT/ocv_prof.o"
# (LTO across runner, library and model; no stack protector and no PIE - the cross compiler's defaults, paid on
#  every function with a local record buffer: the runner path builds records per instruction)
"$CC" -std=c99 ${OCV_PS_CFLAGS:--O3 -mcpu=cortex-a72 -flto -fno-stack-protector -fno-pie -no-pie -U_FORTIFY_SOURCE} -static -pthread -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L \
    -I"$OCV/sw/include" -I"$OUT/gen" ${MODEL_CFLAGS:-} \
    "$OCV/sw/board/ocv_board_main.c" "$OCV/sw/lib/ocv.c" "$OCV/sw/lib/ocv_runner.c" \
    "$OCV/sw/lib/ocv_bus_mmap.c" "$MODEL" ${MODEL_SRCS:-} "$OUT/ocv_prof.o" -o "$BOARD/ocv_$NAME"
cp "$BOARD/ocv_$NAME" "$OUT/ocv_$NAME.debug"
aarch64-linux-gnu-strip "$BOARD/ocv_$NAME" 2>/dev/null || true
cat > "$BOARD/run.sh" <<EOF
#!/bin/sh
# run.sh - run the '$NAME' environment on this board (as root): runner options follow.
cd "\$(dirname "\$0")" && exec ./ocv_$NAME --base $BASE --span $(printf 0x%X $SPAN) "\$@"
EOF
chmod +x "$BOARD/run.sh"
# shellcheck disable=SC2086
fi
for f in ${PAYLOAD:-}; do cp "$f" "$BOARD/"; done
# benchmark set of the example (tools/bench.py), if it has one
if [ -f "$(dirname "$DESC")/bench.txt" ]; then
    cp "$(dirname "$DESC")/bench.txt" "$OCV/tools/bench_board.sh" "$BOARD/"
fi
if [ "$MODEL" = - ]; then log "PS program: none here - the UVM testbench (uvm/build_board.sh aarch64)"
else log "PS program: $BOARD/ocv_$NAME"; fi
[ "${OCV_STOP:-impl}" = sw ] && exit 0

# 3. FPGA image
{ sed "s#^#$OCV/hw/rtl/#" "$OCV/hw/rtl/ocv.f"; printf '%s\n' "${RTL[@]}" "$OUT/gen/${NAME}_ocv.sv"; } > "$OUT/rtl.f"
# Versal has UltraRAM (155 blocks on the VE2302, as many as block RAM tiles): the hub's large record
# buffers go there (ocv_ram), block RAM stays for the rest - a core's RAM, its smaller buffers
DEFS=("OCV_URAM_BITS=${OCV_URAM_BITS:-147456}"); INCS=()
[ "$DMA_DW" = 0 ] || DEFS+=("OCV_DMA_DW=$DMA_DW" "OCV_DMA_IDW=$(python3 -c "import math; print(max(1, math.ceil(math.log2($DMA_N))))")")
for a in ${RTL_DEFINES:-}; do
    case "$a" in
        -D*) DEFS+=("${a#-D}") ;;
        -I*) INCS+=("$(realpath "${a#-I}")") ;;
        *)   echo "vd100: RTL_DEFINES: unsupported '$a' (use -D / -I)"; exit 1 ;;
    esac
done
[ -n "${VIVADO_SETTINGS:-}" ] && source "$VIVADO_SETTINGS"
command -v vivado >/dev/null || { echo "vd100: vivado not found (set VIVADO_SETTINGS)"; exit 1; }
log "Vivado build (${OCV_STOP:-impl}), log: $OUT/vivado.log"
# Vivado 2023.2's source scanner (srcscanner: compile order, hierarchy) grows past 20 GiB on cores with
# large parameter structs (CVA6: a configuration struct of kilobits in every module's name) - synthesis does
# not need it: it is stopped whenever it passes 2 GiB (OCV_SRCSCANNER_GB; 0: never)
SSG=${OCV_SRCSCANNER_GB:-2}
if [ "$SSG" != 0 ]; then
    ( while sleep 1; do
        r=$(ps -C srcscanner -o rss= 2>/dev/null | sort -n | tail -1 || true)   # (set -e, pipefail: none running)
        if [ -n "$r" ] && [ "$r" -ge $((SSG * 1048576)) ]; then
            pkill -x srcscanner || true
            echo "vd100: srcscanner stopped at $((r / 1048576)) GiB" >> "$OUT/srcscanner.log"
        fi
      done ) &
    SSW=$!
    trap 'kill $SSW 2>/dev/null; pkill -x srcscanner || true' EXIT   # (no scanner outlives the build)
fi
( cd "$OUT" && LC_ALL=C OCV_OUT="$OUT" OCV_ENV="${NAME}_ocv" OCV_AW="$AW" OCV_DMA_DW="$DMA_DW" \
    OCV_RTL_F="$OUT/rtl.f" OCV_DEFINES="${DEFS[*]:-}" OCV_INCDIRS="${INCS[*]:-}" \
    OCV_DEBUG="${OCV_DEBUG:-0}" vivado -mode batch -notrace -source "$PLAT/tcl/build.tcl" > "$OUT/vivado.log" 2>&1 ) \
    || { grep -E "OCV_BUILD|ERROR" "$OUT/vivado.log" | head -20; exit 1; }
grep "OCV_BUILD" "$OUT/vivado.log"
[ "${OCV_STOP:-impl}" = impl ] || exit 0

# 4. boot image: our PDI + the A72 firmware of a working BOOT.BIN; Linux from the SD card as is
REF_BOOTBIN=${REF_BOOTBIN:-$PLAT/sd/BOOT_ref.BIN}
LINUX_DIR=${LINUX_DIR:-$PLAT/sd}
if [ -f "$REF_BOOTBIN" ] && [ -f "$LINUX_DIR/image.ub" ]; then
    "$PLAT/tools/make_bootbin.sh" "$OUT/ocv_vd100.pdi" "$REF_BOOTBIN" "$OUT/sdcard/BOOT.BIN" > "$OUT/bootbin.log" 2>&1 \
        || { cat "$OUT/bootbin.log"; exit 1; }
    cp "$LINUX_DIR/image.ub" "$LINUX_DIR/boot.scr" "$OUT/sdcard/"
    log "SD card: $OUT/sdcard (copy all of it to the FAT partition)"
else
    log "REF_BOOTBIN/LINUX_DIR not set: BOOT.BIN not made (PDI: $OUT/ocv_vd100.pdi)"
fi
