/* ocv_uvm_tap.h - the record selection for a UVM testbench's coverage on the board (uvm/ocv_uvm_runner.c).
 *
 * On the board the records of a channel the model checks never become UVM objects: the runner compares them in C
 * (squash windows). The testbench's coverage subscribers of that channel (uvm/ocv_uvm_pkg.sv, rule 7) get instead the
 * model's records (the same as the DUT's in a passing run), thinned to what can change their coverage:
 *
 *   fields F, history K   a record goes on when the projection of it and of the K records before it on the fields F
 *                         (those the subscribers read: uvm/ocv_contract.py) is one not seen before. Its K
 *                         predecessors go with it as context records (the covergroups off while they are written:
 *                         the subscribers' state - the last K records - is then the one it had in the full stream);
 *                         ones already sent are not sent again. K = 0: a subscriber without state - only the records
 *                         with a new projection.
 *   all                   every record (a subscriber whose state is not the last K records).
 *
 * Exact: every bin a covergroup of such a subscriber hits on the full stream it hits on the selection, and no other
 * (the bins depend on the projection of the record and of its history alone). Not kept: how often a bin was hit.
 * A projection is known by a 128-bit fingerprint of it (two independent 64-bit hashes); a collision would drop a
 * record - at 2^-64 per pair of distinct projections, as for the record filter's level 1 (docs/COVERAGE.md).
 */
#ifndef OCV_UVM_TAP_H
#define OCV_UVM_TAP_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define OCV_TAP_WORDS 32                       /* = REC_WORDS of the UVM layer */
#define OCV_TAP_HIST  8                        /* the longest history */

typedef struct {
    int      on, all, hist;
    uint32_t words, mask[OCV_TAP_WORDS];
    uint64_t h1[OCV_TAP_HIST + 1], h2[OCV_TAP_HIST + 1];   /* the projections of the last hist+1 records (ring) */
    uint32_t rec[OCV_TAP_HIST + 1][OCV_TAP_WORDS];         /* and the records */
    uint64_t n;                                /* records seen */
    uint64_t sent_to;                          /* records [0, sent_to) are sent or passed over */
    uint64_t *set; size_t cap, cnt;            /* the fingerprints seen: pairs, open addressing; (0, 0) empty */
    uint64_t passed, context;
} ocv_tap_t;

static inline uint64_t ocv_tap_mix(uint64_t x)
{
    x ^= x >> 30; x *= 0xBF58476D1CE4E5B9ull; x ^= x >> 27; x *= 0x94D049BB133111EBull; x ^= x >> 31;
    return x;
}

/* 1 when (a, b) was not in the set (it is now) */
static inline int ocv_tap_insert(ocv_tap_t *t, uint64_t a, uint64_t b)
{
    if (!a && !b) a = 1;
    if (2 * (t->cnt + 1) > t->cap) {
        const size_t cap = t->cap ? 2 * t->cap : 4096;
        uint64_t *s = calloc(cap * 2, sizeof *s);
        if (!s) { perror("ocv_uvm_tap"); exit(1); }
        for (size_t i = 0; i < t->cap; i++) {
            const uint64_t x = t->set[2 * i], y = t->set[2 * i + 1];
            if (!x && !y) continue;
            size_t j = (size_t)ocv_tap_mix(x ^ y) & (cap - 1);
            while (s[2 * j] || s[2 * j + 1]) j = (j + 1) & (cap - 1);
            s[2 * j] = x; s[2 * j + 1] = y;
        }
        free(t->set);
        t->set = s; t->cap = cap;
    }
    size_t j = (size_t)ocv_tap_mix(a ^ b) & (t->cap - 1);
    for (;;) {
        const uint64_t x = t->set[2 * j], y = t->set[2 * j + 1];
        if (!x && !y) break;
        if (x == a && y == b) return 0;
        j = (j + 1) & (t->cap - 1);
    }
    t->set[2 * j] = a; t->set[2 * j + 1] = b;
    t->cnt++;
    return 1;
}

/* one record of the channel, in order: out(arg, rec, context) for each record to send */
static inline void ocv_tap_record(ocv_tap_t *t, const uint32_t *rec,
                                  void (*out)(void *arg, const uint32_t *rec, int context), void *arg)
{
    const int H = t->hist, R = H + 1;
    const uint32_t slot = (uint32_t)(t->n % (uint64_t)R);
    if (t->all) {
        out(arg, rec, 0);
        t->passed++;
        t->n++;
        t->sent_to = t->n;
        return;
    }
    uint64_t a = 0x243F6A8885A308D3ull, b = 0x13198A2E03707344ull;
    for (uint32_t w = 0; w < t->words; w++) {
        const uint64_t v = rec[w] & t->mask[w];
        a = ocv_tap_mix(a ^ (v | (uint64_t)w << 32));
        b = ocv_tap_mix(b + v * 0x9E3779B97F4A7C15ull + w);
    }
    t->h1[slot] = a; t->h2[slot] = b;
    if (H) memcpy(t->rec[slot], rec, t->words * 4u);
    /* the projection with its history: the records before the first count as "none" (a fixed value) */
    uint64_t ka = a, kb = b;
    for (int k = 1; k <= H; k++) {
        uint64_t pa = 0x452821E638D01377ull, pb = 0xBE5466CF34E90C6Cull;
        if (t->n >= (uint64_t)k) { const uint32_t s = (uint32_t)((t->n - (uint64_t)k) % (uint64_t)R); pa = t->h1[s]; pb = t->h2[s]; }
        ka = ocv_tap_mix(ka * 31u ^ pa);
        kb = ocv_tap_mix(kb + pb * 0xC2B2AE3D27D4EB4Full);
    }
    if (ocv_tap_insert(t, ka, kb)) {
        uint64_t from = t->n >= (uint64_t)H ? t->n - (uint64_t)H : 0;
        if (from < t->sent_to) from = t->sent_to;
        for (uint64_t i = from; i < t->n; i++) { out(arg, t->rec[i % (uint64_t)R], 1); t->context++; }
        out(arg, rec, 0);
        t->passed++;
        t->sent_to = t->n + 1;
    }
    t->n++;
}

#endif /* OCV_UVM_TAP_H */
