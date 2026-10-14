#!/usr/bin/env bash
# t_board_ref.sh - the reference function uvm2board.py writes with the record layout as constants (words
# built and read with fixed shifts and masks) against the generic one (field descriptors, ocv_set_raw):
# the same expected records and the same DUT values handed to the model, for random model outputs and
# random DUT records (the SCR1 verifier-style testbench: 13 compared fields, several across word bounds).
set -euo pipefail
OCV=$(cd "$(dirname "$0")/../.." && pwd)
W=${OUT:-$OCV/build/uvm_test}/board_ref; rm -rf "$W"; mkdir -p "$W"
E=$OCV/examples/scr1/uvm_v
python3 "$OCV/uvm/uvm2board.py" "$E/scr1_if.sv" "$E/scr1_pkg.sv" "$E/tb_top.sv" -o "$W/fast" --top tb_top > /dev/null
OCV_U2B_GENERIC=1 python3 "$OCV/uvm/uvm2board.py" "$E/scr1_if.sv" "$E/scr1_pkg.sv" "$E/tb_top.sv" -o "$W/generic" --top tb_top > /dev/null
grep -q "constant" "$W/fast/board_ref.c" && ! grep -q "constant" "$W/generic/board_ref.c" || { echo "t_board_ref: paths not as expected"; exit 1; }
python3 "$OCV/gen/ocv_gen.py" --uvm "$W/fast/desc.json" -o "$W/gen" > /dev/null
NAME=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$W/fast/desc.json")
cat > "$W/harness.c" <<'CEOF'
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "ocv_uvm_check.h"
#undef OCV_UVM_CHECKER_CMP
#undef OCV_UVM_CHECKER_BRK
#define OCV_UVM_CHECKER_CMP(a, b, c)
#define OCV_UVM_CHECKER_BRK(a, b)
static int vals[13], timer_calls; static int timer_val;
void scr1_ref_step_all(int *a0, int *a1, int *a2, int *a3, int *a4, int *a5, int *a6, int *a7, int *a8, int *a9,
                       int *a10, int *a11, int *a12)
{
    int *a[13] = {a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12};
    for (int i = 0; i < 13; i++) *a[i] = vals[i];
}
void scr1_ref_timer(int v) { timer_calls++; timer_val = v; }
#define board_ref board_ref_fast
#define board_cmp board_cmp_fast
#define board_brk board_brk_fast
#include "fast/board_ref.c"
#undef board_ref
#undef board_cmp
#undef board_brk
#define board_ref board_ref_generic
#define board_cmp board_cmp_generic
#define board_brk board_brk_generic
#include "generic/board_ref.c"
static uint64_t s = 88172645463325252ull;
static uint32_t rnd(void) { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return (uint32_t)s; }
int main(void)
{
    uint32_t dut[32], e1[32], e2[32];
    for (long n = 0; n < 1000000; n++) {
        for (int i = 0; i < 13; i++) vals[i] = (int)rnd();
        for (int i = 0; i < 32; i++) dut[i] = rnd();
        if (n & 1) dut[3] = (dut[3] & ~(0x1FFFu << 6)) | (1u << 6) | ((0xC00u + (rnd() & 2)) << 7);  /* a counter read */
        memset(e1, 0, sizeof e1); memset(e2, 0, sizeof e2);
        timer_calls = 0;
        int r1 = board_ref_fast(dut, e1); int t1 = timer_calls, v1 = timer_val;
        timer_calls = 0;
        int r2 = board_ref_generic(dut, e2); int t2 = timer_calls, v2 = timer_val;
        if (memcmp(e1, e2, sizeof e1) || r1 != r2 || t1 != t2 || (t1 && v1 != v2)) {
            printf("t_board_ref: MISMATCH at %ld\n", n);
            for (int i = 0; i < 8; i++) printf("  w%d fast %08x generic %08x\n", i, e1[i], e2[i]);
            return 1;
        }
    }
    printf("t_board_ref: 1000000 records, layout constants == field descriptors\n");
    return 0;
}
CEOF
cc -std=gnu99 -O2 -w -I"$OCV/sw/include" -I"$OCV/uvm" -I"$W/gen" -I"$W" -include "$W/gen/${NAME}_ocv_meta.h" \
    -DOCV_UVM_DUT="${NAME}_dut" "$W/harness.c" "$OCV/uvm/ocv_uvm_check.c" "$OCV/sw/lib/ocv.c" -o "$W/t"
"$W/t"
