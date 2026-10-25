/* ocv_uvm_model.c - the whole-DUT reference model of a UVM testbench (ocv_model_checker, uvm/ocv_uvm_pkg.sv):
 * an OCV model (ocv_model.h - the one the runner takes, e.g. models/cpu/ocv_cpu_model.c for a processor core)
 * checks every record of every output channel, in simulation. The testbench's agents hand it what they see:
 * the base driver every record the DUT was given (ocv_dpi_model_in), the base monitor every record the DUT
 * made (ocv_dpi_model_out) - no UVM object per check; the board build checks the same channels in C as they
 * leave the FPGA.
 *
 * Two threads besides the simulation, as the runner's overlap mode has them:
 *   - the model's: input() with the stimulus in order (a processor model runs the program at the last word),
 *     each emit() compared with the DUT's record of that channel - waiting for it if the simulation has not
 *     made it yet (the DUT's records are kept in a ring per channel, observed() reads them);
 *   - react's: every DUT output record in arrival order to the model's react() (a processor core's device
 *     requests); the answers are the testbench's - what its driver gave the DUT on the answer channel
 *     (ocv_cpu_dev_hook waits for it), so the model sees the devices the testbench models.
 *
 * DPI:
 *   int  ocv_dpi_model_open(string opts)    "key=value ..." model options (configure), reset; 1 if a model is linked
 *   void ocv_dpi_model_in(int ch, rec)      a record the DUT was given on source channel ch
 *   void ocv_dpi_model_out(int ch, rec)     a record the DUT made on output channel ch
 *   void ocv_dpi_model_status(output longint checked, output longint errors, output int done)
 *   int  ocv_dpi_model_mismatch(output int ch, output rec dut, output rec exp, output int field, output longint index)
 *   string ocv_dpi_model_channel(int ch)    a channel's name (reports)
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ocv.h"
#include "ocv_model.h"

#define REC_WORDS 32                            /* = OCV_UVM_REC_BITS / 32 in ocv_uvm_pkg.sv */
#define MAX_CH    64
#define RING      (1u << 20)                    /* DUT records kept per channel (observed() reads back) */
#define MAX_MISS  16

/* the model, if the testbench links one (weak: the package's DPI is in every build) */
extern const ocv_dut_t   *const ocv_model_dut __attribute__((weak));
extern const ocv_model_t        ocv_model __attribute__((weak));
extern uint32_t (*ocv_cpu_dev_hook)(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle)
    __attribute__((weak));

typedef struct {
    uint32_t *w;                                /* RING records of rec_words */
    uint64_t  n;                                /* records the DUT made */
    uint64_t  next;                             /* the next one emit() compares */
} ring_t;

typedef struct { uint32_t rec[REC_WORDS]; int ch; } item_t;
typedef struct { item_t *v; size_t head, n, cap; } fifo_t;

static struct {
    const ocv_dut_t *dut;
    pthread_mutex_t  mu;
    pthread_cond_t   cv;
    ring_t           out[MAX_CH];
    fifo_t           in, react, answers;
    int              opened, started, model_done, stop, quiet;
    uint64_t         total;                     /* DUT records of all output channels */
    uint64_t         inputs, queued;            /* stimulus records the model has taken / was given */
    int              in_last;                   /* the stimulus is complete (ocv_dpi_model_in_done) */
    uint64_t         checked, errors;
    struct { int ch, field; uint64_t index; uint32_t dut[REC_WORDS], exp[REC_WORDS]; } miss[MAX_MISS];
    int              n_miss, head_miss;
    pthread_t        th_model, th_react;
    int              answer_ch;                 /* the source channel a device read's answer comes on */
} m = { .mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER, .answer_ch = -1 };

