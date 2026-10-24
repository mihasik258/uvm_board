/* ocv_uvm_runner.c - the board side of ocv_model_checker (uvm/ocv_uvm_pkg.sv): a UVM testbench written by the
 * contract, with the whole DUT checked against an OCV model (a processor core's: models/cpu/ocv_cpu_model.c), runs
 * on the board at the runner's pace - the runner (sw/lib/ocv_runner.c: the model, squash windows, DMA rings, the
 * replay to the exact record) owns the hub, and the testbench's agents take part where it has something to say:
 *   - the stimulus (a processor core: the program's words) is what the testbench's source drivers send - the
 *     runner takes it instead of the model's stimulus() (ocv_runner_stimulus_hook);
 *   - the core's device accesses go to the testbench: the record reaches its dev_req monitor, and a read's answer
 *     is what its dev_resp driver sends (ocv_cpu_dev_hook);
 *   - every other output record is checked in C as it leaves the FPGA, none becomes a UVM object; the verdict and
 *     the mismatch come to the checker.
 * The runner works in a thread of its own, but the two never run at once: control passes like a token (as in
 * uvm/cpu/ocv_uvm_cpu.c) - the testbench's wait for progress hands it to the runner, which hands it back when it
 * needs the testbench: more stimulus, a device access, or the end.
 *
 * DPI (the base classes, in a board build with an ocv_model_checker):
 *   int  ocv_dpi_model_board_open(string runner_args)   start: the runner's options ("--squash 4096 --model-opt ...")
 *   void ocv_dpi_model_send(int ch, rec)   a source driver's record: stimulus, or the answer to a device read
 *   int  ocv_dpi_model_recv(int ch, rec)   a record for a monitor (the core's device access): 1 if there is one
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

#define REC_WORDS 32
#define MAX_CH    64

int ocv_runner_main(int argc, char **argv, ocv_bus_t *bus);
int ocv_uvm_bus_open(ocv_bus_t *bus, uint64_t base, char *err, size_t errlen);
extern int (*ocv_runner_stimulus_hook)(int ch, uint64_t index, uint32_t *rec);
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
    if (!started || ch != req_ch) return 0;
    memset(rec, 0, REC_WORDS * 4);
    pthread_mutex_lock(&mu);
    const int got = pop(&to_tb, rec, ocv_model_dut->channels[ch].rec_words);
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
    return d;
}
