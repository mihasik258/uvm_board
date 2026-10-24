/* ocv_cov_filter.c - the coverage-keeping record filter (ocv_cov_filter.h; docs/COVERAGE.md, 2.3). The model's
 * twin of tools/cov/cov_filter_proto.py (the same records kept, checked in test_all.sh):
 *   - a record's components: refinements of the fields isacov's monitor gives the covergroups (tools/cov/cov_proj.py
 *     comps, the same order and values; checked against the monitor by tools/cov/cov_check.py);
 *   - level 1: the vector of the components the projections read, with the previous history record's, by a
 *     128-bit fingerprint - a vector seen before gives nothing new;
 *   - level 2, for a new vector: each projection (the components a coverpoint or cross reads, from the table),
 *     prefixed by the name, trap and interrupt flag, exactly - a value not seen before keeps the record;
 *   - bit-wise coverpoints: per name, trap, interrupt flag and field, the bits seen 1 and seen 0;
 *   - an interrupt's first record: always;
 *   - before a kept record, the records back to the third one before that moved isacov's history (not already
 *     written), flagged as context.
 * Instruction names: Spike's table searched as Spike does (tools/cov/spike_table.cpp), memoized per word. */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L               /* strdup, strtok_r */
#endif
#include <stdlib.h>
#include <string.h>

#include "ocv_cov_filter.h"

/* the components (cov_proj.py COMPS) */
enum { C_M, C_MA, C_T, C_R1, C_R2, C_RD, C_W, C_RDA, C_R1A, C_R2A, C_CSR, C_R1F, C_CW, C_EQ_RD_R1, C_EQ_RD_R2,
       C_EQ_RDA_R1A, C_EQ_RDA_R2A, C_C1, C_C2, C_CD, C_V2LOW, C_REL, C_IMMC, C_IMM5, C_INTR, C_MCAUSE, C_MSTATUS,
       C_MIE, C_MIP, C_INSN6_0, C_INSN14_12, C_INSN31_25, C_NR1, C_NR2, C_NRD, C_HZ, C_N };
static const char *const comp_names[C_N] = {
    "M", "MA", "T", "R1", "R2", "RD", "W", "RDA", "R1A", "R2A", "CSR", "R1F", "CW", "EQ_RD_R1", "EQ_RD_R2",
    "EQ_RDA_R1A", "EQ_RDA_R2A", "C1", "C2", "CD", "V2LOW", "REL", "IMMC", "IMM5", "INTR", "MCAUSE", "MSTATUS",
    "MIE", "MIP", "INSN6_0", "INSN14_12", "INSN31_25", "NR1", "NR2", "NRD", "HZ" };

#define PROJ_MAX   256
#define PROJ_W     16                          /* components of one projection, at most */
#define PREV       0x100                       /* a component of the previous history record */
#define BIT_N      9                           /* bit-wise fields: a b d r1 i s b u j */
#define RING       64

/* a set of fixed-size keys (words; the first never 0: 0 marks a free slot), open addressing; insert: 1 when
 * the key is new */
typedef struct { uint32_t *k; size_t cap, n; int w; } set_t;
static set_t    vecs, values;                 /* level 1 (fingerprints), level 2 */

/* ---------------- the table ---------------- */
typedef struct { uint32_t match, mask; int name; } insn_t;
static insn_t  *insns;
static int      n_insns, bucket_at[257];      /* bucket b: insns[bucket_at[b] .. bucket_at[b + 1]) */
static char   **names;                        /* name ids: names[0] = "unknown" */
static int      n_names;
static uint8_t *hist_normal, *hist_ee;        /* per name id: moves isacov's history (normal / trapping ecall) */
static uint16_t proj[PROJ_MAX][PROJ_W];
static int      proj_w[PROJ_MAX], proj_prev[PROJ_MAX], n_proj;
static uint8_t  used[C_N], used_prev[C_N];    /* the components projections read: this record's, the previous */
static int      n_used, n_used_prev;
static int      bitf[BIT_N], n_bitf;          /* 0..4: the immediates i s b u j, 5 rs1, 6 rs2, 7 rd value, 8 rs1 */
static int      active;