static void push(fifo_t *f, int ch, const uint32_t *rec, int words)
{
    if (f->n == f->cap) {
        size_t cap = f->cap ? 2 * f->cap : 1024;
        item_t *v = malloc(cap * sizeof *v);
        if (!v) { perror("ocv_uvm_model"); exit(1); }
        for (size_t i = 0; i < f->n; i++) v[i] = f->v[(f->head + i) % f->cap];
        free(f->v);
        f->v = v; f->cap = cap; f->head = 0;
    }
    item_t *it = &f->v[(f->head + f->n) % f->cap];
    memset(it, 0, sizeof *it);
    memcpy(it->rec, rec, (size_t)words * 4);
    it->ch = ch;
    f->n++;
}

static int pop(fifo_t *f, item_t *out)          /* under m.mu: waits; 0 when stopped (or the stimulus ended) and empty */
{
    while (!f->n && !m.stop && !(f == &m.in && m.in_last)) pthread_cond_wait(&m.cv, &m.mu);
    if (!f->n) return 0;
    *out = f->v[f->head];
    f->head = (f->head + 1) % f->cap;
    f->n--;
    return 1;
}

/* ---- the model's io ---- */
static void io_emit(ocv_model_io_t *io, int ch, const uint32_t *rec)
{
    (void)io;
    const ocv_channel_t *c = &m.dut->channels[ch];
    ring_t *r = &m.out[ch];
    pthread_mutex_lock(&m.mu);
    while (r->n <= r->next && !m.stop && !m.quiet) pthread_cond_wait(&m.cv, &m.mu);
    if (r->n <= r->next) {                      /* the DUT made no such record (quiet), or the test ended */
        if (m.quiet && !m.stop) {
            m.checked++;
            m.errors++;
            if (m.n_miss < MAX_MISS) {
                const int k = (m.head_miss + m.n_miss++) % MAX_MISS;
                m.miss[k].ch = ch; m.miss[k].field = -1; m.miss[k].index = r->next;
                memset(m.miss[k].dut, 0, sizeof m.miss[k].dut);
                memset(m.miss[k].exp, 0, sizeof m.miss[k].exp);
                memcpy(m.miss[k].exp, rec, (size_t)c->rec_words * 4);
            }
            r->next++;
        }
        pthread_mutex_unlock(&m.mu);
        return;
    }
    const uint32_t *d = r->w + (size_t)(r->next % RING) * c->rec_words;
    const int f = ocv_rec_mismatch(c, d, rec);
    m.checked++;
    if (f >= 0) {
        m.errors++;
        if (m.n_miss < MAX_MISS) {
            const int k = (m.head_miss + m.n_miss++) % MAX_MISS;
            m.miss[k].ch = ch; m.miss[k].field = f; m.miss[k].index = r->next;
            memset(m.miss[k].dut, 0, sizeof m.miss[k].dut);
            memset(m.miss[k].exp, 0, sizeof m.miss[k].exp);
            memcpy(m.miss[k].dut, d, (size_t)c->rec_words * 4);
            memcpy(m.miss[k].exp, rec, (size_t)c->rec_words * 4);
        }
    }
    r->next++;
    pthread_cond_broadcast(&m.cv);              /* (a full ring frees a slot) */
    pthread_mutex_unlock(&m.mu);
}

static int io_observed(ocv_model_io_t *io, int ch, uint32_t index, uint32_t *rec)
{
    (void)io;
    const ocv_channel_t *c = &m.dut->channels[ch];
    ring_t *r = &m.out[ch];
    pthread_mutex_lock(&m.mu);
    while (r->n <= index && !m.stop && !m.quiet) pthread_cond_wait(&m.cv, &m.mu);
    int ok = r->n > index && r->n - index <= RING;
    if (ok) memcpy(rec, r->w + (size_t)(index % RING) * c->rec_words, (size_t)c->rec_words * 4);
    pthread_mutex_unlock(&m.mu);
    return ok;
}

/* interleaved, as the runner's overlap mode: observed() without waiting; the records the DUT made so far
 * (UINT64_MAX once it is quiet - it makes no more: the model may go to the end); let the DUT go on */
