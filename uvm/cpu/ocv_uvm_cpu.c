/* ocv_uvm_cpu.c - a processor core under OCV (gen/cpu_wrap.py) inside a UVM testbench that runs as it
 * is on the processor (Verilator): the core runs in the FPGA, every instruction is checked against the
 * reference model (models/cpu/ocv_cpu_model.c, the OCV runner: engine A), and the testbench takes part only
 * where it has something to say - the core's accesses to its device windows (the testbench's virtual
 * peripherals) go to the testbench's bus agent; between them the testbench's clock stands still.
 *
 * The runner works in a thread of its own, but the two never run at once: control passes like a token -
 * the testbench (its bridge module, the DUT's stand-in) calls ocv_uvm_cpu_next(), the runner runs the core
 * until it makes a device access, hands it over and waits; the bridge carries it out on the bus agent,
 * gives a read's data back (ocv_uvm_cpu_answer) and calls ocv_uvm_cpu_next() again. So the testbench's
 * simulation and the FPGA model on a PC (both Verilator) are never touched by two threads at a time.
 *
 * DPI (the bridge):
 *   int  ocv_uvm_cpu_start(string args)     the runner's options ("--model-opt program=x.hex --squash 4096
 *                                           ..."), the hub at OCV_BASE (or the platform's); 1 if started
 *   int  ocv_uvm_cpu_next(output int dev, addr, we, be, wdata, output longint cycle)
 *                                           1: a device access (the core's clock count); 0: the run is over
 *   void ocv_uvm_cpu_answer(int rdata)      the answer to the read just handed over
 *   int  ocv_uvm_cpu_result()               the runner's exit status (0: every record matched)
 */
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"

int ocv_runner_main(int argc, char **argv, ocv_bus_t *bus);
int ocv_uvm_bus_open(ocv_bus_t *bus, uint64_t base, char *err, size_t errlen);
/* the model's device hook (ocv_cpu_model.c): when set, its react() asks here instead of answering itself */
extern uint32_t (*ocv_cpu_dev_hook)(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle);

static pthread_t       th;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  cv = PTHREAD_COND_INITIALIZER;
static int             turn;                 /* 0: the testbench runs, 1: the runner runs */
static int             done, result, started;
static struct { int dev, we; uint32_t addr, be, wdata, answer; uint64_t cycle; int pending; } q;
static ocv_bus_t       bus;
static int             argc_;
static char           *argv_[64], *argbuf;

static void pass_to(int who)                  /* hand the token over and wait for it back */
{
    turn = who;
    pthread_cond_broadcast(&cv);
    while (turn == who) pthread_cond_wait(&cv, &mu);
}

static uint32_t hook(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle)
{
    pthread_mutex_lock(&mu);
    q.dev = dev; q.addr = addr; q.we = we; q.be = be; q.wdata = wdata; q.cycle = cycle; q.pending = 1;
    q.answer = 0;
    pass_to(0);                                /* the testbench carries it out */
    const uint32_t v = q.answer;
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

int ocv_uvm_cpu_start(const char *args)
{
    if (started) return 1;
    char err[256];
    const char *b = getenv("OCV_BASE");
    if (ocv_uvm_bus_open(&bus, b ? strtoull(b, NULL, 0) : 0, err, sizeof err)) {
        fprintf(stderr, "ocv_uvm_cpu: %s\n", err);
        return 0;
    }
    argbuf = strdup(args ? args : "");
    argv_[argc_++] = (char *)"ocv_uvm_cpu";
    for (char *t = strtok(argbuf, " \t"); t && argc_ < 63; t = strtok(NULL, " \t")) argv_[argc_++] = t;
    argv_[argc_] = NULL;
    ocv_cpu_dev_hook = hook;
    if (pthread_create(&th, NULL, runner, NULL)) { fprintf(stderr, "ocv_uvm_cpu: no thread\n"); return 0; }
    started = 1;
    return 1;
}

int ocv_uvm_cpu_next(int *dev, int *addr, int *we, int *be, int *wdata, long long *cycle)
{
    if (!started) return 0;
    pthread_mutex_lock(&mu);
    q.pending = 0;
    if (!done) pass_to(1);                     /* the runner goes on until the next device access */
    const int got = q.pending && !done;
    if (got) {
        *dev = q.dev; *addr = (int)q.addr; *we = q.we; *be = (int)q.be; *wdata = (int)q.wdata;
        *cycle = (long long)q.cycle;
    }
    pthread_mutex_unlock(&mu);
    if (!got) pthread_join(th, NULL), started = 0;
    return got;
}

void ocv_uvm_cpu_answer(int rdata) { q.answer = (uint32_t)rdata; }

int ocv_uvm_cpu_result(void) { return result; }
