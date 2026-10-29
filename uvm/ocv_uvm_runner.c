/* ocv_uvm_runner.c - the board side of ocv_model_checker (uvm/ocv_uvm_pkg.sv): a UVM testbench written by the
 * contract, with the whole DUT checked against an OCV model (a processor core's: models/cpu/ocv_cpu_model.c), runs
 * on the board at the runner's pace - the runner (sw/lib/ocv_runner.c: the model, squash windows, DMA rings, the
 * replay to the exact record) owns the hub, and the testbench's agents take part where it has something to say:
 *   - the stimulus (a processor core: the program's words) is what the testbench's source drivers send - the
 *     runner takes it instead of the model's stimulus() (ocv_runner_stimulus_hook);
 *   - the core's device accesses go to the testbench: the record reaches its dev_req monitor, and a read's answer
 *     is what its dev_resp driver sends (ocv_cpu_dev_hook);
 *   - every other output record is checked in C as it leaves the FPGA, none becomes a UVM object; the verdict and
 *     the mismatch come to the checker;
 *   - a channel with coverage subscribers in the testbench (ocv_uvm_pkg.sv, rule 7) is tapped: the model's records of
 *     it, thinned to those that can change the coverage (uvm/ocv_uvm_tap.h), reach its monitor.
 * The runner works in a thread of its own, but the two never run at once: control passes like a token (as in
 * uvm/cpu/ocv_uvm_cpu.c) - the testbench's wait for progress hands it to the runner, which hands it back when it
 * needs the testbench: more stimulus, a device access, or the end.
 *
 * DPI (the base classes, in a board build with an ocv_model_checker):
 *   int  ocv_dpi_model_board_open(string runner_args)   start: the runner's options ("--squash 4096 --model-opt ...")
 *   void ocv_dpi_model_send(int ch, rec)   a source driver's record: stimulus, or the answer to a device read
 *   int  ocv_dpi_model_tap(int ch, string spec)   before the start: tap channel ch ("<field>,... <history>" or "all")
 *   int  ocv_dpi_model_recv(int ch, rec)   a record for a monitor (the core's device access, a tapped channel's
 *                                          record): 1 if there is one, 2 if it is a context record (ocv_uvm_tap.h)
 *   void ocv_dpi_model_wait()              the testbench has nothing to do: the runner goes on
 *   int  ocv_dpi_model_board_done(output int rc)   1 when the run is over (rc: the runner's exit status)
 */
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_model.h"
#include "ocv_uvm_tap.h"

#define REC_WORDS 32
#define MAX_CH    64

int ocv_runner_main(int argc, char **argv, ocv_bus_t *bus);
int ocv_uvm_bus_open(ocv_bus_t *bus, uint64_t base, char *err, size_t errlen);
extern int (*ocv_runner_stimulus_hook)(int ch, uint64_t index, uint32_t *rec);
extern void (*ocv_runner_expect_hook)(int ch, const uint32_t *rec);
extern const unsigned char *ocv_runner_expect_tap;
extern uint32_t (*ocv_cpu_dev_hook)(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle)
    __attribute__((weak));

typedef struct { uint32_t w[REC_WORDS]; } rec_t;
typedef struct { rec_t *v; size_t head, n, cap; } fifo_t;

static pthread_t       th;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static int             turn;                 /* 0: the testbench runs, 1: the runner runs */
static int             done, result, started;
static fifo_t          stim[MAX_CH];         /* the source drivers' records, per channel */
static fifo_t          to_tb;                /* the core's device accesses, for the dev_req monitor */
static int             req_ch = -1, resp_ch = -1;
static int             answered;
static uint32_t        answer;
static ocv_bus_t       bus;
/* the tapped channels: their selection, and the records for their monitors (ctx: a context record) */
typedef struct { uint32_t w[REC_WORDS]; int ctx; } trec_t;
typedef struct { trec_t *v; size_t head, n, cap; } tapq_t;
static ocv_tap_t       tap[MAX_CH];
static tapq_t          tap_q[MAX_CH];
static unsigned char   tapped[MAX_CH];
static int             tap_told;
static int             argc_;
static char           *argv_[128], *argbuf;