static int name_id(const char *s)
{
    for (int i = 0; i < n_names; i++)
        if (!strcmp(names[i], s)) return i;
    names = realloc(names, (size_t)(n_names + 1) * sizeof *names);
    if (!names || !(names[n_names] = strdup(s))) { perror("cov_filter"); exit(1); }
    return n_names++;
}

static int comp_id(const char *s)
{
    int prev = 0;
    if (!strncmp(s, "prev.", 5)) { prev = PREV; s += 5; }
    for (int i = 0; i < C_N; i++)
        if (!strcmp(comp_names[i], s)) return i | prev;
    return -1;
}

int cov_filter_open(const char *table)
{
    FILE *f = fopen(table, "r");
    if (!f) { perror(table); return 1; }
    char line[8192];
    int cap = 0, prev_b = -1, bad = 0;
    n_names = 0;
    name_id("unknown");
    hist_normal = hist_ee = NULL;
    char *hn = NULL, *he = NULL;              /* the history lines, applied once every name is known */
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        char *save, *w = strtok_r(line, " ", &save);
        if (!w || w[0] == '#') continue;
        if (!strcmp(w, "insn")) {             /* insn <bucket> <match> <mask> <name> (buckets in order) */
            char *b = strtok_r(0, " ", &save), *m = strtok_r(0, " ", &save), *k = strtok_r(0, " ", &save);
            if (!b || !m || !k || !save) { bad = 1; break; }
            const int bi = atoi(b);
            if (bi < prev_b || bi > 255) { bad = 1; break; }
            if (n_insns == cap && !(insns = realloc(insns, (size_t)(cap = cap ? 2 * cap : 1024) * sizeof *insns))) {
                perror("cov_filter"); exit(1);
            }
            for (int x = prev_b + 1; x <= bi; x++) bucket_at[x] = n_insns;
            prev_b = bi;
            insns[n_insns].match = (uint32_t)strtoul(m, 0, 16);
            insns[n_insns].mask = (uint32_t)strtoul(k, 0, 16);
            insns[n_insns++].name = name_id(save);   /* (the rest of the line: a name may hold spaces) */
        } else if (!strcmp(w, "proj")) {      /* proj <component>... */
            if (n_proj == PROJ_MAX) { bad = 1; break; }
            int n = 0, c;
            proj_prev[n_proj] = 0;
            while ((w = strtok_r(0, " ", &save))) {
                if (n == PROJ_W || (c = comp_id(w)) < 0) { bad = 1; break; }
                proj[n_proj][n++] = (uint16_t)c;
                if (c & PREV) proj_prev[n_proj] = 1;
            }
            proj_w[n_proj++] = n;
        } else if (!strcmp(w, "bit")) {       /* bit <field>... */
            static const char *const bn[BIT_N] = { "0", "1", "2", "3", "4", "a", "b", "d", "r1" };
            while ((w = strtok_r(0, " ", &save))) {
                int i = 0;
                while (i < BIT_N && strcmp(bn[i], w)) i++;
                if (i == BIT_N) { bad = 1; break; }
                bitf[n_bitf++] = i;
            }
        } else if (!strcmp(w, "hist")) {      /* hist normal|ecall_or_ebreak <name>... */
            w = strtok_r(0, " ", &save);
            if (!w) { bad = 1; break; }
            char **h = !strcmp(w, "normal") ? &hn : !strcmp(w, "ecall_or_ebreak") ? &he : NULL;
            if (!h) { bad = 1; break; }
            free(*h);
            *h = strdup(save ? save : "");
        } else {
            bad = 1;
        }
        if (bad) break;
    }
    fclose(f);
    for (int x = prev_b + 1; x <= 256; x++) bucket_at[x] = n_insns;
    if (bad || !n_insns || !n_proj) { fprintf(stderr, "%s: not a filter table (tools/cov/cov_filter_gen.py)\n", table); return 1; }
    if (!(hist_normal = calloc((size_t)n_names, 1)) || !(hist_ee = calloc((size_t)n_names, 1))) { perror("cov_filter"); exit(1); }
    for (int k = 0; k < 2; k++) {
        char *s = k ? he : hn, *save, *w;
        for (w = s ? strtok_r(s, " ", &save) : NULL; w; w = strtok_r(0, " ", &save))
            for (int i = 0; i < n_names; i++)
                if (!strcmp(names[i], w)) (k ? hist_ee : hist_normal)[i] = 1;
    }
    free(hn); free(he);
    /* level 1 reads the components some projection reads (this record's, the previous one's) */
    n_used = n_used_prev = 0;
    for (int x = 0; x < C_N; x++) {
        int cur = x == C_M || x == C_T || x == C_INTR, prev = 0;    /* (and the key of every projection) */
        for (int p = 0; p < n_proj; p++)
            for (int i = 0; i < proj_w[p]; i++) {
                if (proj[p][i] == x) cur = 1;
                if (proj[p][i] == (x | PREV)) prev = 1;
            }
        if (cur) used[n_used++] = (uint8_t)x;
        if (prev) used_prev[n_used_prev++] = (uint8_t)x;
    }
    vecs.w = 4;                               /* the sets' key sizes: a fingerprint, the widest projection */
    values.w = 4;
    for (int p = 0; p < n_proj; p++)
        if (4 + proj_w[p] > values.w) values.w = 4 + proj_w[p];
    active = 1;
    return 0;
}

