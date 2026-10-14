/* ocv_uvm_check.c - registry and engine of the reference checkers (ocv_uvm_check.h). Linked in
 * every build of a UVM testbench on OCV: simulation calls ocv_dpi_check() per transaction from
 * ocv_checker; the board build's ocv_uvm_dpi.c calls ocv_check_record() as records arrive.
 * Build with -include <dut>_ocv_meta.h -DOCV_UVM_DUT=<dut>_dut.
 *
 * Squash (engine A, +OCV_SQUASH=N): a squashed channel delivers one fused record per window of N
 * {last record, count, CRC32C, CRC32}; the reference function then runs `count` times (dut = NULL:
 * single DUT records are not seen) and the window's signatures are compared. A window that differs
 * is located by running the whole program again with +OCV_SQUASH=1 (ocv_check_replay).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <unistd.h>

#include "ocv.h"
#include "ocv_uvm_check.h"

#define OCV_UVM_REC_WORDS 32
#define MAX_CH 256

typedef struct {
    uint32_t dut[OCV_UVM_REC_WORDS], exp[OCV_UVM_REC_WORDS];
    int      field;
    uint64_t index;                          /* the record's number in its channel, from 1 */
} miss_t;

static struct {
    const char      *name[MAX_CH];
    ocv_uvm_check_fn fn[MAX_CH];
    const ocv_uvm_cmp_t *cmp[MAX_CH];        /* the scoreboard's comparison, or NULL: the descriptor's */
    int              n_cmp[MAX_CH];
    int              n_reg;
    const ocv_uvm_cmp_t *cmp_by_ch[MAX_CH];
    int              n_cmp_by_ch[MAX_CH];
    const ocv_field_t *cmp_f[MAX_CH][64];    /* resolved fields of cmp_by_ch */
    ocv_uvm_check_fn by_ch[MAX_CH];          /* resolved against the DUT's channels */
    int              enabled[MAX_CH];        /* an ocv_checker of this channel is in the testbench */
    int              resolved;
    uint64_t         checked[MAX_CH], errors[MAX_CH];
    int              done[MAX_CH];
    miss_t          *miss[MAX_CH];           /* mismatches not yet shown to UVM (board) */
    uint32_t         mask[MAX_CH][OCV_UVM_REC_WORDS];   /* compared bits (squash signatures) */
    int              masked[MAX_CH];
    uint32_t         window;                 /* +OCV_SQUASH: records per fused record */
    int              sq_on[MAX_CH];          /* this channel's endpoint fuses windows */
    int              deliver[MAX_CH];        /* checked records also go on to UVM (coverage) */
    int              inexact[MAX_CH];        /* the scoreboard compares with a tolerance: no squash */
    const char      *brk_name[MAX_CH];       /* break patterns as registered, resolved by channel */
    const ocv_uvm_brk_t *brk_reg[MAX_CH];
    int              n_brk_reg[MAX_CH], n_breg;
    const ocv_uvm_brk_t *brk[MAX_CH];
    int              n_brk[MAX_CH];
    uint32_t        *dbuf;                   /* the window's records until its signatures match */
    size_t           dcap;
    uint32_t         n_miss[MAX_CH], cap_miss[MAX_CH], head_miss[MAX_CH];
} k;

void ocv_uvm_checker_cmp(const char *channel, ocv_uvm_check_fn fn, const ocv_uvm_cmp_t *cmp, int n_cmp)
{
    if (k.n_reg < MAX_CH) {
        k.name[k.n_reg] = channel; k.fn[k.n_reg] = fn; k.cmp[k.n_reg] = cmp; k.n_cmp[k.n_reg] = n_cmp;
        k.n_reg++;
    }
}

void ocv_uvm_checker(const char *channel, ocv_uvm_check_fn fn) { ocv_uvm_checker_cmp(channel, fn, NULL, 0); }

static void resolve(void);