static int io_peek(ocv_model_io_t *io, int ch, uint32_t index, uint32_t *rec)
{
    (void)io;
    const ocv_channel_t *c = &m.dut->channels[ch];
    ring_t *r = &m.out[ch];
    pthread_mutex_lock(&m.mu);
    int ok = r->n > index && r->n - index <= RING;
    if (ok) memcpy(rec, r->w + (size_t)(index % RING) * c->rec_words, (size_t)c->rec_words * 4);
    pthread_mutex_unlock(&m.mu);
    return ok;
}

static uint64_t io_progress(ocv_model_io_t *io, int ch)
{
    (void)io;
    pthread_mutex_lock(&m.mu);
    const uint64_t n = m.quiet || m.stop ? UINT64_MAX : m.out[ch].n;
    pthread_mutex_unlock(&m.mu);
    return n;
}

static void io_idle(ocv_model_io_t *io)
{
    (void)io;
    struct timespec t;
    clock_gettime(CLOCK_REALTIME, &t);
    t.tv_nsec += 1000000;                       /* up to 1 ms: new records, or the end */
    if (t.tv_nsec >= 1000000000) { t.tv_sec++; t.tv_nsec -= 1000000000; }
    pthread_mutex_lock(&m.mu);
    const uint64_t seen = m.total;
    while (m.total == seen && !m.quiet && !m.stop)
        if (pthread_cond_timedwait(&m.cv, &m.mu, &t)) break;
    pthread_mutex_unlock(&m.mu);
}

static void io_send(ocv_model_io_t *io, int ch, const uint32_t *rec)
{
    (void)io; (void)ch; (void)rec;              /* the DUT got the testbench's answer from its own driver */
}

static ocv_model_io_t io = { .emit = io_emit, .observed = io_observed, .send = io_send,
                             .peek = io_peek, .progress = io_progress, .idle = io_idle };

/* ---- the threads ---- */
static void *model_thread(void *arg)
{
    (void)arg;
    item_t it;
    pthread_mutex_lock(&m.mu);
    static int dbg = -1;
    if (dbg < 0) dbg = getenv("OCV_UVM_MODEL_DEBUG") ? atoi(getenv("OCV_UVM_MODEL_DEBUG")) : 0;
    if (dbg) fprintf(stderr, "ocv_uvm_model: model thread up, %zu queued\n", m.in.n);
    while (pop(&m.in, &it)) {
        pthread_mutex_unlock(&m.mu);
        if (dbg > 1) fprintf(stderr, "ocv_uvm_model: input ch %d\n", it.ch);
        ocv_model.input(it.ch, it.rec, &io);
        pthread_mutex_lock(&m.mu);
        m.inputs++;
        if (dbg) fprintf(stderr, "ocv_uvm_model: input %llu (channel %d) done: %llu checked, %llu DUT records\n",
                         (unsigned long long)m.inputs, it.ch, (unsigned long long)m.checked,
                         (unsigned long long)m.total);
        /* the stimulus is all in and the model has taken it (a processor model: the program run to its end) */
        if (!m.in.n && m.in_last) break;
    }
    m.model_done = 1;
    pthread_cond_broadcast(&m.cv);
    pthread_mutex_unlock(&m.mu);
    return NULL;
}

/* a device read's answer: the testbench's, as its driver gave it to the DUT (in order) */
static uint32_t dev_hook(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle)
{
    (void)dev; (void)addr; (void)be; (void)wdata; (void)cycle;
    if (we) return 0;
    item_t it;
    uint32_t v = 0;
    pthread_mutex_lock(&m.mu);
    if (pop(&m.answers, &it)) {
        const ocv_channel_t *c = &m.dut->channels[it.ch];
        v = (uint32_t)ocv_get_raw(it.rec, &c->fields[0]);
    }
    pthread_mutex_unlock(&m.mu);
    return v;
}