/* ---------------- hash sets ---------------- */
static uint64_t mix(uint64_t h)
{
    h ^= h >> 33; h *= 0xff51afd7ed558ccdull; h ^= h >> 33; h *= 0xc4ceb9fe1a85ec53ull; h ^= h >> 33;
    return h;
}

/* a word sequence's hash: a multiply and a shift per word, the full mix at the end; k: the multiplier */
#define K1 0x9e3779b97f4a7c15ull
#define K2 0xd6e8feb86659fd93ull
static uint64_t hash_words(const uint32_t *w, int n, uint64_t seed, uint64_t k)
{
    uint64_t h = seed + (uint64_t)n;
    for (int i = 0; i < n; i++) { h = (h ^ w[i]) * k; h ^= h >> 31; }
    return mix(h);
}

/* both lanes of a word sequence in one pass, two words a step (the level-1 fingerprint) */
static void hash_lanes(const uint32_t *w, int n, uint64_t seed, uint64_t *h1, uint64_t *h2)
{
    uint64_t a = seed + (uint64_t)n, b = ~seed + (uint64_t)n;
    int i = 0;
    for (; i + 1 < n; i += 2) {
        const uint64_t x = w[i] | (uint64_t)w[i + 1] << 32;
        a = (a ^ x) * K1; a ^= a >> 31;
        b = (b ^ x) * K2; b ^= b >> 29;
    }
    if (i < n) { a = (a ^ w[i]) * K1; a ^= a >> 31; b = (b ^ w[i]) * K2; b ^= b >> 29; }
    *h1 = mix(a); *h2 = mix(b);
}

/* a key's hash: its words up to the last non-zero one (a projection's value is padded with zeros) */
static uint64_t hash_key(const uint32_t *w, int n)
{
    while (n > 0 && !w[n - 1]) n--;
    return hash_words(w, n, 0, K1);
}

static int set_insert(set_t *s, const uint32_t *key)
{
    if (2 * (s->n + 1) > s->cap) {            /* grow: rehash every key */
        set_t t = { 0, s->cap ? 2 * s->cap : 1u << 12, 0, s->w };
        if (!(t.k = calloc(t.cap * (size_t)t.w, sizeof *t.k))) { perror("cov_filter"); exit(1); }
        for (size_t i = 0; i < s->cap; i++)
            if (s->k[i * (size_t)s->w]) set_insert(&t, s->k + i * (size_t)s->w);
        free(s->k);
        *s = t;
    }
    for (size_t i = (size_t)hash_key(key, s->w) & (s->cap - 1);; i = (i + 1) & (s->cap - 1)) {
        uint32_t *k = s->k + i * (size_t)s->w;
        if (!k[0]) {
            memcpy(k, key, (size_t)s->w * sizeof *k);
            s->n++;
            return 1;
        }
        if (!memcmp(k, key, (size_t)s->w * sizeof *k)) return 0;
    }
}