void ocv_uvm_checker_brk(const char *channel, const ocv_uvm_brk_t *b, int n)
{
    if (k.n_breg < MAX_CH) { k.brk_name[k.n_breg] = channel; k.brk_reg[k.n_breg] = b; k.n_brk_reg[k.n_breg] = n; k.n_breg++; }
}

int ocv_check_breaks(int ch, uint32_t mask[][32], uint32_t value[][32])
{
    resolve();
    int np = 0;
    for (int i = 0; i < k.n_brk[ch]; i++) {
        const ocv_uvm_brk_t *b = &k.brk[ch][i];
        if (b->pat < 0 || b->pat >= 4) { fprintf(stderr, "ocv_uvm: break pattern %d (FPGA has 4)\n", b->pat); exit(2); }
        const ocv_field_t *f = ocv_uvm_field(OCV_UVM_DUT.channels[ch].name, b->field);
        uint32_t mw[32] = { 0 }, vw[32] = { 0 };
        ocv_set_raw(mw, f, b->mask);
        ocv_set_raw(vw, f, b->value & b->mask);
        for (int w = 0; w < 32; w++) { mask[b->pat][w] |= mw[w]; value[b->pat][w] |= vw[w]; }
        if (b->pat + 1 > np) np = b->pat + 1;
    }
    return np;
}

const ocv_field_t *ocv_uvm_field(const char *channel, const char *field)
{
    const ocv_dut_t *d = &OCV_UVM_DUT;
    for (int ch = 0; ch < d->n_channels; ch++)
        if (!strcmp(d->channels[ch].name, channel)) {
            const ocv_field_t *f = ocv_field(&d->channels[ch], field);
            if (f) return f;
        }
    fprintf(stderr, "ocv_uvm: no field '%s' in channel '%s' of '%s'\n", field, channel, d->name);
    exit(2);
}

static void resolve(void)
{
    if (k.resolved) return;
    const ocv_dut_t *d = &OCV_UVM_DUT;
    for (int i = 0; i < k.n_reg; i++) {
        int found = 0;
        for (int ch = 0; ch < d->n_channels; ch++)
            if (!strcmp(d->channels[ch].name, k.name[i])) {
                if (d->channels[ch].kind == OCV_CH_SOURCE) {
                    fprintf(stderr, "ocv_uvm: checker on '%s', a source channel\n", k.name[i]);
                    exit(2);
                }
                if (k.by_ch[ch] && k.by_ch[ch] != k.fn[i]) {
                    fprintf(stderr, "ocv_uvm: two reference functions for channel '%s'\n", k.name[i]);
                    exit(2);
                }
                k.by_ch[ch] = k.fn[i];
                if (k.cmp[i]) {
                    if (k.n_cmp[i] > 64) { fprintf(stderr, "ocv_uvm: too many compared fields\n"); exit(2); }
                    k.cmp_by_ch[ch] = k.cmp[i];
                    k.n_cmp_by_ch[ch] = k.n_cmp[i];
                    for (int j = 0; j < k.n_cmp[i]; j++)
                        k.cmp_f[ch][j] = ocv_uvm_field(k.name[i], k.cmp[i][j].field);
                    memset(k.mask[ch], 0, sizeof k.mask[ch]);   /* the scoreboard's bits */
                    k.inexact[ch] = 0;
                    for (int j = 0; j < k.n_cmp[i]; j++) {
                        uint32_t one[OCV_UVM_REC_WORDS] = { 0 };
                        if (k.cmp[i][j].kind != 0) { k.inexact[ch] = 1; continue; }   /* a tolerance: no signature */
                        ocv_set_raw(one, k.cmp_f[ch][j], k.cmp[i][j].bits);
                        for (int w = 0; w < OCV_UVM_REC_WORDS; w++) k.mask[ch][w] |= one[w];
                    }
                    k.masked[ch] = 1;
                }
                found = 1;
            }
        if (!found) { fprintf(stderr, "ocv_uvm: checker for unknown channel '%s'\n", k.name[i]); exit(2); }
    }
    for (int i = 0; i < k.n_breg; i++) {
        int found = 0;
        for (int ch = 0; ch < d->n_channels; ch++)
            if (!strcmp(d->channels[ch].name, k.brk_name[i])) {
                k.brk[ch] = k.brk_reg[i]; k.n_brk[ch] = k.n_brk_reg[i]; found = 1;
            }
        if (!found) { fprintf(stderr, "ocv_uvm: break patterns for unknown channel '%s'\n", k.brk_name[i]); exit(2); }
    }
    k.resolved = 1;
}