static void *react_thread(void *arg)
{
    (void)arg;
    item_t it;
    pthread_mutex_lock(&m.mu);
    while (pop(&m.react, &it)) {
        pthread_mutex_unlock(&m.mu);
        ocv_model.react(it.ch, it.rec, &io);
        pthread_mutex_lock(&m.mu);
    }
    pthread_mutex_unlock(&m.mu);
    return NULL;
}

static void start(void)
{
    if (m.started) return;
    m.started = 1;
    if (pthread_create(&m.th_model, NULL, model_thread, NULL)) { perror("ocv_uvm_model"); exit(1); }
    if (ocv_model.react && pthread_create(&m.th_react, NULL, react_thread, NULL)) { perror("ocv_uvm_model"); exit(1); }
}

/* ---- DPI ---- */
int ocv_dpi_model_open(const char *opts)
{
    if (getenv("OCV_UVM_MODEL_DEBUG"))
        fprintf(stderr, "ocv_uvm_model: open '%s': model %s\n", opts ? opts : "", &ocv_model ? ocv_model.name : "none");
    if (!&ocv_model || !&ocv_model_dut) return 0;
    if (m.opened) return 1;
    m.dut = ocv_model_dut;
    if (m.dut->n_channels > MAX_CH) { fprintf(stderr, "ocv_uvm_model: too many channels\n"); return 0; }
    char *s = strdup(opts ? opts : ""), *save = NULL;
    for (char *t = strtok_r(s, " ", &save); t; t = strtok_r(NULL, " ", &save)) {
        char *eq = strchr(t, '=');
        if (!eq || !ocv_model.configure) continue;
        *eq = 0;
        if (ocv_model.configure(t, eq + 1)) fprintf(stderr, "ocv_uvm_model: model option '%s' not taken\n", t);
    }
    free(s);
    for (int ch = 0; ch < m.dut->n_channels; ch++) {
        const ocv_channel_t *c = &m.dut->channels[ch];
        if (c->kind == OCV_CH_SOURCE) continue;
        if (!(m.out[ch].w = calloc((size_t)RING * c->rec_words, 4))) { perror("ocv_uvm_model"); exit(1); }
    }
    if (&ocv_cpu_dev_hook) {                    /* a processor core under OCV's wrapper: its device answers */
        ocv_cpu_dev_hook = dev_hook;
        for (int ch = 0; ch < m.dut->n_channels; ch++)
            if (!strcmp(m.dut->channels[ch].name, "dev_resp")) m.answer_ch = ch;
    }
    ocv_model.reset();
    m.opened = 1;
    return 1;
}

void ocv_dpi_model_in(int ch, const uint32_t *rec)
{
    if (getenv("OCV_UVM_MODEL_DEBUG"))
        fprintf(stderr, "ocv_uvm_model: in ch %d '%s' stream %d (opened %d, %d channels)\n", ch,
                m.dut ? m.dut->channels[ch].name : "?", m.dut ? m.dut->channels[ch].stream : -1, m.opened,
                m.dut ? m.dut->n_channels : -1);
    if (!m.opened || ch < 0 || ch >= m.dut->n_channels) return;
    const ocv_channel_t *c = &m.dut->channels[ch];
    pthread_mutex_lock(&m.mu);
    /* every record the DUT was given goes to the model's input(); the core wrapper's device answers (dev_resp)
     * also to the device hook, which hands them to the model's react() */
    push(&m.in, ch, rec, c->rec_words);
    m.queued++;
    if (ch == m.answer_ch) push(&m.answers, ch, rec, c->rec_words);
    pthread_cond_broadcast(&m.cv);
    pthread_mutex_unlock(&m.mu);
    start();
}

