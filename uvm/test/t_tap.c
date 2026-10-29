/* t_tap.c - the coverage selection on the board (uvm/ocv_uvm_tap.h) is exact: a subscriber with a history of K
 * records sees, on the records the selection sends (context records with its covergroups off), the same set of
 * (record, K records before it) projections as on every record - here a random stream of 2 million records,
 * symbols of 4 bits read, one word not read. Exit 0 when the two sets are the same. */
#include "ocv_uvm_tap.h"
#include <assert.h>
#define K 3
static uint32_t hist[K]; static int nh;            /* the subscriber's view: last K delivered */
static char full[1<<20], got[1<<20];
static uint32_t gram(uint32_t cur, const uint32_t *h, int n) {   /* symbols < 16, "none" = 15 */
    uint32_t g = cur & 15;
    for (int k = 0; k < K; k++) g = g << 4 | (k < n ? (h[k] & 15) : 15);
    return g;
}
static void out(void *a, const uint32_t *rec, int ctx) {
    (void)a;
    if (!ctx) got[gram(rec[0], hist, nh)] = 1;
    for (int k = K - 1; k > 0; k--) hist[k] = hist[k - 1];
    hist[0] = rec[0]; if (nh < K) nh++;
}
int main(void) {
    ocv_tap_t t; memset(&t, 0, sizeof t);
    t.words = 2; t.mask[0] = 0xF; t.hist = K;           /* word 1 is not read: it varies freely */
    uint32_t fh[K] = { 0 }; int fn = 0; uint64_t seed = 7, N = 2000000;
    for (uint64_t i = 0; i < N; i++) {
        seed = seed * 6364136223846793005ull + 1442695040888963407ull;
        uint32_t r[2] = { (uint32_t)(seed >> 60) % 6, (uint32_t)(seed >> 20) };   /* 6 symbols: grams saturate */
        if (i % 1000 < 3) r[0] = 7 + (uint32_t)(i / 1000) % 5;                     /* rare ones */
        full[gram(r[0], fh, fn)] = 1;
        for (int k = K - 1; k > 0; k--) fh[k] = fh[k - 1];
        fh[0] = r[0]; if (fn < K) fn++;
        ocv_tap_record(&t, r, out, NULL);
    }
    int nf = 0, ng = 0, bad = 0;
    for (int g = 0; g < 1 << 20; g++) { nf += full[g]; ng += got[g]; bad += full[g] != got[g]; }
    printf("records %llu passed %llu context %llu; grams full %d tap %d differ %d\n", (unsigned long long)t.n,
           (unsigned long long)t.passed, (unsigned long long)t.context, nf, ng, bad);
    return bad != 0;
}
