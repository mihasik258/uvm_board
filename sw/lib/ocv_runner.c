/* ocv_runner.c - generic verification run for any DUT described by OCV metadata.
 *
 * Per batch:
 *   1. stimulus: the model's generator (or random fields) fills the source channels, until it
 *      runs out or the batch is full;
 *   2. run: load and start the sources, wait until every source is done and the outputs have
 *      stopped growing;
 *   3. model: feed the stimulus to the reference model, which may look at the DUT's actual
 *      records (observed()) for values the specification leaves open;
 *   4. check: no lost records, same number of records, then record by record, field by field
 *      under the descriptor's rules; the first difference is reported with context.
 * Reactive DUTs (the model has react(), or a source is a "stream"): during step 2 every new record
 * of an output channel is read as soon as it appears and handed to react(), whose send() answers go
 * straight into stream sources (a ring the DUT reads; with freeze_when_starved the DUT is held
 * until the answer is there). Stream sources get no stimulus from step 1.
 * Batches follow each other without resetting the DUT (unless --reset-each-batch), so the run
 * length is not bounded by the buffer depth. The run ends after --batches batches or at the
 * first batch for which the model has no stimulus.
 *
 * Squash (--squash N, channels with "squash" in the descriptor): the endpoint fuses every N records
 * into one {last record, count, CRC32C, CRC32}; the runner folds the model's records the same way
 * and compares the fused records - the DUT's output costs the PS one record read per N. A window
 * that differs is located exactly by running everything again with --squash 1 (the run is
 * deterministic), automatically when the main gave its command line (ocv_runner_set_exec).
 *
 * Exit status: 0 all records match, 2 mismatch / missing / extra / lost records, 1 setup error.
 */
#include "ocv.h"
#include "ocv_model.h"
#include "ocv_runner.h"

#include <pthread.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* A growable array of records. */
typedef struct {
    uint32_t *w;
    size_t    cap;      /* records allocated */
    uint32_t  n;        /* records held */
} recbuf_t;

static void recbuf_reserve(recbuf_t *b, uint32_t more, unsigned words)
{
    if (b->n + (size_t)more <= b->cap) return;
    while (b->n + (size_t)more > b->cap) b->cap = b->cap ? b->cap * 2 : 1024;
    b->w = realloc(b->w, b->cap * words * sizeof *b->w);
    if (!b->w) { fprintf(stderr, "ocv: out of memory\n"); exit(1); }
}

static void recbuf_push(recbuf_t *b, const uint32_t *rec, unsigned words)
{
    recbuf_reserve(b, 1, words);
    memcpy(b->w + (size_t)b->n * words, rec, words * sizeof *rec);
    b->n++;
}

typedef struct {
    recbuf_t  exp;      /* expected by the model in this batch */
    recbuf_t  got;      /* captured from the DUT in this batch (drained buffers included) */
    uint64_t  stream;   /* records of this channel in earlier batches */
    uint64_t  compared;
    uint64_t  drains;   /* times a full lossless buffer was emptied while the DUT waited */
    /* --overlap: got as the model thread sees it, published without a lock. The buffer is never
     * moved while the thread runs: when it grows, a new one is published and the old one is kept
     * until the end of the batch. Readers load pub_n (acquire), then pub_w. */
    uint32_t *pub_w;
    uint32_t  pub_n;
    void    **retired;
    unsigned  n_retired;
    uint32_t  qw;       /* words per queued record: rec_words, + 3 for a squashed channel */
    /* squash: the model's records folded into the open window */
    ocv_squash_t sq;                     /* the open window (squash): also the model's (io->squash) */
} queue_t;

typedef struct { uint16_t ch; uint32_t i; } stim_ref_t;

typedef struct {
    ocv_env_t   env;
    queue_t    *q;        /* per output channel (unused for sources) */
    uint32_t  **stim;     /* stimulus of the current batch, per source channel */
    uint32_t   *n_stim;   /* records of the current batch, per source channel */
    stim_ref_t *order;    /* order in which the stimulus records were generated */
    uint32_t    n_order;
    uint32_t  **mask;     /* per output channel: bits compared (word-mask path) */
    int        *by_mask;  /* per output channel: records compare as masked words */
    ocv_model_io_t *io;
    int         in_reset;
    /* --overlap: the model runs in a thread of its own while the DUT runs and is drained, and
     * checks every record as soon as the DUT's one has arrived */
    int             overlap;
    pthread_mutex_t mu;         /* guards q[].got (appended by the main thread) and the flags */
    pthread_cond_t  cv;         /* new DUT records, end of the batch, or stop */
    int             dut_done;   /* no more DUT records in this batch */
    int             stop;       /* a mismatch was found; read by the main thread without the lock,
                                 * so always accessed atomically */
    int             mm_ch, mm_field;
    uint32_t        mm_i;       /* first mismatch: channel (-1 = none), record, field */
    double          model_busy, model_wait;   /* model thread: total and waiting for the DUT, s */
    /* reactive mode */
    int             reactive;
    int             react_skip_squash;  /* squashed channels are collected, not handed to react() */
    uint32_t       *seen;       /* per output channel: records already read from its buffer */
    uint32_t       *stream_n;   /* per stream source: records written this batch (= LENGTH to set) */
    uint8_t        *dirty;      /* per stream source: LENGTH not yet published */
    uint64_t       *answers;    /* per stream source: records sent over the run */
    uint64_t        max_polls;
    uint32_t        window;     /* --squash: records per fused record */
    int             obs_squash; /* the model asked for DUT records it cannot see in squash mode */
    /* interleaved (not --overlap, not --no-interleave): the model runs in this thread while the DUT runs,
     * making poll passes itself (io->idle, and while it waits for a DUT record in observed()) */
    int             interleave, il_active, il_quiet;
    uint32_t        settle, il_settled;
    uint64_t        il_polls;
    uint32_t       *il_prev;    /* per channel: count at the last pass (what "moved" compares) */
    uint64_t       *taken_hi;   /* per channel: TAKEN's wraps (a 64-bit count of a squashed channel) */
    uint32_t       *taken_lo;
} run_t;

static int    exec_argc;          /* the main's command line, to run again for a squash replay */
static char **exec_argv;
void ocv_runner_set_exec(int argc, char **argv)      /* a copy: mains compact argv in place */
{
    exec_argv = calloc((size_t)argc + 1, sizeof *exec_argv);
    if (!exec_argv) return;
    for (int i = 0; i < argc; i++) exec_argv[i] = argv[i];
    exec_argc = argc;
}

/* first field that differs, or -1; whole words under a mask when the channel allows it */
#define SQUASH_SIG 1000    /* rec_diff: the window signatures (count, CRCs) differ - not a field index */
static int rec_diff(const run_t *r, int ch, const uint32_t *g, const uint32_t *e)
{
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    const uint32_t k = c->rec_words;
    /* a fused window: the signatures first (the last record alone says little); a window of one:
     * the record itself first, for the usual field-by-field report */
    if (c->squash && r->window > 1 && (g[k] != e[k] || g[k + 1] != e[k + 1] || g[k + 2] != e[k + 2]))
        return SQUASH_SIG;
    int f = -1;
    if (r->by_mask[ch]) {
        uint32_t diff = 0;
        for (unsigned w = 0; w < k; w++) diff |= (g[w] ^ e[w]) & r->mask[ch][w];
        if (diff) f = ocv_rec_mismatch(c, g, e);
    } else {
        f = ocv_rec_mismatch(c, g, e);
    }
    if (f < 0 && c->squash && (g[k] != e[k] || g[k + 1] != e[k + 1] || g[k + 2] != e[k + 2])) return SQUASH_SIG;
    return f;
}

static double now_s(void);

/* model thread: DUT record `index` of channel `ch` into rec, waiting until it has been drained;
 * 0 if the DUT did not produce it (end of the batch) */