void ocv_dpi_model_out(int ch, const uint32_t *rec)
{
    if (!m.opened || ch < 0 || ch >= m.dut->n_channels) return;
    const ocv_channel_t *c = &m.dut->channels[ch];
    ring_t *r = &m.out[ch];
    if (!r->w) return;
    pthread_mutex_lock(&m.mu);
    /* the model is far behind (r->next may pass r->n: records it took as missing once the DUT was quiet) */
    while (r->n >= r->next + RING && !m.stop) pthread_cond_wait(&m.cv, &m.mu);
    memcpy(r->w + (size_t)(r->n % RING) * c->rec_words, rec, (size_t)c->rec_words * 4);
    r->n++;
    m.total++;
    if (ocv_model.react) push(&m.react, ch, rec, c->rec_words);
    pthread_cond_broadcast(&m.cv);
    pthread_mutex_unlock(&m.mu);
}

void ocv_dpi_model_status(long long *checked, long long *errors, int *done)
{
    pthread_mutex_lock(&m.mu);
    *checked = (long long)m.checked;
    *errors = (long long)m.errors;
    /* done: the model has taken all the stimulus it was given and checked something (a processor model takes the
     * last program word only when the program has run to its end) */
    *done = m.model_done || (m.inputs == m.queued && m.queued && m.checked);
    pthread_mutex_unlock(&m.mu);
}

int ocv_dpi_model_mismatch(int *ch, uint32_t *dut, uint32_t *exp, int *field, long long *index)
{
    pthread_mutex_lock(&m.mu);
    if (!m.n_miss) { pthread_mutex_unlock(&m.mu); return 0; }
    const int k = m.head_miss;
    *ch = m.miss[k].ch; *field = m.miss[k].field; *index = (long long)m.miss[k].index;
    memcpy(dut, m.miss[k].dut, sizeof m.miss[k].dut);
    memcpy(exp, m.miss[k].exp, sizeof m.miss[k].exp);
    m.head_miss = (m.head_miss + 1) % MAX_MISS;
    m.n_miss--;
    pthread_mutex_unlock(&m.mu);
    return 1;
}

const char *ocv_dpi_model_channel(int ch)
{
    return m.dut && ch >= 0 && ch < m.dut->n_channels ? m.dut->channels[ch].name : "?";
}

const char *ocv_dpi_model_field(int ch, int field)
{
    if (!m.dut || ch < 0 || ch >= m.dut->n_channels) return "?";
    const ocv_channel_t *c = &m.dut->channels[ch];
    return field >= 0 && field < c->n_fields ? c->fields[field].name : "?";
}

/* the stimulus is complete: once the model has taken all of it, it is done (the source driver's sequence ended -
 * the testbench says so, e.g. after the item with `last`) */
void ocv_dpi_model_in_done(void)
{
    pthread_mutex_lock(&m.mu);
    m.in_last = 1;
    pthread_cond_broadcast(&m.cv);
    pthread_mutex_unlock(&m.mu);
}

/* the DUT's output records so far (the checker tells quiet from it); the DUT makes no more: the model goes on to the
 * end of the stimulus without waiting for it */
long long ocv_dpi_model_records(void)
{
    pthread_mutex_lock(&m.mu);
    const long long n = m.started ? (long long)m.total : -1;
    pthread_mutex_unlock(&m.mu);
    return n;
}

void ocv_dpi_model_quiet(void)
{
    pthread_mutex_lock(&m.mu);
    m.quiet = 1;
    pthread_cond_broadcast(&m.cv);
    pthread_mutex_unlock(&m.mu);
}

/* the test is over: the threads let go (a model still waiting for records the DUT never made) */
void ocv_dpi_model_close(void)
{
    pthread_mutex_lock(&m.mu);
    m.stop = 1;
    pthread_cond_broadcast(&m.cv);
    pthread_mutex_unlock(&m.mu);
}

/* a record as "field=value ..." (reports) */
const char *ocv_dpi_model_format(int ch, const uint32_t *rec)
{
    static char buf[1024];
    if (!m.dut || ch < 0 || ch >= m.dut->n_channels) return "?";
    ocv_rec_format(&m.dut->channels[ch], rec, buf, sizeof buf);
    return buf;
}