/* the channel is checked in C (1) or its transactions go to UVM monitors (0): a registered
 * function alone is not enough - the testbench must have an ocv_checker of the channel */
int ocv_check_active(int ch)
{
    resolve();
    return ch >= 0 && ch < MAX_CH && k.by_ch[ch] != NULL && k.enabled[ch];
}

/* check one record: index of the first mismatching field or -1; *exp gets the expected record */
static int check(int ch, const uint32_t *rec, uint32_t *exp, int *last)
{
    const ocv_channel_t *c = &OCV_UVM_DUT.channels[ch];
    memset(exp, 0, OCV_UVM_REC_WORDS * 4u);
    *last = k.by_ch[ch](rec, exp) == 1;
    k.checked[ch]++;
    if (*last) k.done[ch] = 1;
    int f = -1;
    if (k.cmp_by_ch[ch]) {                   /* the scoreboard's comparison: the first field that differs */
        for (int j = 0; j < k.n_cmp_by_ch[ch] && f < 0; j++) {
            const ocv_field_t *fl = k.cmp_f[ch][j];
            const ocv_uvm_cmp_t *cm = &k.cmp_by_ch[ch][j];
            if (cm->kind == 1) {                 /* |dut - model| <= tol */
                int64_t x = fl->is_signed ? ocv_get_int(rec, fl) : (int64_t)ocv_get_raw(rec, fl);
                int64_t y = fl->is_signed ? ocv_get_int(exp, fl) : (int64_t)ocv_get_raw(exp, fl);
                uint64_t d = x > y ? (uint64_t)x - (uint64_t)y : (uint64_t)y - (uint64_t)x;
                if (d > cm->tol) f = (int)(fl - c->fields);
            } else if ((ocv_get_raw(rec, fl) ^ ocv_get_raw(exp, fl)) & cm->bits)
                f = (int)(fl - c->fields);
        }
    } else
        f = ocv_rec_mismatch(c, rec, exp);
    if (f >= 0) k.errors[ch]++;
    return f;
}

/* the bits the checker compares, as record words (for the endpoint's run-time mask) */
const uint32_t *ocv_check_mask(int ch)
{
    resolve();
    if (k.inexact[ch]) return NULL;          /* a tolerance cannot be signed: record by record */
    const ocv_channel_t *c = &OCV_UVM_DUT.channels[ch];
    if (!k.masked[ch] && ocv_channel_word_masks(c, k.mask[ch])) k.masked[ch] = 1;
    return k.masked[ch] ? k.mask[ch] : NULL;
}

/* an endpoint without a run-time mask signs the bits of the descriptor's exact/mask fields: a
 * squash window means the same comparison only if the checker compares exactly those bits */
int ocv_check_squash_ok(int ch)
{
    resolve();
    const ocv_channel_t *c = &OCV_UVM_DUT.channels[ch];
    uint32_t hw[OCV_UVM_REC_WORDS] = { 0 };
    if (!c->squash || !ocv_channel_word_masks(c, hw)) return 0;
    if (!k.cmp_by_ch[ch]) return 1;          /* the descriptor's rules: the same bits */
    if (k.inexact[ch]) return 0;
    return !memcmp(hw, k.mask[ch], c->rec_words * 4u);
}

/* board: records as they come out of the FPGA; mismatches are kept for UVM */
#define SIG_FIELD 1000     /* a mismatch of the window signatures, not of a field */