static void push(fifo_t *f, const uint32_t *rec, int words)
{
    if (f->n == f->cap) {
        size_t cap = f->cap ? 2 * f->cap : 1024;
        rec_t *v = malloc(cap * sizeof *v);
        if (!v) { perror("ocv_uvm_runner"); exit(1); }
        for (size_t i = 0; i < f->n; i++) v[i] = f->v[(f->head + i) % f->cap];
        free(f->v);
        f->v = v; f->cap = cap; f->head = 0;
    }
    rec_t *r = &f->v[(f->head + f->n) % f->cap];
    memset(r, 0, sizeof *r);
    memcpy(r->w, rec, (size_t)words * 4);
    f->n++;
}

static int pop(fifo_t *f, uint32_t *rec, int words)
{
    if (!f->n) return 0;
    memcpy(rec, f->v[f->head].w, (size_t)words * 4);
    f->head = (f->head + 1) % f->cap;
    f->n--;
    return 1;
}

static void pass_to(int who)                  /* (under mu) hand the token over and wait for it back */
{
    turn = who;
    pthread_cond_broadcast(&cv);
    while (turn == who) pthread_cond_wait(&cv, &mu);
}

/* the runner wants the next stimulus record of source ch: what the testbench sent; when there is none, the
 * testbench gets the token once more - still none then: the stimulus is complete (for this batch) */
static int stim_hook(int ch, uint64_t index, uint32_t *rec)
{
    (void)index;
    const ocv_channel_t *c = &ocv_model_dut->channels[ch];
    pthread_mutex_lock(&mu);
    int got = pop(&stim[ch], rec, c->rec_words);
    if (!got) {
        pass_to(0);
        got = pop(&stim[ch], rec, c->rec_words);
    }
    pthread_mutex_unlock(&mu);
    if (getenv("OCV_UVM_MODEL_DEBUG") && (index < 3 || !got))
        fprintf(stderr, "ocv_uvm_runner: stimulus %s[%llu] %s %08x %08x\n", c->name, (unsigned long long)index,
                got ? "" : "none", got ? rec[0] : 0, got ? rec[1] : 0);
    return got;
}

/* a device access of the core: to the testbench's dev_req monitor; a read waits for its dev_resp driver */
static uint32_t dev_hook(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle)
{
    const ocv_channel_t *c = &ocv_model_dut->channels[req_ch];
    uint32_t r[REC_WORDS] = { 0 };
    ocv_set(c, r, "dev", (uint64_t)dev);
    ocv_set(c, r, "addr", addr);
    ocv_set(c, r, "we", (uint64_t)we);
    ocv_set(c, r, "be", be);
    ocv_set(c, r, "wdata", wdata);
    ocv_set(c, r, "cycle", cycle);
    pthread_mutex_lock(&mu);
    push(&to_tb, r, c->rec_words);
    answered = 0;
    do pass_to(0); while (!we && !answered && !done);
    const uint32_t v = answer;
    pthread_mutex_unlock(&mu);
    return v;
}

/* (the runner's thread) a tapped channel's record that the selection keeps: to its monitor */
static void tap_send(void *arg, const uint32_t *rec, int context)
{
    const int ch = *(const int *)arg;
    tapq_t *f = &tap_q[ch];
    pthread_mutex_lock(&mu);
    if (f->n == f->cap) {
        const size_t cap = f->cap ? 2 * f->cap : 1024;
        trec_t *v = malloc(cap * sizeof *v);
        if (!v) { perror("ocv_uvm_runner"); exit(1); }
        for (size_t i = 0; i < f->n; i++) v[i] = f->v[(f->head + i) % f->cap];
        free(f->v);
        f->v = v; f->cap = cap; f->head = 0;
    }
    trec_t *r = &f->v[(f->head + f->n) % f->cap];
    memset(r, 0, sizeof *r);
    memcpy(r->w, rec, (size_t)ocv_model_dut->channels[ch].rec_words * 4);
    r->ctx = context;
    f->n++;
    pthread_mutex_unlock(&mu);
}
static void tap_hook(int ch, const uint32_t *rec)
{
    ocv_tap_record(&tap[ch], rec, tap_send, &ch);
}