/* ---------------- names ---------------- */
static int spike_name(uint32_t w)
{
    const int b[3] = { (int)((w & 0x7f) % 255), (int)((w & 0xe003) % 255), 255 };
    for (int j = 0; j < 3; j++)
        for (int i = bucket_at[b[j]]; i < bucket_at[b[j] + 1]; i++)
            if ((w & insns[i].mask) == insns[i].match) return insns[i].name;
    return 0;
}

static uint32_t *memo_w, *memo_id;            /* word -> name id + 1 (0: empty) */
static size_t    memo_cap, memo_n;

static int name_of(uint32_t w)
{
    if (2 * (memo_n + 1) > memo_cap) {
        uint32_t *ow = memo_w, *oi = memo_id;
        const size_t oc = memo_cap;
        memo_cap = oc ? 2 * oc : 1u << 14;
        if (!(memo_w = calloc(memo_cap, sizeof *memo_w)) || !(memo_id = calloc(memo_cap, sizeof *memo_id))) { perror("cov_filter"); exit(1); }
        memo_n = 0;
        for (size_t i = 0; i < oc; i++)
            if (oi[i]) {
                size_t j = (size_t)mix(ow[i] * K1) & (memo_cap - 1);
                while (memo_id[j]) j = (j + 1) & (memo_cap - 1);
                memo_w[j] = ow[i]; memo_id[j] = oi[i]; memo_n++;
            }
        free(ow); free(oi);
    }
    size_t j = (size_t)mix(w * K1) & (memo_cap - 1);
    while (memo_id[j]) {
        if (memo_w[j] == w) return (int)memo_id[j] - 1;
        j = (j + 1) & (memo_cap - 1);
    }
    const int id = spike_name(w);
    memo_w[j] = w; memo_id[j] = (uint32_t)id + 1; memo_n++;
    return id;
}

/* ---------------- components (cov_proj.py comps, hazards) ---------------- */
static uint32_t vclass(uint32_t v)
{
    return v == 0 ? 0 : v == 1 ? 1 : v == 0xffffffffu ? 2 : v == 0x80000000u ? 3 : v >> 31 ? 4 : 5;
}

static uint32_t cls3(uint32_t v, int bits) { return v == 0 ? 0 : v >> (bits - 1) ? 1 : 2; }

/* the immediates as isacov's monitor keeps them (cov_proj.py imms) */
static void imms(uint32_t w, uint32_t im[5])
{
    if ((w & 3) != 3) { memset(im, 0, 5 * sizeof *im); return; }
    im[0] = w >> 20;
    im[1] = ((w >> 25) << 5) | ((w >> 7) & 31);
    im[2] = (((w >> 31) & 1) << 11) | (((w >> 7) & 1) << 10) | (((w >> 25) & 63) << 4) | ((w >> 8) & 15);
    im[3] = w >> 12;
    im[4] = (((w >> 31) & 1) << 19) | (((w >> 12) & 255) << 11) | (((w >> 20) & 1) << 10) | ((w >> 21) & 1023);
}