/* run the whole program again with +OCV_SQUASH=1 (every record compared): the run is deterministic,
 * so it stops at the very record. No return if it can be started. */
void ocv_check_replay(void)
{
    static char buf[65536];
    FILE *f = fopen("/proc/self/cmdline", "rb");
    if (!f) return;
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    fclose(f);
    char *av[512];
    int ac = 0;
    for (size_t i = 0; i < n && ac < 509; i += strlen(buf + i) + 1)
        if (strncmp(buf + i, "+OCV_SQUASH=", 12)) av[ac++] = buf + i;
    av[ac++] = "+OCV_SQUASH=1";
    av[ac] = NULL;
    printf("OCV-UVM: REPLAY - running again with +OCV_SQUASH=1 to find the record\n");
    fflush(stdout);
    execv("/proc/self/exe", av);
    perror("ocv_uvm: replay");
}

void ocv_check_set_window(uint32_t n) { k.window = n ? n : 1; }
static void (*deliver_fn)(int ch, const uint32_t *recs, uint32_t n);
void ocv_check_set_deliver(void (*fn)(int, const uint32_t *, uint32_t)) { deliver_fn = fn; }

/* the testbench has subscribers of this channel besides the checked scoreboard (coverage): give
 * them the records - with squash the model's, once their window's signatures matched (equal to the
 * DUT's in every compared bit; uvm2board.py lets only compared fields be read) */
int ocv_dpi_check_deliver(int ch)
{
    if (ch < 0 || ch >= MAX_CH) return 0;
    k.deliver[ch] = 1;
    return 1;
}

void ocv_check_set_squashed(int ch, int on) { if (ch >= 0 && ch < MAX_CH) k.sq_on[ch] = on; }

void ocv_uvm_wave_hint(int ch, uint64_t record) __attribute__((weak));   /* board (ocv_uvm_dpi.c) */

static void add_miss(int ch, const uint32_t *dut, const uint32_t *exp, int field, uint64_t index)
{
    if (ocv_uvm_wave_hint) ocv_uvm_wave_hint(ch, index);
    if (k.n_miss[ch] - k.head_miss[ch] >= 1000) return;          /* enough to show; still counted */
    if (k.n_miss[ch] == k.cap_miss[ch]) {
        uint32_t cap = k.cap_miss[ch] ? 2 * k.cap_miss[ch] : 16;
        miss_t *m = realloc(k.miss[ch], cap * sizeof *m);
        if (!m) { fprintf(stderr, "ocv_uvm: out of memory\n"); exit(2); }
        k.miss[ch] = m;
        k.cap_miss[ch] = cap;
    }
    miss_t *m = &k.miss[ch][k.n_miss[ch]++];
    memset(m, 0, sizeof *m);
    memcpy(m->dut, dut, OCV_UVM_DUT.channels[ch].rec_words * 4u);
    memcpy(m->exp, exp, OCV_UVM_DUT.channels[ch].rec_words * 4u);
    m->field = field;
    m->index = index;
}

/* a fused record: run the reference `count` times, compare the window's signatures
 * (GCC: the zeroing loop stays a loop - as a memset call it costs a library call per record) */