int ocv_dpi_model_tap(int ch, const char *spec)
{
    if (started || !ocv_model_dut || ch < 0 || ch >= ocv_model_dut->n_channels || ch >= MAX_CH) return 0;
    const ocv_channel_t *c = &ocv_model_dut->channels[ch];
    if (c->kind == OCV_CH_SOURCE || !strcmp(c->name, "dev_req")) return 0;   /* (given to the testbench anyway) */
    ocv_tap_t *t = &tap[ch];
    memset(t->mask, 0, sizeof t->mask);
    t->words = c->rec_words; t->all = 0; t->hist = 0;
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", spec ? spec : "");
    char *fl = strtok(buf, " \t"), *hs = strtok(NULL, " \t");
    if (!fl || !strcmp(fl, "all")) t->all = 1;
    else {
        t->hist = hs ? atoi(hs) : 0;
        if (t->hist < 0 || t->hist > OCV_TAP_HIST) {
            fprintf(stderr, "ocv_uvm_runner: channel '%s': coverage history %d (at most %d): every record\n", c->name,
                    t->hist, OCV_TAP_HIST);
            t->all = 1; t->hist = 0;
        }
        /* "<field>" (all of it) or "<field>[hi:lo]" (those bits of it) */
        for (char *f = strtok(fl, ","); f && !t->all; f = strtok(NULL, ",")) {
            char *br = strchr(f, '[');
            unsigned hi = 0, lo = 0;
            const int part = br != NULL;
            if (part) {
                *br = 0;
                if (sscanf(br + 1, "%u:%u", &hi, &lo) != 2) lo = hi;
            }
            const ocv_field_t *F = ocv_field(c, f);
            if (!F || (part && (hi < lo || hi >= F->width))) {
                fprintf(stderr, "ocv_uvm_runner: channel '%s' has no field '%s' (coverage): every record\n", c->name, f);
                t->all = 1;
                break;
            }
            const uint32_t b0 = F->lsb + (part ? lo : 0), b1 = F->lsb + (part ? hi + 1 : F->width);
            for (uint32_t b = b0; b < b1; b++) t->mask[b / 32] |= 1u << (b % 32);
        }
    }
    t->on = 1;
    tapped[ch] = 1;
    ocv_runner_expect_tap = tapped;
    ocv_runner_expect_hook = tap_hook;
    return 1;
}

static void *runner(void *arg)
{
    (void)arg;
    pthread_mutex_lock(&mu);
    while (turn != 1) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    const int rc = ocv_runner_main(argc_, argv_, &bus);
    fflush(stdout);
    pthread_mutex_lock(&mu);
    result = rc;
    done = 1;
    turn = 0;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    return NULL;
}

