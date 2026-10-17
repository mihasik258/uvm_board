#!/usr/bin/env bash
# qprof.sh [program.hex] [lines] - the reference model's cost without the board: A72 instructions per RISC-V
# instruction of the model path (hw/cpu/run.sh <bind> bench, the jit model), counted under qemu-aarch64 with
# its TCG plugin hotblocks - by function and by source line (an instruction count, not time: the board's
# timing is measured on the board; the counts tell where the work is and whether a change cut it).
# First the fast and jit models' signatures are compared (window CRCs, record counts, coverage; with the
# runner's compared-bits masks): a change of the model path must keep them equal.
#
#   tools/qprof.sh build/embench/nettle-aes_s1.hex 30
#
# Needs: tools/get_qemu.sh's source tree (build/qemu/qemu-9.2.0); a second qemu-aarch64 with plugins is
# built next to it once (build-a64p: not static - plugins need a dynamic qemu), hotblocks patched to list
# every block. Environment: BIND (default examples/cva6/cva6.bind).
set -uo pipefail
OCV=$(cd "$(dirname "$0")/.." && pwd)
PROG=$(realpath "${1:-$OCV/build/embench/nettle-aes_s1.hex}")
LINES=${2:-30}
BIND=${BIND:-$OCV/examples/cva6/cva6.bind}
QSRC=$OCV/build/qemu/qemu-9.2.0
QP=$QSRC/build-a64p
[ -d "$QSRC" ] || { echo "qprof: no $QSRC (tools/get_qemu.sh)"; exit 1; }
if [ ! -x "$QP/qemu-aarch64" ] || [ ! -f "$QP/contrib/plugins/libhotblocks.so" ]; then
    echo "qprof: building qemu-aarch64 with plugins (once, ~10 min)"
    sed -i 's/^static guint64 limit = 20;/static guint64 limit = 1000000;/' "$QSRC/contrib/plugins/hotblocks.c"
    mkdir -p "$QP"
    ( cd "$QP" && PATH=$OCV/build/qemu/venv/bin:$PATH ../configure --target-list=aarch64-linux-user --enable-plugins \
        --disable-docs --disable-tools --disable-werror > configure.log 2>&1 &&
      PATH=$OCV/build/qemu/venv/bin:$PATH nice ninja -j"${OCV_MAKE_J:-6}" qemu-aarch64 contrib/plugins/libhotblocks.so > make.log 2>&1 ) \
        || { echo "qprof: qemu build failed ($QP/*.log)"; exit 1; }
fi
ulimit -v 4000000
OUT=$OCV/build/qprof
OCV_BENCH_EXTRA=-g OUT=$OUT OCV_BENCH_ARCH=aarch64 "$OCV/hw/cpu/run.sh" "$BIND" bench 2>&1 | grep -E "error|warning" | grep -v lto
B=$(ls "$OUT"/bench_aarch64/bench_model) || exit 1
Q=$OCV/build/qemu/qemu-aarch64
sig() { OCV_BENCH_MASKS=1 "$Q" -cpu cortex-a72 "$B" --batches 1 --model-opt program="$PROG" --model-opt max=30000000 "$@" 2>&1 |
        grep -oE "[0-9]* instructions, [0-9]* records|signature [0-9a-f]*|instructions - .*" | md5sum | cut -c1-12; }
a=$(sig --model-opt cpu=fast); b=$(sig --model-opt cpu=jit)
echo "qprof: $(basename "$PROG"): signatures fast $a, jit $b: $([ "$a" = "$b" ] && echo SAME || echo DIFFER)"
OCV_BENCH_MASKS=1 OCV_JIT_STATS=1 "$QP/qemu-aarch64" -cpu cortex-a72 -plugin "$QP/contrib/plugins/libhotblocks.so" -d plugin \
    -D "$OUT/hot.txt" "$B" --batches 1 --model-opt program="$PROG" --model-opt max=30000000 --model-opt cpu=jit > "$OUT/run.txt" 2>&1
grep -E "^jit:|bench_model:" "$OUT/run.txt" | cut -c1-160
python3 - "$B" "$OUT/hot.txt" "$OUT/run.txt" "$LINES" <<'EOF'
import collections, re, subprocess, sys
binf, hot, run, lines = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
n = int(re.search(r"(\d+) instructions,", open(run).read()).group(1))
cnt = collections.Counter(); outside = 0
for l in open(hot):
    p = l.strip().split(", ")
    if len(p) != 4 or not p[0].startswith("0x"): continue
    a, i, e = int(p[0], 16), int(p[2]), int(p[3])
    if a >= 0x10000000: outside += i * e; continue           # the jit's generated code (mmap)
    for k in range(i): cnt[a + 4 * k] += e                    # (AArch64: 4 bytes an instruction)
addrs = sorted(cnt)
out = subprocess.run(["aarch64-linux-gnu-addr2line", "-e", binf, "-s", "-f"] + [hex(a) for a in addrs],
                     capture_output=True, text=True).stdout.splitlines()
fn = collections.Counter(); ln = collections.Counter()
for k, a in enumerate(addrs):
    f = out[2 * k]; fn[f] += cnt[a]; ln[f + " " + out[2 * k + 1].split(" ")[0]] += cnt[a]
inb = sum(cnt.values())
print(f"qprof: {(inb + outside) / n:.1f} A72 instructions per RISC-V instruction: translated code {outside / n:.1f}, "
      f"the program {inb / n:.1f} ({n} RISC-V instructions)")
print("by function:")
for k, v in fn.most_common(12): print(f"  {v / n:6.1f}  {k}")
print("by line:")
for k, v in ln.most_common(lines): print(f"  {v / n:6.1f}  {k}")
EOF