#if defined(__GNUC__) && !defined(__clang__)
__attribute__((optimize("no-tree-loop-distribute-patterns")))
#endif
static void check_window(int ch, const uint32_t *fused)
{
    const ocv_channel_t *c = &OCV_UVM_DUT.channels[ch];
    const uint32_t w = c->rec_words, count = fused[w];
    if (!k.masked[ch]) { ocv_channel_word_masks(c, k.mask[ch]); k.masked[ch] = 1; }
    uint32_t cc = 0xFFFFFFFFu, cz = 0xFFFFFFFFu, exp[OCV_UVM_REC_WORDS];
    const int dl = k.deliver[ch] && deliver_fn;
    if (dl && (size_t)count * w > k.dcap) {
        k.dcap = (size_t)count * w;
        if (!(k.dbuf = realloc(k.dbuf, k.dcap * 4u))) { fprintf(stderr, "ocv_uvm: out of memory\n"); exit(2); }
    }
    for (uint32_t i = 0; i < count; i++) {
        for (uint32_t j = 0; j < w; j++) exp[j] = 0;   /* the record's words (inline: w is small) */
        /* the window's last record is the DUT's own (fused[0..w-1]): with break patterns it is the
         * record the model takes a value from */
        if (k.by_ch[ch]((k.n_brk[ch] && i + 1 == count) ? fused : NULL, exp) == 1) k.done[ch] = 1;
        ocv_squash_add(&cc, &cz, exp, k.mask[ch], w);
        if (dl) memcpy(k.dbuf + (size_t)i * w, exp, w * 4u);
    }
    k.checked[ch] += count;
    if (cc == fused[w + 1] && cz == fused[w + 2]) {
        if (dl) deliver_fn(ch, k.dbuf, count);
        return;
    }
    k.errors[ch]++;
    printf("OCV-UVM: channel '%s': window of records %llu..%llu differs (signatures dut %08x %08x, model %08x %08x)\n",
           c->name, (unsigned long long)(k.checked[ch] - count), (unsigned long long)(k.checked[ch] - 1),
           fused[w + 1], fused[w + 2], cc, cz);
    if (k.window > 1) ocv_check_replay();
    add_miss(ch, fused, exp, SIG_FIELD, k.checked[ch]);      /* the window's last record */
}

void ocv_check_record(int ch, const uint32_t *rec)
{
    if (OCV_UVM_DUT.channels[ch].squash && k.window > 1 && k.sq_on[ch]) { check_window(ch, rec); return; }
    uint32_t exp[OCV_UVM_REC_WORDS];
    int last, f = check(ch, rec, exp, &last);
    if (k.deliver[ch] && deliver_fn) deliver_fn(ch, rec, 1);          /* the DUT's record, as in simulation */
    if (f < 0) return;
    add_miss(ch, rec, exp, f, k.checked[ch]);
}

/* ---- DPI (ocv_checker in ocv_uvm_pkg.sv) ---- */

/* an ocv_checker of channel ch exists: 1 if a C function is registered for it */
int ocv_dpi_check_enable(int ch)
{
    resolve();
    if (ch < 0 || ch >= MAX_CH || !k.by_ch[ch]) return 0;
    k.enabled[ch] = 1;
    return 1;
}

/* simulation: check one transaction; returns the mismatching field or -1, *last = end of test */
int ocv_dpi_check(int ch, const uint32_t *rec, uint32_t *exp, int *last)
{
    resolve();
    if (ch < 0 || ch >= MAX_CH || !k.by_ch[ch]) { fprintf(stderr, "ocv_uvm: no C checker registered for channel %d\n", ch); exit(2); }
    uint32_t r[OCV_UVM_REC_WORDS];
    memcpy(r, rec, sizeof r);
    return check(ch, r, exp, last);
}

/* board: progress of a channel's checker */
void ocv_dpi_check_status(int ch, long long *checked, long long *errors, int *done)
{
    *checked = (long long)k.checked[ch];
    *errors = (long long)k.errors[ch];
    *done = k.done[ch];
}

/* board: the next mismatch not yet reported: 1 and the records, or 0 */
int ocv_dpi_check_mismatch(int ch, uint32_t *dut, uint32_t *exp, int *field, long long *index)
{
    if (k.head_miss[ch] == k.n_miss[ch]) return 0;
    miss_t *m = &k.miss[ch][k.head_miss[ch]++];
    memcpy(dut, m->dut, sizeof m->dut);
    memcpy(exp, m->exp, sizeof m->exp);
    *field = m->field;
    *index = (long long)m->index;
    return 1;
}

const char *ocv_dpi_field_name(int ch, int field)
{
    const ocv_channel_t *c = &OCV_UVM_DUT.channels[ch];
    if (field == SIG_FIELD) return "(window signature)";
    return field >= 0 && field < c->n_fields ? c->fields[field].name : "?";
}