static int wait_got(run_t *r, int ch, uint32_t index, uint32_t *rec)
{
    queue_t *q = &r->q[ch];
    uint32_t n = __atomic_load_n(&q->pub_n, __ATOMIC_ACQUIRE);
    if (n <= index) {                    /* ahead of the DUT: wait (the only locked path) */
        double t = now_s();
        pthread_mutex_lock(&r->mu);
        while ((n = __atomic_load_n(&q->pub_n, __ATOMIC_ACQUIRE)) <= index && !r->dut_done
               && !__atomic_load_n(&r->stop, __ATOMIC_RELAXED))
            pthread_cond_wait(&r->cv, &r->mu);
        pthread_mutex_unlock(&r->mu);
        r->model_wait += now_s() - t;
        if (n <= index) return 0;
    }
    const uint32_t *w = __atomic_load_n(&q->pub_w, __ATOMIC_ACQUIRE);
    memcpy(rec, w + (size_t)index * q->qw, q->qw * 4u);
    return 1;
}

static void emit(ocv_model_io_t *io, int ch, const uint32_t *rec)
{
    run_t *r = io->priv;
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (c->kind == OCV_CH_SOURCE) {
        fprintf(stderr, "ocv: model emitted on source channel '%s'\n", c->name);
        exit(1);
    }
    queue_t *q = &r->q[ch];
    uint32_t fused[259];
    if (c->squash) {                             /* fold into the window, as the endpoint does */
        if (q->sq.n == 0) q->sq.c = q->sq.z = 0xFFFFFFFFu;
        ocv_squash_add(&q->sq.c, &q->sq.z, rec, r->mask[ch], c->rec_words);
        for (uint32_t j = 0; j < c->rec_words; j++) q->sq.last[j] = rec[j];   /* (a few words: no libc call) */
        if (++q->sq.n < r->window) return;
        memcpy(fused, q->sq.last, c->rec_words * 4u);
        fused[c->rec_words] = q->sq.n;
        fused[c->rec_words + 1] = q->sq.c;
        fused[c->rec_words + 2] = q->sq.z;
        q->sq.n = 0;
        rec = fused;
    }
    recbuf_push(&q->exp, rec, q->qw);
    if (!r->overlap || __atomic_load_n(&r->stop, __ATOMIC_RELAXED)) return;
    uint32_t i = q->exp.n - 1, g[259];
    if (!wait_got(r, ch, i, g)) return;          /* the DUT made fewer: the count check reports it */
    int f = rec_diff(r, ch, g, rec);
    if (f < 0) { q->compared += c->squash ? g[c->rec_words] : 1; return; }
    pthread_mutex_lock(&r->mu);
    if (r->mm_ch < 0) { r->mm_ch = ch; r->mm_i = i; r->mm_field = f; }
    __atomic_store_n(&r->stop, 1, __ATOMIC_RELAXED);
    pthread_cond_broadcast(&r->cv);
    pthread_mutex_unlock(&r->mu);
}

/* emit() of n records; a squashed channel (not --overlap) folds them with its window state in locals */
static void emit_n(ocv_model_io_t *io, int ch, const uint32_t *recs, uint32_t n, uint32_t stride)
{
    run_t *r = io->priv;
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (!c->squash || r->overlap || c->kind == OCV_CH_SOURCE) {
        for (uint32_t i = 0; i < n; i++) emit(io, ch, recs + (size_t)i * stride);
        return;
    }
    queue_t *q = &r->q[ch];
    const uint32_t W = c->rec_words, win = r->window, *mask = r->mask[ch];
    uint32_t a = q->sq.c, z = q->sq.z, k = q->sq.n;
    for (uint32_t i = 0; i < n; i++) {
        const uint32_t *rec = recs + (size_t)i * stride;
        if (k == 0) a = z = 0xFFFFFFFFu;
        ocv_squash_add(&a, &z, rec, mask, W);
        if (++k < win) continue;
        uint32_t fused[259];
        for (uint32_t j = 0; j < W; j++) fused[j] = rec[j];
        fused[W] = k; fused[W + 1] = a; fused[W + 2] = z;
        recbuf_push(&q->exp, fused, q->qw);
        k = 0;
    }
    if (k && n) for (uint32_t j = 0; j < W; j++) q->sq.last[j] = recs[(size_t)(n - 1) * stride + j];
    q->sq.c = a; q->sq.z = z; q->sq.n = k;
}

/* a piece of records (ocv_fold_t): squashed channels (not --overlap), inside one window - folded with
 * ocv_fold_apply, the window state as emit_n leaves it */
static int fold_make(ocv_model_io_t *io, int ch, const uint32_t *recs, uint32_t n, uint32_t stride, ocv_fold_t *f)
{
    run_t *r = io->priv;
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (!c->squash || r->overlap || c->kind == OCV_CH_SOURCE) return 0;
    return ocv_fold_make(f, recs, n, stride, r->mask[ch], c->rec_words);
}
static int emit_fold(ocv_model_io_t *io, int ch, const ocv_fold_t *f)
{
    run_t *r = io->priv;
    queue_t *q = &r->q[ch];
    if (q->sq.n + f->n >= r->window) return 0;  /* (the window would end inside: record by record) */
    if (q->sq.n == 0) q->sq.c = q->sq.z = 0xFFFFFFFFu;
    ocv_fold_apply(&q->sq.c, &q->sq.z, f);
    q->sq.n += f->n;
    for (uint32_t j = 0; j < f->words; j++) q->sq.last[j] = f->last[j];
    return 1;
}

/* the window state for a model that folds its records itself: as emit_n, squashed channels without --overlap */
static ocv_squash_t *squash(ocv_model_io_t *io, int ch)
{
    run_t *r = io->priv;
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (!c->squash || r->overlap || c->kind == OCV_CH_SOURCE || c->rec_words > 256) return NULL;
    return &r->q[ch].sq;
}
static void squash_close(ocv_model_io_t *io, int ch)
{   /* the window is full: its fused record, as emit_n makes it */
    run_t *r = io->priv;
    queue_t *q = &r->q[ch];
    const uint32_t W = r->env.dut->channels[ch].rec_words;
    uint32_t fused[259];
    for (uint32_t j = 0; j < W; j++) fused[j] = q->sq.last[j];
    fused[W] = q->sq.n; fused[W + 1] = q->sq.c; fused[W + 2] = q->sq.z;
    recbuf_push(&q->exp, fused, q->qw);
    q->sq.n = 0;
}

/* interleaved: one pass over the channels as the wait loop makes it (records in, answers out, full buffers
 * restarted) - the DUT goes on while the model runs; quiet once nothing moved for --settle passes with all
 * stimulus taken (or after --max-polls passes: then the wait loop after the model reports it) */
static uint32_t react_new(run_t *r, int ch);
static void collect(run_t *r, int ch, int restart);
static void il_poll(run_t *r)
{
    const ocv_dut_t *dut = r->env.dut;
    int quiet = 1;
    for (int ch = 0; ch < dut->n_channels; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        uint32_t n;
        if (c->kind == OCV_CH_SOURCE) {
            if (ocv_ep_rd(&r->env, ch, OCV_EP_REG_STATUS) & OCV_SRC_ST_DONE) continue;
            quiet = 0;
            continue;
        } else if (r->reactive && !(r->react_skip_squash && c->squash)) {
            if (react_new(r, ch)) quiet = 0;
            continue;
        }
        n = ocv_ep_rd(&r->env, ch, OCV_EP_REG_COUNT);
        if (ocv_ring_on(&r->env, ch)) {
            if (n != r->env.ep[ch].tail) collect(r, ch, 0);
        } else if (c->lossless && n == c->depth) {
            collect(r, ch, 1);
            r->q[ch].drains++;
            n = ~0u;
        }
        if (c->squash && n != ~0u) n = ocv_ep_rd(&r->env, ch, OCV_EP_REG_TAKEN);
        if (n != r->il_prev[ch]) quiet = 0;
        r->il_prev[ch] = n;
    }
    r->il_settled = quiet ? r->il_settled + 1 : 0;
    if (r->il_settled >= r->settle || ++r->il_polls >= r->max_polls) r->il_quiet = 1;
}
static void idle(ocv_model_io_t *io)
{
    run_t *r = io->priv;
    if (r->il_active && !r->il_quiet) il_poll(r);
}
/* how many records the DUT has made on output channel ch so far (squashed: taken by its endpoint);
 * UINT64_MAX once it is quiet (or the model runs after it): all it will make are there */
static uint64_t progress(ocv_model_io_t *io, int ch)
{
    run_t *r = io->priv;
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (!r->il_active || r->il_quiet) return UINT64_MAX;
    if (!c->squash) return r->q[ch].got.n;
    const uint32_t t = ocv_ep_rd(&r->env, ch, OCV_EP_REG_TAKEN);
    if (t < r->taken_lo[ch]) r->taken_hi[ch] += 1ull << 32;
    r->taken_lo[ch] = t;
    return r->taken_hi[ch] + t;
}