int ocv_dpi_model_board_open(const char *args)
{
    if (started) return 1;
    char err[256];
    const char *b = getenv("OCV_BASE");
    if (ocv_uvm_bus_open(&bus, b ? strtoull(b, NULL, 0) : 0, err, sizeof err)) {
        fprintf(stderr, "ocv_uvm_runner: %s\n", err);
        return 0;
    }
    for (int ch = 0; ch < ocv_model_dut->n_channels; ch++) {
        if (!strcmp(ocv_model_dut->channels[ch].name, "dev_req")) req_ch = ch;
        if (!strcmp(ocv_model_dut->channels[ch].name, "dev_resp")) resp_ch = ch;
    }
    argbuf = strdup(args ? args : "");
    argv_[argc_++] = (char *)"ocv_uvm_runner";
    for (char *t = strtok(argbuf, " \t"); t && argc_ < 127; t = strtok(NULL, " \t")) argv_[argc_++] = t;
    /* a batch takes all the stimulus the testbench sends (the runner caps each source at its depth): not the
     * runner's default, the smallest source's depth */
    int has_batch = 0, has_batches = 0;
    for (int i = 1; i < argc_; i++) {
        if (!strcmp(argv_[i], "--batch")) has_batch = 1;
        if (!strcmp(argv_[i], "--batches")) has_batches = 1;
    }
    if (!has_batch && argc_ < 125) { argv_[argc_++] = (char *)"--batch"; argv_[argc_++] = (char *)"1048576"; }
    /* as many batches as the testbench sends stimulus for (a batch holds at most a source's depth): the run ends
     * at the first batch with none - the testbench's end, not the runner's default of one batch */
    if (!has_batches && argc_ < 125) { argv_[argc_++] = (char *)"--batches"; argv_[argc_++] = (char *)"1000000000000"; }
    argv_[argc_] = NULL;
    ocv_runner_stimulus_hook = stim_hook;
    if (&ocv_cpu_dev_hook && req_ch >= 0) ocv_cpu_dev_hook = dev_hook;
    if (pthread_create(&th, NULL, runner, NULL)) { fprintf(stderr, "ocv_uvm_runner: no thread\n"); return 0; }
    started = 1;
    return 1;
}

void ocv_dpi_model_send(int ch, const uint32_t *rec)
{
    if (!started || ch < 0 || ch >= ocv_model_dut->n_channels) return;
    pthread_mutex_lock(&mu);
    if (ch == resp_ch) {                       /* the answer to the device read the runner waits on */
        answer = (uint32_t)ocv_get(&ocv_model_dut->channels[ch], rec, "rdata");
        answered = 1;
    } else {
        push(&stim[ch], rec, ocv_model_dut->channels[ch].rec_words);
    }
    pthread_mutex_unlock(&mu);
}

int ocv_dpi_model_recv(int ch, uint32_t *rec)
{
    if (!started || ch < 0 || ch >= MAX_CH || (ch != req_ch && !tapped[ch])) return 0;
    memset(rec, 0, REC_WORDS * 4);
    pthread_mutex_lock(&mu);
    int got;
    if (ch == req_ch) got = pop(&to_tb, rec, ocv_model_dut->channels[ch].rec_words);
    else {
        tapq_t *f = &tap_q[ch];
        got = 0;
        if (f->n) {
            const trec_t *r = &f->v[f->head];
            memcpy(rec, r->w, (size_t)ocv_model_dut->channels[ch].rec_words * 4);
            got = r->ctx ? 2 : 1;
            f->head = (f->head + 1) % f->cap;
            f->n--;
        }
    }
    pthread_mutex_unlock(&mu);
    return got;
}

void ocv_dpi_model_wait(void)
{
    if (!started) return;
    pthread_mutex_lock(&mu);
    if (!done) pass_to(1);
    pthread_mutex_unlock(&mu);
    if (done) {
        static int joined;
        if (!joined++) pthread_join(th, NULL);
    }
}

int ocv_dpi_model_board_done(int *rc)
{
    pthread_mutex_lock(&mu);
    const int d = done;
    *rc = result;
    pthread_mutex_unlock(&mu);
    if (d && !tap_told++)
        for (int ch = 0; ch < MAX_CH && ocv_model_dut && ch < ocv_model_dut->n_channels; ch++)
            if (tapped[ch])
                printf("ocv_uvm_runner: coverage of '%s' (%s): %llu records, %llu to the testbench + %llu context\n",
                       ocv_model_dut->channels[ch].name, tap[ch].all ? "every record" : "new projections",
                       (unsigned long long)tap[ch].n, (unsigned long long)tap[ch].passed,
                       (unsigned long long)tap[ch].context);
    return d;
}
