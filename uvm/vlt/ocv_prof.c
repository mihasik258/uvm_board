/* ocv_prof.c - a sampling profiler built into a program (for the board, where there is no perf):
 * OCV_PROF=<file> in the environment turns it on. Every OCV_PROF_US microseconds of CPU time
 * (default 1000) SIGPROF records the call stack; at exit the samples go to <file> as text, one
 * sample per line, return addresses in hex. tools/prof_report.py turns them into a report
 * with the symbols of the same binary (addr2line on the PC).
 * Without OCV_PROF it does nothing.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <ucontext.h>
#include <unwind.h>

#define DEPTH   24
#define SAMPLES (1u << 17)

static uintptr_t *buf;          /* SAMPLES x DEPTH, 0 ends a stack */
static volatile uint32_t n_samples, n_lost;
static const char *out;

struct walk { uintptr_t *pc; int n; };
#undef DEPTH
#define DEPTH 24

static _Unwind_Reason_Code step(struct _Unwind_Context *ctx, void *arg)
{
    struct walk *w = (struct walk *)arg;
    if (w->n >= DEPTH + 4) return _URC_END_OF_STACK;
    w->pc[w->n++] = (uintptr_t)_Unwind_GetIP(ctx);
    return _URC_NO_REASON;
}

/* frame 0: the interrupted pc (from the signal context, always right); then the frames the
 * unwinder finds above the handler, after the signal frame (best effort) */
static void on_prof(int sig, siginfo_t *si, void *ucp)
{
    (void)sig; (void)si;
    uint32_t i = n_samples;
    if (i >= SAMPLES) { n_lost++; return; }
    n_samples = i + 1;
    uintptr_t *s = buf + (size_t)i * DEPTH;
    const ucontext_t *uc = (const ucontext_t *)ucp;
#if defined(__aarch64__)
    uintptr_t pc = (uintptr_t)uc->uc_mcontext.pc;
#elif defined(__x86_64__)
    uintptr_t pc = (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
#else
    uintptr_t pc = 0;
#endif
    uintptr_t tmp[DEPTH + 4];
    struct walk w = { tmp, 0 };
    _Unwind_Backtrace(step, &w);
    int k = 0, j = 0;
    s[k++] = pc;
    for (j = 0; j < w.n && tmp[j] != pc && tmp[j] != pc + 1; j++) ;   /* skip handler + signal frame */
    if (j < w.n) j++;                                                   /* the interrupted frame itself */
    for (; j < w.n && k < DEPTH; j++) s[k++] = tmp[j];
    if (k < DEPTH) s[k] = 0;
}

static void dump(void);
static void dump(void)
{
    struct itimerval off = { { 0, 0 }, { 0, 0 } };
    setitimer(ITIMER_PROF, &off, NULL);
    FILE *f = fopen(out, "w");
    if (!f) { perror(out); return; }
    fprintf(f, "# ocv_prof samples=%u lost=%u period_us=%s ref_dump=%lx\n", n_samples, n_lost,
            getenv("OCV_PROF_US") ? getenv("OCV_PROF_US") : "1000",
            (unsigned long)(uintptr_t)&dump);          /* where this function is: the load offset */
    for (uint32_t i = 0; i < n_samples; i++) {
        const uintptr_t *s = buf + (size_t)i * DEPTH;
        for (int d = 0; d < DEPTH && s[d]; d++)
            fprintf(f, "%s%lx", d ? " " : "", (unsigned long)s[d]);
        fputc('\n', f);
    }
    fclose(f);
    fprintf(stderr, "ocv_prof: %u samples -> %s\n", n_samples, out);
}

__attribute__((constructor)) static void ocv_prof_start(void)
{
    out = getenv("OCV_PROF");
    if (!out || !*out) return;
    buf = (uintptr_t *)calloc((size_t)SAMPLES * DEPTH, sizeof *buf);
    if (!buf) return;
    long us = getenv("OCV_PROF_US") ? atol(getenv("OCV_PROF_US")) : 1000;
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_prof;
    sa.sa_flags = SA_RESTART | SA_SIGINFO;
    sigaction(SIGPROF, &sa, NULL);
    atexit(dump);
    struct itimerval t = { { 0, us }, { 0, us } };
    setitimer(ITIMER_PROF, &t, NULL);
}