static void comps(const uint32_t *r, int name, uint32_t *c)
{
    const uint32_t w = r[0];
    const int cw = (w & 3) != 3;
    uint32_t im[5];
    imms(w, im);
    const int32_t sa = (int32_t)r[4], sb = (int32_t)r[6];
    c[C_M] = (uint32_t)name; c[C_MA] = r[9] & 3; c[C_T] = r[2];
    c[C_R1] = cw ? w : r[3]; c[C_R2] = cw ? w : r[5]; c[C_RD] = cw ? w : (w >> 7) & 31; c[C_W] = w;
    c[C_RDA] = r[7]; c[C_R1A] = r[3]; c[C_R2A] = r[5];
    c[C_CSR] = (w & 0x7f) == 0x73 ? w >> 20 : 0; c[C_R1F] = (w & 0x7f) == 0x73 ? (w >> 15) & 31 : 0;
    c[C_CW] = cw ? w : 0;
    c[C_EQ_RD_R1] = cw ? w : ((w >> 7) & 31) == r[3]; c[C_EQ_RD_R2] = cw ? w : ((w >> 7) & 31) == r[5];
    c[C_EQ_RDA_R1A] = r[7] == r[3]; c[C_EQ_RDA_R2A] = r[7] == r[5];
    c[C_C1] = vclass(r[4]); c[C_C2] = vclass(r[6]); c[C_CD] = vclass(r[8]); c[C_V2LOW] = r[6] & 31;
    c[C_REL] = (uint32_t)((r[4] == r[6]) | ((sa < sb) << 1) | ((r[4] < r[6]) << 2));
    c[C_IMMC] = cls3(im[0], 12) | cls3(im[1], 12) << 2 | cls3(im[2], 12) << 4 | cls3(im[3], 20) << 6 | cls3(im[4], 20) << 8;
    c[C_IMM5] = (w >> 20) & 31;
    c[C_INTR] = r[10]; c[C_MCAUSE] = r[11]; c[C_MSTATUS] = r[12]; c[C_MIE] = r[13]; c[C_MIP] = r[14];
    c[C_INSN6_0] = w & 0x7f; c[C_INSN14_12] = (w >> 12) & 7; c[C_INSN31_25] = w >> 25;
    c[C_NR1] = cw ? (w >> 7) & 31 : (w >> 15) & 31; c[C_NR2] = cw ? (w >> 2) & 31 : (w >> 20) & 31;
    c[C_NRD] = (w >> 7) & 31;
}

/* ---------------- the filter ---------------- */
static uint32_t prev_c[C_N];
static uint64_t prev_h1, prev_h2;             /* its level-1 lanes */
static int      have_prev;
static uint64_t n_rec, n_kept, n_ctx, last_out;
static struct { uint32_t r[COV_REC_N]; int moves; uint64_t n; } ring[RING];
static int      ring_n, ring_head;            /* ring[(ring_head + i) % RING], i < ring_n: oldest first */

void cov_rvfi_line(FILE *out, const uint32_t r[COV_REC_N], int context)
{
    fprintf(out, "%x %x %x %x %x %x %x %x %x %x %x %x %x %x %x%s\n", r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7],
            r[8], r[9], r[10], r[11], r[12], r[13], r[14], context ? " 1" : "");
}

/* the bit-wise masks of (M, trap, interrupt flag): per field the bits seen 1 and seen 0 -
 * [M T intr used s1[BIT_N] s0[BIT_N]] */
#define MASK_W (4 + 2 * BIT_N)
static uint32_t *masks;
static size_t    masks_cap, masks_n;

static uint32_t *mask_entry(const uint32_t key[3])
{
    if (2 * (masks_n + 1) > masks_cap) {
        uint32_t *o = masks;
        const size_t oc = masks_cap;
        masks_cap = oc ? 2 * oc : 1u << 10;
        if (!(masks = calloc(masks_cap * MASK_W, sizeof *masks))) { perror("cov_filter"); exit(1); }
        masks_n = 0;
        for (size_t i = 0; i < oc; i++)
            if (o[MASK_W * i + 3]) memcpy(mask_entry(o + MASK_W * i), o + MASK_W * i, MASK_W * sizeof *o);
        free(o);
    }
    for (size_t j = (size_t)hash_words(key, 3, 1, K1) & (masks_cap - 1);; j = (j + 1) & (masks_cap - 1)) {
        uint32_t *e = masks + MASK_W * j;
        if (!e[3]) { memcpy(e, key, 3 * sizeof *e); e[3] = 1; masks_n++; return e; }
        if (!memcmp(e, key, 3 * sizeof *e)) return e;
    }
}

