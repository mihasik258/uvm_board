/* ocv_busbench.c - price of PS accesses to the hub window on the board, by access pattern.
 *
 *   ocv_busbench --base 0x80000000 [--span 0x100000] [--slot N] [--n COUNT]
 *
 * Reads the same register, walks the hub registers, reads one buffer word over and over, walks a
 * buffer, and does the same for writes (to the THROTTLE register, restored). --slot picks the
 * endpoint whose buffer is read (default 1). Also compares a volatile 32-bit loop with memcpy of
 * the window, to see whether wider accesses help. Nothing here depends on the DUT.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ocv_bus_mmap.h"
#include "ocv_regs.h"

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    uint64_t base = 0;
    size_t span = 1u << 20;
    unsigned slot = 1, n = 100000;
    for (int i = 1; i + 1 < argc; i += 2) {
        if      (!strcmp(argv[i], "--base")) base = strtoull(argv[i + 1], 0, 0);
        else if (!strcmp(argv[i], "--span")) span = strtoull(argv[i + 1], 0, 0);
        else if (!strcmp(argv[i], "--slot")) slot = (unsigned)strtoul(argv[i + 1], 0, 0);
        else if (!strcmp(argv[i], "--n"))    n = (unsigned)strtoul(argv[i + 1], 0, 0);
    }
    if (!base) { fprintf(stderr, "usage: %s --base <hub address> [--span B] [--slot N] [--n N]\n", argv[0]); return 1; }
    ocv_bus_t bus;
    if (ocv_bus_mmap_open(&bus, base, span)) return 1;
    volatile uint32_t *w = bus.priv;

    uint32_t layout = w[OCV_HUB_REG_LAYOUT / 4];
    uint32_t sbase = slot << OCV_LAYOUT_SLOT_LOG2(layout);
    uint32_t g = w[(sbase + OCV_EP_REG_GEOMETRY) / 4];
    uint32_t boff = sbase + (uint32_t)OCV_GEOM_BUF_OFFSET(g);
    uint32_t bwords = (1u << OCV_GEOM_LOG2_DEPTH(g)) << OCV_GEOM_LOG2_STRIDE(g);
    if (w[OCV_HUB_REG_ID / 4] != OCV_HUB_ID_VALUE || w[(sbase + OCV_EP_REG_ID) / 4] != OCV_EP_ID_VALUE) {
        fprintf(stderr, "no hub / no endpoint in slot %u\n", slot);
        return 1;
    }
    printf("slot %u buffer: %u words at offset 0x%x\n", slot, bwords, boff);
    volatile uint32_t sink = 0;
    double t;

#define BENCH(label, body) \
    t = now(); for (unsigned i = 0; i < n; i++) { body; } \
    printf("  %-44s %6.0f ns\n", label, (now() - t) / n * 1e9)

    BENCH("read: same register (ID)", sink += w[0]);
    BENCH("read: hub registers 0..6 in turn", sink += w[i % 7]);
    BENCH("read: same buffer word", sink += w[boff / 4]);
    BENCH("read: buffer words in order", sink += w[boff / 4 + i % bwords]);
    BENCH("read: 4 consecutive buffer words (per word)", { sink += w[boff / 4 + (i & ~3u) % bwords + (i & 3)]; });
    uint32_t thr = w[(sbase + OCV_EP_REG_THROTTLE) / 4];
    BENCH("write: same register (THROTTLE)", w[(sbase + OCV_EP_REG_THROTTLE) / 4] = thr);
    sink += w[0];

    /* memcpy of a whole buffer: lets the compiler/libc use wider loads */
    static uint32_t copy[1 << 16];
    unsigned words = bwords < (1u << 16) ? bwords : (1u << 16);
    unsigned reps = n / words ? n / words : 1;
    t = now();
    for (unsigned r = 0; r < reps; r++) memcpy(copy, (const void *)(w + boff / 4), words * 4);
    printf("  %-44s %6.0f ns\n", "read: memcpy of the buffer (per word)", (now() - t) / (reps * (double)words) * 1e9);
    /* copy loops into normal memory: the loads do not depend on each other, so the core can keep
     * several in flight; wider loads move more data per bus transaction. Each copy is checked
     * against the plain 32-bit read (the buffer must not change meanwhile: run after a run). */
    static uint32_t ref[1 << 16];
    for (unsigned k = 0; k < words; k++) ref[k] = w[boff / 4 + k];
    const char *names[3] = { "copy: 32-bit loads (per word)", "copy: 64-bit loads (per word)",
                             "copy: 128-bit loads, ldp (per word)" };
    for (int mode = 0; mode < 3; mode++) {
        memset(copy, 0, sizeof copy);
        t = now();
        for (unsigned r = 0; r < reps; r++) {
            if (mode == 0) {
                const volatile uint32_t *src = w + boff / 4;
                for (unsigned k = 0; k < words; k++) copy[k] = src[k];
            } else if (mode == 1) {
                const volatile uint64_t *src = (const volatile uint64_t *)(w + boff / 4);
                uint64_t *dst = (uint64_t *)copy;
                for (unsigned k = 0; k < words / 2; k++) dst[k] = src[k];
            } else {
                const volatile uint64_t *src = (const volatile uint64_t *)(w + boff / 4);
                uint64_t *dst = (uint64_t *)copy;
                for (unsigned k = 0; k < words / 2; k += 2) {
                    uint64_t a, b;
                    __asm__ volatile("ldp %0, %1, [%2]" : "=r"(a), "=r"(b) : "r"(src + k) : "memory");
                    dst[k] = a; dst[k + 1] = b;
                }
            }
        }
        double ns = (now() - t) / (reps * (double)words) * 1e9;
        printf("  %-44s %6.0f ns  %s\n", names[mode], ns, memcmp(copy, ref, words * 4) ? "DATA DIFFERS" : "data ok");
    }
    (void)sink;
    return 0;
}