static int observed_at(run_t *r, int ch, uint32_t index, uint32_t *rec, int wait);
static int observed(ocv_model_io_t *io, int ch, uint32_t index, uint32_t *rec) { return observed_at(io->priv, ch, index, rec, 1); }
/* observed() without waiting for the DUT: 0 if the record is not there yet */
static int peek(ocv_model_io_t *io, int ch, uint32_t index, uint32_t *rec) { return observed_at(io->priv, ch, index, rec, 0); }
static int observed_at(run_t *r, int ch, uint32_t index, uint32_t *rec, int wait)
{
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (c->kind == OCV_CH_SOURCE) return 0;
    if (c->squash && r->window > 1) { r->obs_squash = 1; return 0; }   /* single records are not seen */
    uint32_t g[259];
    if (r->overlap) {
        if (!wait_got(r, ch, index, g)) return 0;
        memcpy(rec, g, c->rec_words * 4u);
        return 1;
    }
    if (wait) while (index >= r->q[ch].got.n && r->il_active && !r->il_quiet) il_poll(r);   /* (interleaved) */
    if (index >= r->q[ch].got.n) return 0;
    memcpy(rec, r->q[ch].got.w + (size_t)index * r->q[ch].qw, c->rec_words * 4u);
    return 1;
}

static void *model_thread(void *arg)
{
    run_t *r = arg;
    double t = now_s();
    if (r->in_reset) ocv_model.reset();
    for (uint32_t k = 0; k < r->n_order; k++) {
        const ocv_channel_t *c = &r->env.dut->channels[r->order[k].ch];
        ocv_model.input(r->order[k].ch, r->stim[r->order[k].ch] + (size_t)r->order[k].i * c->rec_words, r->io);
    }
    r->model_busy += now_s() - t;
    return NULL;
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* --profile: wall time and bus accesses per phase of the run. Phases switch only at phase
 * boundaries (a few times per batch and per drain), so the bookkeeping does not distort the run;
 * individual accesses are counted, not timed, and their price is measured separately at the end. */
enum { PH_STIM, PH_LOAD, PH_WAIT, PH_DRAIN, PH_REACT, PH_MODEL, PH_CHECK, PH_OTHER, PH_N };
static const char *const ph_name[PH_N] = {
    "stimulus (model generator)", "load stimulus (bus writes)", "wait for DUT (status polls)",
    "drain outputs (bus reads)", "react + send (model answers)", "reference model", "compare", "other" };
static double   ph_t[PH_N];
static uint64_t ph_rd[PH_N + 1], ph_wr[PH_N + 1];   /* [PH_N]: the price measurement itself */
static int      ph_cur = PH_OTHER;
static double   ph_t0;

static int phase(int p)                   /* switch phase, return the previous one */
{
    double t = now_s();
    ph_t[ph_cur] += t - ph_t0;
    ph_t0 = t;
    int prev = ph_cur;
    ph_cur = p;
    return prev;
}

static ocv_bus_t *real_bus;               /* the counting bus forwards to it */
static uint32_t cnt_rd(ocv_bus_t *b, uint32_t off) { (void)b; ph_rd[ph_cur]++; return real_bus->rd(real_bus, off); }
static void cnt_wr(ocv_bus_t *b, uint32_t off, uint32_t v) { (void)b; ph_wr[ph_cur]++; real_bus->wr(real_bus, off, v); }
static void cnt_rd_block(ocv_bus_t *b, uint32_t off, uint32_t *dst, uint32_t n)
{
    (void)b;
    ph_rd[ph_cur] += n;                   /* counted in words */
    real_bus->rd_block(real_bus, off, dst, n);
}

static void profile_report(ocv_env_t *env, double total)
{
    /* price of one access: a hub register read, and a write of a harmless register (THROTTLE of
     * the first endpoint, restored) */
    const int n = 20000;
    ph_cur = PH_N;                        /* its own accesses stay out of the table */
    uint32_t thr = ocv_ep_rd(env, 0, OCV_EP_REG_THROTTLE);
    double t = now_s();
    volatile uint32_t chain = 0;          /* each read waits for the previous one, as the runner's do */
    for (int i = 0; i < n; i++) chain += real_bus->rd(real_bus, OCV_HUB_REG_ID + (chain & 0));
    double rd_ns = (now_s() - t) / n * 1e9;
    t = now_s();
    for (int i = 0; i < n; i++) real_bus->wr(real_bus, env->ep[0].base + OCV_EP_REG_THROTTLE, thr);
    (void)real_bus->rd(real_bus, OCV_HUB_REG_ID);                   /* wait for posted writes */
    double wr_ns = (now_s() - t) / n * 1e9;
    /* and a read of an output buffer word (sequential words, as a drain reads them) */
    double buf_ns = 0;
    for (int ch = 0; ch < env->dut->n_channels; ch++) {
        if (env->dut->channels[ch].kind == OCV_CH_SOURCE) continue;
        const ocv_channel_t *c = &env->dut->channels[ch];
        uint32_t *blk = malloc((size_t)c->depth * ocv_store_words(c) * 4u);
        if (!blk) break;
        int got = 0;
        t = now_s();
        while (got < n) { ocv_rec_read_block(env, ch, 0, c->depth, blk); got += (int)(c->depth * ocv_store_words(c)); }
        buf_ns = (now_s() - t) / got * 1e9;
        free(blk);
        break;
    }

    uint64_t rd = 0, wr = 0;
    for (int p = 0; p < PH_N; p++) { rd += ph_rd[p]; wr += ph_wr[p]; }
    printf("PROFILE: one bus read %.0f ns (register), %.0f ns per word of an output buffer (drain path); one bus write %.0f ns\n",
           rd_ns, buf_ns, wr_ns);
    printf("PROFILE: %-28s %9s %6s %10s %10s %9s\n", "phase", "time, s", "share", "words rd", "writes", "bus, s");
    for (int p = 0; p < PH_N; p++) {
        double bus = ((p == PH_DRAIN ? buf_ns : rd_ns) * ph_rd[p] + ph_wr[p] * wr_ns) * 1e-9;
        printf("PROFILE: %-28s %9.4f %5.1f%% %10llu %10llu %9.4f\n", ph_name[p], ph_t[p],
               total > 0 ? 100.0 * ph_t[p] / total : 0.0, (unsigned long long)ph_rd[p],
               (unsigned long long)ph_wr[p], bus);
    }
    double bus = ((rd - ph_rd[PH_DRAIN]) * rd_ns + ph_rd[PH_DRAIN] * buf_ns + wr * wr_ns) * 1e-9;
    printf("PROFILE: %-28s %9.4f %5.1f%% %10llu %10llu %9.4f\n", "total", total, 100.0,
           (unsigned long long)rd, (unsigned long long)wr, bus);
    printf("PROFILE: bus accesses take %.0f%% of the run (estimate from the measured prices)\n",
           total > 0 ? 100.0 * bus / total : 0.0);
}

/* Move the records now in an output channel's buffer to the host copy; `restart` also empties
 * the buffer (which lets a frozen DUT continue). */
static void collect(run_t *r, int ch, int restart)
{
    int prev = phase(PH_DRAIN);
    recbuf_t *got = &r->q[ch].got;
    /* a DMA ring: what reached PS memory since the last time (at most a ring's worth); otherwise the
     * whole buffer, read over the bus */
    const int ring = ocv_ring_on(&r->env, ch);
    uint32_t n = ring ? 1u << r->env.ep[ch].ring_log2 : ocv_ep_rd(&r->env, ch, OCV_EP_REG_COUNT);
    if (r->overlap) {                      /* read without the lock, then append and wake the model */
        static uint32_t *tmp;
        static size_t cap;
        if ((size_t)n * r->q[ch].qw > cap) {
            cap = (size_t)n * r->q[ch].qw;
            tmp = realloc(tmp, cap * 4u);
            if (!tmp) { fprintf(stderr, "ocv: out of memory\n"); exit(1); }
        }
        if (ring) n = ocv_ring_take(&r->env, ch, tmp, n);
        else      ocv_rec_read_block(&r->env, ch, 0, n, tmp);
        queue_t *q = &r->q[ch];
        if (got->n + (size_t)n > got->cap) {        /* grow without moving what the model reads */
            size_t cap = got->cap ? got->cap : 1024;
            while (got->n + (size_t)n > cap) cap *= 2;
            uint32_t *w = malloc(cap * r->q[ch].qw * 4u);
            void **ret = realloc(q->retired, (q->n_retired + 1) * sizeof *ret);
            if (!w || !ret) { fprintf(stderr, "ocv: out of memory\n"); exit(1); }
            if (got->n) memcpy(w, got->w, (size_t)got->n * r->q[ch].qw * 4u);
            q->retired = ret;
            q->retired[q->n_retired++] = got->w;
            got->w = w;
            got->cap = cap;
            __atomic_store_n(&q->pub_w, w, __ATOMIC_RELEASE);
        }
        memcpy(got->w + (size_t)got->n * r->q[ch].qw, tmp, (size_t)n * r->q[ch].qw * 4u);
        got->n += n;
        __atomic_store_n(&q->pub_n, got->n, __ATOMIC_RELEASE);
        pthread_mutex_lock(&r->mu);                /* wake a model thread that waits */
        pthread_cond_broadcast(&r->cv);
        pthread_mutex_unlock(&r->mu);
    } else {
        recbuf_reserve(got, n, r->q[ch].qw);
        if (ring) n = ocv_ring_take(&r->env, ch, got->w + (size_t)got->n * r->q[ch].qw, n);
        else      ocv_rec_read_block(&r->env, ch, 0, n, got->w + (size_t)got->n * r->q[ch].qw);
        got->n += n;
    }
    if (restart && !ring) ocv_ep_wr(&r->env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
    phase(prev);
}

/* everything the DUT gave a ring channel so far: wait until the FPGA has written it all (COUNT
 * records captured, the FIFO emptied), collecting meanwhile. 0, or -1 if the DMA reports a write
 * error or does not get there. */
static int ring_finish(run_t *r, int ch, uint64_t max_polls)
{
    for (uint64_t polls = 0; ocv_ring_pending(&r->env, ch); polls++) {
        if (polls >= max_polls) {
            printf("FAIL channel '%s': DMA stuck - %u records captured but not in PS memory\n",
                   r->env.dut->channels[ch].name, ocv_ring_pending(&r->env, ch));
            return -1;
        }
        collect(r, ch, 0);
    }
    if (ocv_ep_rd(&r->env, ch, OCV_EP_REG_DMA_STAT) & OCV_DMA_ST_ERROR) {
        printf("FAIL channel '%s': DMA write error (the ring's address is not writable memory?)\n",
               r->env.dut->channels[ch].name);
        return -1;
    }
    return 0;
}

/* ---- reactive mode ---- */

/* publish the records react() sent: raise LENGTH of every stream source that got some */
static void flush_streams(run_t *r)
{
    for (int ch = 0; ch < r->env.dut->n_channels; ch++)
        if (r->dirty[ch]) { ocv_ep_wr(&r->env, ch, OCV_EP_REG_LENGTH, r->stream_n[ch]); r->dirty[ch] = 0; }
}

/* io->send: record k of a stream source goes to slot k mod depth, once the DUT has taken the one
 * that was there (k < COUNT + depth) */
static void send_rec(ocv_model_io_t *io, int ch, const uint32_t *rec)
{
    run_t *r = io->priv;
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    if (c->kind != OCV_CH_SOURCE || !c->stream) {
        fprintf(stderr, "ocv: model sent on channel '%s', which is not a stream source\n", c->name);
        exit(1);
    }
    uint32_t k = r->stream_n[ch];
    for (uint64_t polls = 0; k >= ocv_ep_rd(&r->env, ch, OCV_EP_REG_COUNT) + c->depth; polls++) {
        flush_streams(r);                        /* the DUT can only drain what is published */
        if (polls >= r->max_polls) {
            printf("FAIL channel '%s': the DUT does not take the answers it asked for - %u sent, %u taken"
                   " (it asked for more than it consumes, or consumed data that was not there)\n",
                   c->name, k, ocv_ep_rd(&r->env, ch, OCV_EP_REG_COUNT));
            fflush(stdout);
            exit(2);
        }
    }
    ocv_rec_write(&r->env, ch, k % c->depth, rec);
    r->stream_n[ch] = k + 1;
    r->dirty[ch] = 1;
    r->answers[ch]++;
}

/* Read the records the DUT added to output channel ch since the last call, hand each to react(),
 * publish the answers. A full buffer that holds the DUT is then restarted (it resumes).
 * Returns the number of new records. */
static uint32_t react_new(run_t *r, int ch)
{
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    queue_t *q = &r->q[ch];
    if (ocv_ring_on(&r->env, ch)) {               /* a DMA ring: the new records, from PS memory */
        uint32_t first = q->got.n, k;
        int prev = phase(PH_DRAIN);
        collect(r, ch, 0);
        k = q->got.n - first;
        if (k && ocv_model.react) {
            phase(PH_REACT);
            for (uint32_t i = 0; i < k; i++)
                ocv_model.react(ch, q->got.w + (size_t)(first + i) * q->qw, r->io);
            flush_streams(r);
        }
        phase(prev);
        return k;
    }
    uint32_t n = ocv_ep_rd(&r->env, ch, OCV_EP_REG_COUNT), k = 0;
    if (n > r->seen[ch]) {
        int prev = phase(PH_DRAIN);
        k = n - r->seen[ch];
        recbuf_reserve(&q->got, k, q->qw);
        uint32_t first = q->got.n;
        ocv_rec_read_block(&r->env, ch, r->seen[ch], k, q->got.w + (size_t)first * q->qw);
        q->got.n += k;
        r->seen[ch] = n;
        if (ocv_model.react) {
            phase(PH_REACT);
            for (uint32_t i = 0; i < k; i++)
                ocv_model.react(ch, q->got.w + (size_t)(first + i) * q->qw, r->io);
            flush_streams(r);
        }
        phase(prev);
    }
    /* a full buffer that holds the DUT (lossless monitor: frozen; sink with backpressure: not
     * ready) has now been read completely: restart it and the DUT goes on */
    if ((c->lossless || (r->env.ep[ch].kind & OCV_KIND_BACKPRESSURE)) && n == c->depth) {
        ocv_ep_wr(&r->env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
        r->seen[ch] = 0;
        q->drains++;
    }
    return k;
}

static void usage(const char *prog)
{
    fprintf(stderr,
            "usage: %s [options]\n"
            "  --batches N         at most N batches (default 1)\n"
            "  --batch N           stimulus records per batch and source (default: smallest source depth; a\n"
            "                      source smaller than N gets up to its depth)\n"
            "  --seed S            random seed (default 1)\n"
            "  --reset-each-batch  reset the DUT (and model) before every batch, not only the first\n"
            "  --throttle-in P     stimulus sources pause a new record with probability P/256 per cycle\n"
            "  --throttle-out P    back-pressured sinks withhold ready with probability P/256\n"
            "  --throttle-stream P stream sources (answers of a reactive model) reach the DUT late, with\n"
            "                      probability P/256 per cycle: memory/peer latency the DUT must cope with\n"
            "  --model-opt K=V     option for the reference model (repeatable)\n"
            "  --settle N          outputs must stay unchanged for N status polls (default 32)\n"
            "  --context K         records of context printed on a mismatch (default 3)\n"
            "  --max-polls N       give up waiting for the DUT after N status polls (default 10000000)\n"
            "  --stall-polls N     fail when no channel moves for N polls while stimulus is pending (default 100000)\n"
            "  --max-cycles N      fail when a batch runs more than N DUT clocks (a DUT that never ends: e.g. a\n"
            "                      core looping in its trap handler; channels keep moving, so not a stall) - 0: no limit\n"
            "  --quiet             only the final line\n"
            "  --profile           time and bus accesses per phase of the run\n"
            "  --no-block          read output buffers word by word (as before block reads; for comparison)\n"
            "  --slow-compare      compare field by field under each rule (as before the word-mask path)\n"
            "  --overlap           run the model in a second thread, concurrently with the DUT and the drains\n"
            "  --no-dma            read outputs over the bus even if the image has DMA rings\n"
            "  --ring-bytes N      at most N bytes per DMA ring (default: an even share of the DMA memory)\n"
            "                      (default: on when an output channel is lossless, i.e. streams during the run)\n"
            "  --no-overlap        model after the DUT, in the same thread\n"
            "  --no-interleave     (without --overlap) the model after the DUT, not while it runs\n"
            "  --info              check the hub, endpoints and bus against the metadata; run nothing\n"
            "  --squash N          channels built with \"squash\": compare fused windows of N records (signatures);\n"
            "                      a differing window is located by running again with --squash 1 (default 1)\n", prog);
}

/* A squashed run failed: run the same program again with --squash 1, every record compared - the
 * run is deterministic, so that run stops at the very record (no return if it can be started). */
static void squash_replay(const run_t *r)
{
    if (r->window <= 1 || !exec_argv) return;
    printf("REPLAY: running again with --squash 1 to find the record\n");
    fflush(stdout);
    char **av = calloc((size_t)exec_argc + 3, sizeof *av);
    if (!av) return;
    int n = 0;
    for (int j = 0; j < exec_argc; j++) {
        if (!strcmp(exec_argv[j], "--squash") && j + 1 < exec_argc) { j++; continue; }
        av[n++] = exec_argv[j];
    }
    av[n++] = "--squash";
    av[n++] = "1";
    execv("/proc/self/exe", av);
    perror("ocv: replay");
}

static int report_mismatch(run_t *r, int ch, uint32_t i, int field, int context, uint64_t batch)
{
    const ocv_channel_t *c = &r->env.dut->channels[ch];
    queue_t *q = &r->q[ch];
    char a[512], b[512];
    const uint32_t *dut = q->got.w + (size_t)i * q->qw;
    const uint32_t *exp = q->exp.w + (size_t)i * q->qw;
    if (field == SQUASH_SIG) {
        const uint32_t k = c->rec_words;
        printf("MISMATCH channel '%s' window of records %llu..%llu (batch %llu): signatures differ -"
               " dut %u records crc32c %08x crc32 %08x, model %u records crc32c %08x crc32 %08x\n",
               c->name, (unsigned long long)q->compared, (unsigned long long)(q->compared + exp[k] - 1),
               (unsigned long long)batch, dut[k], dut[k + 1], dut[k + 2], exp[k], exp[k + 1], exp[k + 2]);
        if (r->obs_squash)
            printf("  note: the model asked for DUT records it cannot see in squash mode (observed())\n");
        squash_replay(r);
        return 2;
    }
    printf("MISMATCH channel '%s' record %llu (batch %llu, slot %u): field '%s'\n", c->name,
           (unsigned long long)(c->squash ? q->compared : q->stream + i), (unsigned long long)batch, i,
           c->fields[field].name);
    ocv_rec_format(c, dut, a, sizeof a);
    ocv_rec_format(c, exp, b, sizeof b);
    printf("  dut  : %s\n  model: %s\n", a, b);
    if (context > 0 && i > 0) {
        printf("  preceding records (dut, all matched):\n");
        for (uint32_t k = (i > (uint32_t)context) ? i - context : 0; k < i; k++) {
            ocv_rec_format(c, q->got.w + (size_t)k * q->qw, a, sizeof a);
            printf("    [%llu] %s\n", (unsigned long long)(q->stream + k), a);
        }
    }
    return 2;
}

/* every way out of the run once the hub is open: close it (its DMA rings off - the FPGA must not write on into
 * memory this process gives back) */
#define RUN_END(v) do { int rc_ = (v); ocv_env_close(&r.env); return rc_; } while (0)

int ocv_runner_main(int argc, char **argv, ocv_bus_t *bus)
{
    const ocv_dut_t *dut = ocv_model_dut;
    uint64_t batches = 1, seed = 1, max_polls = 10000000, stall_polls = 100000, max_cycles = 0;
    uint32_t batch = 0, thr_in = 0, thr_out = 0, thr_stream = 0;
    int no_interleave = getenv("OCV_NO_INTERLEAVE") != NULL;
    int reset_each = 0, context = 3, quiet = 0, settle = 32, profile = 0, no_block = 0, slow_compare = 0, overlap = -1, no_dma = 0;
    size_t ring_bytes = 0;
    uint32_t window = 1;

    for (int i = 1; i < argc; i++) {
        const char *o = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if      (!strcmp(o, "--batches") && v)      { batches = strtoull(v, 0, 0); i++; }
        else if (!strcmp(o, "--batch") && v)        { batch = (uint32_t)strtoul(v, 0, 0); i++; }
        else if (!strcmp(o, "--seed") && v)         { seed = strtoull(v, 0, 0); i++; }
        else if (!strcmp(o, "--context") && v)      { context = atoi(v); i++; }
        else if (!strcmp(o, "--settle") && v)       { settle = atoi(v); i++; }
        else if (!strcmp(o, "--throttle-in") && v)  { thr_in = (uint32_t)strtoul(v, 0, 0) & 0xFF; i++; }
        else if (!strcmp(o, "--throttle-out") && v) { thr_out = (uint32_t)strtoul(v, 0, 0) & 0xFF; i++; }
        else if (!strcmp(o, "--throttle-stream") && v) { thr_stream = (uint32_t)strtoul(v, 0, 0) & 0xFF; i++; }
        else if (!strcmp(o, "--max-polls") && v)    { max_polls = strtoull(v, 0, 0); i++; }
        else if (!strcmp(o, "--max-cycles") && v)   { max_cycles = strtoull(v, 0, 0); i++; }
        else if (!strcmp(o, "--stall-polls") && v)  { stall_polls = strtoull(v, 0, 0); i++; }
        else if (!strcmp(o, "--squash") && v)       { window = (uint32_t)strtoul(v, 0, 0); if (!window) window = 1; i++; }
        else if (!strcmp(o, "--model-opt") && v) {
            char kv[512];
            snprintf(kv, sizeof kv, "%s", v);
            char *eq = strchr(kv, '=');
            if (eq) *eq++ = 0;
            if (!ocv_model.configure || ocv_model.configure(kv, eq ? eq : "")) {
                fprintf(stderr, "ocv: model '%s' rejected option '%s'\n", ocv_model.name, v);
                return 1;
            }
            i++;
        }
        else if (!strcmp(o, "--reset-each-batch")) reset_each = 1;
        else if (!strcmp(o, "--quiet"))            quiet = 1;
        else if (!strcmp(o, "--profile"))          profile = 1;
        else if (!strcmp(o, "--no-block"))         no_block = 1;
        else if (!strcmp(o, "--no-dma"))           no_dma = 1;
        else if (!strcmp(o, "--ring-bytes") && v)  { ring_bytes = (size_t)strtoull(v, 0, 0); i++; }
        else if (!strcmp(o, "--slow-compare"))     slow_compare = 1;
        else if (!strcmp(o, "--overlap"))          overlap = 1;
        else if (!strcmp(o, "--no-overlap"))       overlap = 0;
        else if (!strcmp(o, "--no-interleave"))    no_interleave = 1;
        else if (!strcmp(o, "--info"))             return ocv_hub_info(bus, dut, stdout) ? 1 : 0;
        else { usage(argv[0]); return 1; }
    }

    run_t r;
    char err[256];
    memset(&r, 0, sizeof r);
    ocv_bus_t plain = *bus;
    if (no_block) { plain.rd_block = NULL; bus = &plain; }
    ocv_bus_t counting = { cnt_rd, cnt_wr, NULL, bus->rd_block ? cnt_rd_block : NULL,
                           bus->dma_va, bus->dma_pa, bus->dma_size, bus->dma_sync };   /* (the rings' cache upkeep too) */
    real_bus = bus;
    if (profile) bus = &counting;
    if (ocv_env_open(&r.env, bus, dut, err, sizeof err)) {
        fprintf(stderr, "ocv: %s\n", err);
        return 1;
    }

    /* outputs built with DMA empty themselves into rings in PS memory, when the bus has some */
    int n_rings = no_dma ? 0 : ocv_ring_setup(&r.env, ring_bytes);

    int n_src = 0;
    uint32_t min_depth = ~0u;              /* smallest source buffer: the default batch */
    for (int ch = 0; ch < dut->n_channels; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        if (c->kind != OCV_CH_SOURCE || c->stream) continue;
        n_src++;
        if (c->depth < min_depth) min_depth = c->depth;
    }
    if (n_src == 0) {
        fprintf(stderr, "ocv: '%s' has no (non-stream) source channel: nothing to start the DUT with\n", dut->name);
        RUN_END(1);
    }
    if (batch == 0) batch = min_depth;
    r.mask = calloc(dut->n_channels, sizeof *r.mask);
    r.by_mask = calloc(dut->n_channels, sizeof *r.by_mask);
    for (int ch = 0; ch < dut->n_channels; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        if (c->kind == OCV_CH_SOURCE) continue;
        r.mask[ch] = calloc(c->rec_words, 4);
        int maskable = ocv_channel_word_masks(c, r.mask[ch]);   /* also the bits a squash signs */
        r.by_mask[ch] = !slow_compare && maskable;
    }
    r.window = window;
    /* Overlap pays off only when records stream in during the run (lossless channels are drained
     * while the DUT runs). Otherwise every record arrives in one drain at the end of the batch:
     * nothing to overlap with, and a thread per batch costs more than it saves (measured on the
     * VD100: mac16 0.117 s sequential, 0.147 s overlapped). */
    for (int ch = 0; ch < dut->n_channels; ch++)
        if (dut->channels[ch].kind == OCV_CH_SOURCE && dut->channels[ch].stream) r.reactive = 1;
    if (ocv_model.react) r.reactive = 1;
    if (r.reactive && overlap == 1)
        fprintf(stderr, "ocv: --overlap ignored: a reactive model answers during the run, in the runner's thread\n");
    if (r.reactive) overlap = 0;
    if (overlap < 0) {
        overlap = 0;
        for (int ch = 0; ch < dut->n_channels; ch++)
            if (dut->channels[ch].kind != OCV_CH_SOURCE && dut->channels[ch].lossless) overlap = 1;
    }
    r.overlap = overlap;
    /* not overlapped: the model still runs while the DUT does - in this thread, polling as it goes */
    r.interleave = !overlap && !no_interleave;
    r.settle = (uint32_t)settle;
    r.il_prev = calloc(dut->n_channels, sizeof *r.il_prev);
    r.taken_hi = calloc(dut->n_channels, sizeof *r.taken_hi);
    r.taken_lo = calloc(dut->n_channels, sizeof *r.taken_lo);
    r.max_polls = max_polls;
    r.seen = calloc(dut->n_channels, sizeof *r.seen);
    r.stream_n = calloc(dut->n_channels, sizeof *r.stream_n);
    r.dirty = calloc(dut->n_channels, 1);
    r.answers = calloc(dut->n_channels, sizeof *r.answers);
    r.mm_ch = -1;
    pthread_mutex_init(&r.mu, NULL);
    pthread_cond_init(&r.cv, NULL);
    r.q = calloc(dut->n_channels, sizeof *r.q);
    int n_squash = 0;
    for (int ch = 0; ch < dut->n_channels; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        r.q[ch].qw = ocv_store_words(c);
        r.q[ch].sq.window = window; r.q[ch].sq.words = c->rec_words; r.q[ch].sq.mask = r.mask[ch];   /* (io->squash) */
        if (c->kind != OCV_CH_SOURCE && c->squash) {
            ocv_squash_window(&r.env, ch, window);
            uint32_t got_w = ocv_ep_rd(&r.env, ch, OCV_EP_REG_SQUASH);
            if (got_w != window) {
                fprintf(stderr, "ocv: channel '%s' took squash window %u, asked %u\n", c->name, got_w, window);
                RUN_END(1);
            }
            n_squash++;
        }
    }
    if (window > 1 && !n_squash)
        fprintf(stderr, "ocv: --squash %u: no channel of '%s' is built with squash; records compared one by one\n",
                window, dut->name);
    /* with --squash > 1 a reactive model sees the channels that are not squashed (squashed ones are
     * collected as windows, not handed to react()) */
    r.react_skip_squash = window > 1;
    r.stim = calloc(dut->n_channels, sizeof *r.stim);
    r.n_stim = calloc(dut->n_channels, sizeof *r.n_stim);
    r.order = calloc((size_t)batch * n_src, sizeof *r.order);
    uint64_t *stim_index = calloc(dut->n_channels, sizeof *stim_index);
    for (int ch = 0; ch < dut->n_channels; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        if (c->kind == OCV_CH_SOURCE && !c->stream) {   /* stream sources are fed by react() */
            r.stim[ch] = calloc((size_t)(batch < c->depth ? batch : c->depth) * c->rec_words, 4);
        }
    }

    for (int ch = 0; ch < dut->n_channels; ch++) {
        if (dut->channels[ch].kind == OCV_CH_SOURCE)      /* streams: answer latency, separately */
            ocv_ep_wr(&r.env, ch, OCV_EP_REG_THROTTLE, dut->channels[ch].stream ? thr_stream : thr_in);
        else if (r.env.ep[ch].kind & OCV_KIND_BACKPRESSURE)
            ocv_ep_wr(&r.env, ch, OCV_EP_REG_THROTTLE, thr_out);
    }

    /* (OCV_NO_EMITN=1: records one by one, emit() - to tell the batched path apart when something differs) */
    ocv_model_io_t io = { emit, observed, &r, send_rec, 0, getenv("OCV_NO_EMITN") ? NULL : emit_n,
                          getenv("OCV_NO_FOLD") ? NULL : fold_make, emit_fold,
                          getenv("OCV_NO_SQPUSH") ? NULL : squash, squash_close, peek, progress, idle };
    r.io = &io;
    uint64_t rng = seed ? seed : 1, stim_total = 0, cycles = 0, polls_total = 0, done_batches = 0;
    double t0 = now_s();
    ph_t0 = t0;
    if (!quiet)
        printf("OCV: %s (DUT_ID 0x%08x), model '%s', %u channel(s), up to %llu batch(es) x %u stimulus records,"
               " throttle in/out %u/%u, model %s\n", dut->name, dut->dut_id, ocv_model.name, dut->n_channels,
               (unsigned long long)batches, batch, thr_in, thr_out,
               r.reactive ? "reactive (answers the DUT during the run)"
               : r.overlap ? "in its own thread (--overlap)" : "after the DUT (--no-overlap)");
    if (!quiet && n_rings) {
        printf("OCV: outputs over DMA rings in PS memory:");
        for (int ch = 0; ch < dut->n_channels; ch++)
            if (ocv_ring_on(&r.env, ch))
                printf(" %s (%u x %u B)", dut->channels[ch].name, 1u << r.env.ep[ch].ring_log2,
                       1u << r.env.ep[ch].slot_log2);
        printf("\n");
    }

    for (uint64_t b = 0; b < batches; b++) {
        int in_reset = (b == 0 || reset_each);
        io.batch = b;

        /* 1. stimulus */
        phase(PH_STIM);
        int active[256];
        uint32_t n_order = 0;
        for (int ch = 0; ch < dut->n_channels; ch++) {
            active[ch] = dut->channels[ch].kind == OCV_CH_SOURCE && !dut->channels[ch].stream;
            r.n_stim[ch] = 0;
        }
        for (uint32_t i = 0; i < batch; i++) {
            int any = 0;
            for (int ch = 0; ch < dut->n_channels; ch++) {
                if (!active[ch]) continue;
                const ocv_channel_t *c = &dut->channels[ch];
                if (r.n_stim[ch] >= c->depth) { active[ch] = 0; continue; }   /* this source is full */
                uint32_t *rec = r.stim[ch] + (size_t)r.n_stim[ch] * c->rec_words;
                memset(rec, 0, c->rec_words * 4u);
                int got = 1;
                if (ocv_model.stimulus)
                    got = ocv_model.stimulus(ch, stim_index[ch], rec, &rng);
                else
                    for (int f = 0; f < c->n_fields; f++) ocv_set_raw(rec, &c->fields[f], ocv_rand(&rng));
                if (!got) { active[ch] = 0; continue; }
                r.order[n_order++] = (stim_ref_t){ (uint16_t)ch, r.n_stim[ch] };
                r.n_stim[ch]++;
                stim_index[ch]++;
                any = 1;
            }
            if (!any) break;
        }
        if (n_order == 0) {
            if (b == 0) { fprintf(stderr, "ocv: the model produced no stimulus\n"); return 1; }
            break;                                   /* stimulus exhausted: the run is complete */
        }
        stim_total += n_order;

        /* 2. run */
        phase(PH_LOAD);
        if (in_reset) {
            if (b) cycles += ocv_cycles(&r.env);
            ocv_dut_reset(&r.env, 1);
        } else {
            for (int ch = 0; ch < dut->n_channels; ch++)
                if (dut->channels[ch].kind == OCV_CH_SOURCE) ocv_ep_wr(&r.env, ch, OCV_EP_REG_CTRL, 0);
        }
        for (int ch = 0; ch < dut->n_channels; ch++) {
            const ocv_channel_t *c = &dut->channels[ch];
            if (c->kind != OCV_CH_SOURCE) continue;
            for (uint32_t i = 0; i < r.n_stim[ch]; i++)
                ocv_rec_write(&r.env, ch, i, r.stim[ch] + (size_t)i * c->rec_words);
            ocv_ep_wr(&r.env, ch, OCV_EP_REG_LENGTH, r.n_stim[ch]);
        }
        for (int ch = 0; ch < dut->n_channels; ch++)
            if (dut->channels[ch].kind != OCV_CH_SOURCE)
                ocv_ep_wr(&r.env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
        /* stream sources first: once stimulus flows the DUT may ask at once, and must find its
         * answer channel live (enabled, so a wait freezes it) */
        for (int pass = 0; pass < 2; pass++)
            for (int ch = 0; ch < dut->n_channels; ch++)
                if (dut->channels[ch].kind == OCV_CH_SOURCE && !!dut->channels[ch].stream == (pass == 0))
                    ocv_ep_wr(&r.env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
        if (in_reset) ocv_dut_reset(&r.env, 0);

        /* wait until every source is done and the outputs stop growing; a full lossless buffer
         * (the DUT is frozen meanwhile) is emptied into the host copy and the DUT resumes */
        for (int ch = 0; ch < dut->n_channels; ch++) {
            queue_t *q = &r.q[ch];
            if (in_reset) q->stream = 0;
            else          q->stream += q->exp.n;
            q->exp.n = 0;
            q->got.n = 0;
        }
        r.in_reset = in_reset;
        r.n_order = n_order;
        for (int ch = 0; ch < dut->n_channels; ch++) { r.seen[ch] = 0; r.stream_n[ch] = 0; r.dirty[ch] = 0; }
        pthread_t model_tid;
        if (r.overlap) {
            for (int ch = 0; ch < dut->n_channels; ch++) {
                r.q[ch].pub_w = r.q[ch].got.w;
                r.q[ch].pub_n = 0;
            }
            r.dut_done = 0;
            __atomic_store_n(&r.stop, 0, __ATOMIC_RELAXED);
            if (pthread_create(&model_tid, NULL, model_thread, &r)) {
                fprintf(stderr, "ocv: cannot start the model thread\n");
                RUN_END(1);
            }
        }
        /* interleaved: the model now, while the DUT runs (it polls the DUT itself); the wait below then
         * only sees the DUT go quiet */
        if (r.interleave) {
            for (int ch = 0; ch < dut->n_channels; ch++) { r.il_prev[ch] = ~0u; r.taken_hi[ch] = 0; r.taken_lo[ch] = 0; }
            r.il_active = 1; r.il_quiet = 0; r.il_settled = 0; r.il_polls = 0;
            phase(PH_MODEL);
            model_thread(&r);
            r.il_active = 0;
        }
        phase(PH_WAIT);
        uint64_t polls = 0, still = 0;         /* polls without any channel moving */
        const uint64_t cyc0 = max_cycles ? ocv_cycles(&r.env) : 0;
        int timed_out = 0;
        uint32_t prev[256], src_prev[256];
        int settled = 0;
        for (int ch = 0; ch < dut->n_channels; ch++) prev[ch] = src_prev[ch] = ~0u;
        for (;;) {
            int quiet_now = 1, moved = 0, pending = 0;
            for (int ch = 0; ch < dut->n_channels; ch++) {
                const ocv_channel_t *c = &dut->channels[ch];
                if (c->kind == OCV_CH_SOURCE) {
                    if (!(ocv_ep_rd(&r.env, ch, OCV_EP_REG_STATUS) & OCV_SRC_ST_DONE)) {
                        quiet_now = 0;
                        pending = 1;
                        uint32_t sent = ocv_ep_rd(&r.env, ch, OCV_EP_REG_COUNT);
                        if (sent != src_prev[ch]) moved = 1;
                        src_prev[ch] = sent;
                    }
                } else if (r.reactive && !(r.react_skip_squash && c->squash)) {
                    if (react_new(&r, ch)) quiet_now = 0, moved = 1;
                } else {
                    uint32_t n = ocv_ep_rd(&r.env, ch, OCV_EP_REG_COUNT);
                    if (ocv_ring_on(&r.env, ch)) {
                        if (n != r.env.ep[ch].tail) collect(&r, ch, 0);   /* whatever reached memory */
                    } else if (c->lossless && n == c->depth) {
                        collect(&r, ch, 1);
                        r.q[ch].drains++;
                        n = ~0u;
                    }
                    if (c->squash && n != ~0u)           /* fused: watch the DUT records taken instead */
                        n = ocv_ep_rd(&r.env, ch, OCV_EP_REG_TAKEN);
                    if (n != prev[ch]) quiet_now = 0, moved = 1;
                    prev[ch] = n;
                }
            }
            polls++;
            settled = quiet_now ? settled + 1 : 0;
            if (settled >= settle) break;
            if (r.overlap && __atomic_load_n(&r.stop, __ATOMIC_RELAXED)) break;   /* mismatch found */
            /* stimulus still waiting and nothing moves anywhere: the DUT is stuck (e.g. a reactive
             * DUT waiting for the answer to a request the platform never saw) */
            still = (pending && !moved) ? still + 1 : 0;
            if (stall_polls && still >= stall_polls) {
                printf("FAIL: DUT stalled - stimulus pending but no channel moved for %llu polls (batch %llu)\n",
                       (unsigned long long)still, (unsigned long long)b);
                for (int ch = 0; ch < dut->n_channels; ch++)
                    if (dut->channels[ch].kind == OCV_CH_SOURCE)
                        printf("  source '%s': %u taken\n", dut->channels[ch].name, ocv_ep_rd(&r.env, ch, OCV_EP_REG_COUNT));
                    else
                        printf("  output '%s': %u records so far\n", dut->channels[ch].name, r.q[ch].got.n);
                RUN_END(2);
            }
            /* a DUT that never ends: what it did so far is compared (the first wrong record says
             * where it went astray), then the run fails */
            if (max_cycles && (polls & 255) == 0 && ocv_cycles(&r.env) - cyc0 > max_cycles) {
                timed_out = 1;
                ocv_dut_reset(&r.env, 1);           /* held: its records stop where they are */
                break;
            }
            if (polls >= max_polls) {
                printf("FAIL: DUT did not go quiet within %llu status polls (batch %llu)\n",
                       (unsigned long long)max_polls, (unsigned long long)b);
                RUN_END(2);
            }
        }
        polls_total += polls;

        /* squash: the DUT is quiet - emit the open windows (one more fused record each) */
        if (n_squash) {
            for (int ch = 0; ch < dut->n_channels; ch++)
                if (dut->channels[ch].kind != OCV_CH_SOURCE && dut->channels[ch].squash) ocv_squash_flush(&r.env, ch);
            (void)ocv_ep_rd(&r.env, 0, OCV_EP_REG_ID);   /* a read after the writes: emitted by then */
        }

        /* the rest of every output buffer joins the host copy */
        uint32_t lost[256];
        for (int ch = 0; ch < dut->n_channels; ch++) {
            if (dut->channels[ch].kind == OCV_CH_SOURCE) continue;
            lost[ch] = ocv_ep_rd(&r.env, ch, OCV_EP_REG_DROPPED);
            if (r.reactive && !(r.react_skip_squash && dut->channels[ch].squash)) react_new(&r, ch);
            else collect(&r, ch, 0);
            if (ocv_ring_on(&r.env, ch)) {
                if (r.reactive && !(r.react_skip_squash && dut->channels[ch].squash))
                    while (ocv_ring_pending(&r.env, ch)) react_new(&r, ch);
                if (ring_finish(&r, ch, max_polls)) RUN_END(2);
            }
        }

        /* 3. model: reset if the DUT was, then feed the stimulus in the order it was sent (with
         * --overlap it has been running all along: tell it the DUT is done and wait for it) */
        phase(PH_MODEL);
        if (r.overlap) {
            pthread_mutex_lock(&r.mu);
            r.dut_done = 1;
            pthread_cond_broadcast(&r.cv);
            pthread_mutex_unlock(&r.mu);
            pthread_join(model_tid, NULL);
            for (int ch = 0; ch < dut->n_channels; ch++) {
                queue_t *q = &r.q[ch];
                for (unsigned k = 0; k < q->n_retired; k++) free(q->retired[k]);
                q->n_retired = 0;
            }
        } else if (!r.interleave) {
            model_thread(&r);
        }
        for (int ch = 0; ch < dut->n_channels; ch++) {          /* squash: the model's open windows */
            const ocv_channel_t *c = &dut->channels[ch];
            queue_t *q = &r.q[ch];
            if (c->kind == OCV_CH_SOURCE || !c->squash || q->sq.n == 0) continue;
            uint32_t fused[259];
            memcpy(fused, q->sq.last, c->rec_words * 4u);
            fused[c->rec_words] = q->sq.n;
            fused[c->rec_words + 1] = q->sq.c;
            fused[c->rec_words + 2] = q->sq.z;
            q->sq.n = 0;
            recbuf_push(&q->exp, fused, q->qw);
            uint32_t i = q->exp.n - 1;
            if (r.overlap && r.mm_ch < 0 && i < q->got.n) {
                int f = rec_diff(&r, ch, q->got.w + (size_t)i * q->qw, fused);
                if (f < 0) q->compared += fused[c->rec_words];
                else { r.mm_ch = ch; r.mm_i = i; r.mm_field = f; }
            }
        }

        /* 4. check: sources drained, nothing lost, then records, then counts */
        phase(PH_CHECK);
        for (int ch = 0; ch < dut->n_channels; ch++) {
            const ocv_channel_t *c = &dut->channels[ch];
            queue_t *q = &r.q[ch];
            if (c->kind == OCV_CH_SOURCE) {
                if (timed_out) continue;
                uint32_t sent = ocv_ep_rd(&r.env, ch, OCV_EP_REG_COUNT);
                uint32_t want = c->stream ? r.stream_n[ch] : r.n_stim[ch];   /* stream: the answers */
                if (sent != want) {
                    printf("FAIL channel '%s': DUT accepted %u of %u %s records (batch %llu) - DUT stalled?\n",
                           c->name, sent, want, c->stream ? "answer" : "stimulus", (unsigned long long)b);
                    RUN_END(2);
                }
                continue;
            }
            if (lost[ch]) {
                printf("FAIL channel '%s': %u records lost (buffer of %u full) in batch %llu\n", c->name, lost[ch],
                       c->depth, (unsigned long long)b);
                RUN_END(2);
            }
            uint32_t n = q->got.n < q->exp.n ? q->got.n : q->exp.n;
            if (r.overlap) {                     /* already compared by the model thread */
                if (r.mm_ch == ch) RUN_END(report_mismatch(&r, ch, r.mm_i, r.mm_field, context, b));
            } else {
                for (uint32_t i = 0; i < n; i++) {
                    int f = rec_diff(&r, ch, q->got.w + (size_t)i * q->qw, q->exp.w + (size_t)i * q->qw);
                    if (f >= 0) RUN_END(report_mismatch(&r, ch, i, f, context, b));
                    q->compared += c->squash ? q->got.w[(size_t)i * q->qw + c->rec_words] : 1;
                }
            }
            if (timed_out) continue;            /* cut short: the counts cannot agree */
            int drained = c->lossless || ocv_ring_on(&r.env, ch)
                          || (r.reactive && (r.env.ep[ch].kind & OCV_KIND_BACKPRESSURE));
            if (!drained && q->exp.n > c->depth) {
                printf("FAIL channel '%s': model expects %u records in batch %llu but the buffer holds %u;"
                       " use a smaller --batch, a deeper or a lossless channel (first %u match)\n",
                       c->name, q->exp.n, (unsigned long long)b, c->depth, n);
                RUN_END(2);
            }
            if (q->got.n != q->exp.n) {
                printf("FAIL channel '%s': DUT produced %u %srecords, model expects %u (batch %llu, first %u match)\n",
                       c->name, q->got.n, (c->squash && window > 1) ? "fused " : "", q->exp.n,
                       (unsigned long long)b, n);
                if (c->squash) {
                    if (r.obs_squash)
                        printf("  note: the model asked for DUT records it cannot see in squash mode (observed())\n");
                    squash_replay(&r);
                }
                RUN_END(2);
            }
        }
        if (timed_out) {
            printf("FAIL: DUT still running after %llu clocks (batch %llu, --max-cycles) - it does not end;"
                   " every record it made until then matches\n", (unsigned long long)max_cycles, (unsigned long long)b);
            for (int ch = 0; ch < dut->n_channels; ch++)
                if (dut->channels[ch].kind != OCV_CH_SOURCE)
                    printf("  output '%s': DUT %u records, model %u\n", dut->channels[ch].name, r.q[ch].got.n,
                           r.q[ch].exp.n);
            RUN_END(2);
        }
        phase(PH_OTHER);
        done_batches++;
        if (!quiet)
            printf("  batch %llu: ok (%u stimulus records)\n", (unsigned long long)b, n_order);
    }
    cycles += ocv_cycles(&r.env);
    phase(PH_OTHER);
    double dt = now_s() - t0;
    uint64_t compared_total = 0;
    for (int ch = 0; ch < dut->n_channels; ch++) compared_total += r.q[ch].compared;
    if (compared_total == 0)
        printf("WARNING: no output record was compared - is the stimulus complete (--batch/--batches)?\n");

    printf("OCV: %s PASS - %llu batch(es), %llu stimulus records,", dut->name,
           (unsigned long long)done_batches, (unsigned long long)stim_total);
    for (int ch = 0; ch < dut->n_channels; ch++)
        if (dut->channels[ch].kind != OCV_CH_SOURCE) {
            printf(" %s=%llu", dut->channels[ch].name, (unsigned long long)r.q[ch].compared);
            if (r.q[ch].drains) printf(" (%llu drains)", (unsigned long long)r.q[ch].drains);
        }
    printf(" compared;");
    if (n_squash && window > 1) printf(" squash window %u;", window);
    for (int ch = 0; ch < dut->n_channels; ch++)
        if (dut->channels[ch].kind == OCV_CH_SOURCE && dut->channels[ch].stream)
            printf(" %llu answers on %s;", (unsigned long long)r.answers[ch], dut->channels[ch].name);
    uint64_t answers = 0;
    for (int ch = 0; ch < dut->n_channels; ch++) answers += r.answers[ch];
    if (answers) printf(" %.2f us per answer;", dt / (double)answers * 1e6);   /* reaction time */
    printf(" %llu DUT cycles, %.3f s, %llu status polls\n", (unsigned long long)cycles, dt,
           (unsigned long long)polls_total);
    if (r.obs_squash)
        printf("NOTE: the model asked for DUT records it cannot see with --squash %u (observed()); its own values"
               " were used - they matched\n", window);
    if (profile) {
        profile_report(&r.env, dt);
        if (r.overlap)
            printf("PROFILE: model thread (--overlap): busy %.4f s, of it waiting for DUT records %.4f s;"
                   " 'reference model' above = main thread waiting for it\n", r.model_busy, r.model_wait);
    }

    for (int ch = 0; ch < dut->n_channels; ch++) { free(r.q[ch].exp.w); free(r.q[ch].got.w); free(r.stim[ch]); }
    for (int ch = 0; ch < dut->n_channels; ch++) free(r.mask[ch]);
    free(r.il_prev); free(r.taken_hi); free(r.taken_lo);
    for (int ch = 0; ch < dut->n_channels; ch++) free(r.q[ch].retired);
    free(r.mask); free(r.by_mask); free(r.seen); free(r.stream_n); free(r.dirty); free(r.answers);
    free(r.q); free(r.stim); free(r.n_stim); free(r.order); free(stim_index);
    ocv_env_close(&r.env);
    return 0;
}