void cov_filter_record(FILE *out, const uint32_t r[COV_REC_N])
{
    if (!active) { cov_rvfi_line(out, r, 0); return; }
    n_rec++;
    const int name = name_of(r[0]);
    uint32_t c[C_N];
    comps(r, name, c);
    c[C_HZ] = have_prev ? (uint32_t)((prev_c[C_NRD] == c[C_NR1]) | (prev_c[C_NRD] == c[C_NR2]) << 1 |
                                     (prev_c[C_NRD] == 0) << 2) : 0;
    int keep = r[10] != 0;                    /* an interrupt's first record: always */
    /* level 1: this record's components and the previous history record's (128-bit fingerprint; the previous
     * record's lanes kept from when it was this one) */
    uint32_t fp[4], u[C_N] = { 0 };
    for (int i = 0; i < n_used; i++) u[i] = c[used[i]];
    uint64_t c1, c2;
    hash_lanes(u, n_used, 5, &c1, &c2);
    const uint64_t h1 = mix(c1 ^ (have_prev ? prev_h1 * K2 : 0x5bd1e995ull));
    const uint64_t h2 = mix(c2 ^ (have_prev ? prev_h2 * K1 : 0x27d4eb2full));
    fp[0] = (uint32_t)h1 | 1; fp[1] = (uint32_t)(h1 >> 32); fp[2] = (uint32_t)h2; fp[3] = (uint32_t)(h2 >> 32);
    if (set_insert(&vecs, fp)) {
        /* level 2: each projection's value, exactly: [proj + 1 | has_prev << 16, M, T, intr, v...] */
        uint32_t k[4 + PROJ_W];
        for (int p = 0; p < n_proj; p++) {
            memset(k, 0, (size_t)values.w * sizeof *k);
            k[0] = (uint32_t)(p + 1) | (uint32_t)(proj_prev[p] && have_prev) << 16;
            k[1] = c[C_M]; k[2] = c[C_T]; k[3] = r[10];
            for (int i = 0; i < proj_w[p]; i++) {
                const int x = proj[p][i];
                k[4 + i] = (x & PREV) ? (have_prev ? prev_c[x & ~PREV] : 0) : c[x];
            }
            if (set_insert(&values, k)) keep = 1;
        }
    }
    /* bit-wise fields: a bit not seen 1 / 0 before (per name, trap, interrupt flag) */
    if (n_bitf) {
        uint32_t im[5];
        imms(r[0], im);
        const uint32_t src[BIT_N] = { im[0], im[1], im[2], im[3], im[4], r[4], r[6], r[8], r[3] };
        const uint32_t key[3] = { c[C_M], c[C_T], r[10] };
        uint32_t *e = mask_entry(key), *s1 = e + 4, *s0 = e + 4 + BIT_N;
        for (int i = 0; i < n_bitf; i++) {
            const uint32_t v = src[bitf[i]];
            if ((v & ~s1[i]) || (~v & ~s0[i])) { s1[i] |= v; s0[i] |= ~v; keep = 1; }
        }
    }
    /* isacov's sample(): a normal record of a name its normal branches take, a trapping ecall/ebreak */
    const int moves = ((r[2] & 1) == 0 && hist_normal[name]) ||
                      ((r[2] >> 1 == 3 || r[2] >> 1 == 8 || r[2] >> 1 == 11) && hist_ee[name]);
    if (keep) {
        n_kept++;
        int start = ring_n, nn = 0;
        while (start > 0 && nn < 3) {
            start--;
            if (ring[(ring_head + start) % RING].moves) nn++;
        }
        for (int i = start; i < ring_n; i++) {
            const int s = (ring_head + i) % RING;
            if (ring[s].n > last_out) { cov_rvfi_line(out, ring[s].r, 1); n_ctx++; }
        }
        cov_rvfi_line(out, r, 0);
        last_out = n_rec;
    }
    const int s = ring_n < RING ? (ring_head + ring_n++) % RING : (ring_head++ % RING);
    if (ring_head >= RING) ring_head -= RING;
    memcpy(ring[s].r, r, sizeof ring[s].r);
    ring[s].moves = moves;
    ring[s].n = n_rec;
    if (moves) {
        memcpy(prev_c, c, sizeof prev_c);
        for (int i = 0; i < n_used_prev; i++) u[i] = c[used_prev[i]];
        hash_lanes(u, n_used_prev, 3, &prev_h1, &prev_h2);
        have_prev = 1;
    }
}

void cov_filter_report(void)
{
    if (!active) return;
    fprintf(stderr, "cov_filter: records %llu kept %llu context %llu vectors %zu projection values %zu\n",
            (unsigned long long)n_rec, (unsigned long long)n_kept, (unsigned long long)n_ctx, vecs.n, values.n);
}
