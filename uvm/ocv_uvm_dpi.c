/* ocv_uvm_dpi.c - the DPI side of OCV's UVM agents: a UVM testbench (on the PS of the board, compiled
 * by Verilator; or in any simulator on a PC) exchanges transactions with the DUT in the FPGA.
 *
 * Every source channel is a stream (ring buffer fed during the run), every output channel is
 * drained during the run without loss (lossless monitor / sink with backpressure: the DUT waits
 * while its buffer is full) - the generator's --uvm option builds the hub that way.
 *
 *   ocv_dpi_open("0x...")    map the hub (+OCV_BASE, any 64-bit address), check it is this DUT, reset, enable channels, release
 *   ocv_dpi_send(ch, rec)     queue one record on a source: 1 = taken, 0 = ring full (poll, retry)
 *   ocv_dpi_service(&moved)   publish written records, collect new output records; returns the DUT's
 *                             clock count (the testbench's time follows it); moved = records went
 *                             either way
 *   ocv_dpi_recv(ch, rec)     next collected output record: 1 = got one, 0 = none yet
 *   ocv_dpi_close()           unmap; returns the statistics line
 *   ocv_dpi_first_error()     the testbench reported its first error: print the line that records
 *                             the waveform around it on a PC (+OCV_WAVE=<channel>:<record>)
 *
 * Records cross DPI as `bit [OCV_UVM_REC_BITS-1:0]` (32-bit words, word 0 = bits 31:0).
 * The DUT's metadata comes from the generated <dut>_ocv_meta.h: build with
 *   -include <dut>_ocv_meta.h -DOCV_UVM_DUT=<dut>_dut
 * The bus comes from ocv_uvm_bus_open(): /dev/mem on the board (ocv_uvm_bus_mmap.c), a Verilator
 * model of the FPGA image on a PC (ocv_uvm_bus_vlt.cpp).
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ocv.h"
#include "ocv_regs.h"

#ifndef OCV_UVM_DUT
#error "build with -include <dut>_ocv_meta.h -DOCV_UVM_DUT=<dut>_dut"
#endif

#define OCV_UVM_REC_WORDS 32                    /* = OCV_UVM_REC_BITS / 32 in ocv_uvm_pkg.sv */

int ocv_uvm_bus_open(ocv_bus_t *bus, uint64_t base, char *err, size_t errlen);
/* the in-process constraint solver of the Verilator build (uvm/vlt/ocv_fast_random.cpp), if linked */
void ocv_fast_random_stats(uint64_t *fast, uint64_t *fallback) __attribute__((weak));
/* reference checkers in C (ocv_uvm_check.c): a checked channel's records never become UVM objects */
int  ocv_check_active(int ch);
int  ocv_check_squash_ok(int ch);
void ocv_check_set_deliver(void (*fn)(int, const uint32_t *, uint32_t));
const uint32_t *ocv_check_mask(int ch);
int  ocv_check_breaks(int ch, uint32_t mask[][32], uint32_t value[][32]);
void ocv_check_set_squashed(int ch, int on);
void ocv_check_record(int ch, const uint32_t *rec);
void ocv_check_set_window(uint32_t n);
void ocv_uvm_bus_close(ocv_bus_t *bus);

typedef struct {
    uint32_t *w;                                 /* collected output records (FIFO) */
    uint32_t  head, n, cap;
} fifo_t;

static struct {
    int        open;
    ocv_bus_t  bus;
    ocv_env_t  env;
    uint32_t  *sent;                             /* source: records written to the ring */
    uint32_t  *taken;                            /* source: COUNT last read (records the DUT took) */
    uint8_t   *dirty;                            /* source: LENGTH not yet published */
    uint32_t  *seen;                             /* output: records read from the buffer */
    uint64_t  *fused_n, *taken_last, *taken_cyc; /* squash: records covered by fused records; TAKEN seen, and
                                                 * the DUT cycle it last changed at */
    uint32_t   window;
    fifo_t    *q;
    uint64_t  *recs, polls, waits;
    uint64_t  *got;                              /* output: records given to UVM (ocv_dpi_recv) */
    double     t0;
    /* wall-clock stages: program start, hub open, first / last output record */
    double     t_prog, t_first, t_last;
} g;

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

__attribute__((constructor)) static void ocv_uvm_prog_start(void) { g.t_prog = now_s(); }

static void deliver(int ch, const uint32_t *recs, uint32_t n);
static void fatal(const char *msg)
{
    fprintf(stderr, "ocv_uvm: %s\n", msg);
    exit(2);
}

static const ocv_channel_t *chan(int ch, int want_source)
{
    if (!g.open) fatal("not open (no OCV agent ran ocv_dpi_open)");
    if (ch < 0 || ch >= g.env.dut->n_channels) fatal("channel number out of range");
    const ocv_channel_t *c = &g.env.dut->channels[ch];
    if (want_source != (c->kind == OCV_CH_SOURCE))
        fatal(want_source ? "send on an output channel" : "receive on a source channel");
    return c;
}

int ocv_dpi_open(const char *base_str)
{
    if (g.open) return 1;
    uint64_t base = base_str && *base_str ? strtoull(base_str, NULL, 0) : 0;
    const ocv_dut_t *dut = &OCV_UVM_DUT;
    char err[256];
    if (ocv_uvm_bus_open(&g.bus, base, err, sizeof err)) { fprintf(stderr, "ocv_uvm: %s\n", err); return 0; }
    if (ocv_env_open(&g.env, &g.bus, dut, err, sizeof err)) { fprintf(stderr, "ocv_uvm: %s\n", err); return 0; }
    int n = dut->n_channels;
    for (int ch = 0; ch < n; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        if (c->rec_words > OCV_UVM_REC_WORDS) {
            fprintf(stderr, "ocv_uvm: channel '%s': %u-word records, the UVM layer carries up to %u\n",
                    c->name, c->rec_words, OCV_UVM_REC_WORDS);
            return 0;
        }
        int ok = c->kind == OCV_CH_SOURCE ? c->stream
                                          : c->lossless || (g.env.ep[ch].kind & OCV_KIND_BACKPRESSURE);
        if (!ok) {
            fprintf(stderr, "ocv_uvm: channel '%s' is not built for transactions (%s) - generate the hub "
                    "with ocv_gen.py --uvm\n", c->name, c->kind == OCV_CH_SOURCE ? "not a stream" : "may lose records");
            return 0;
        }
    }
    g.sent = calloc(n, sizeof *g.sent);
    g.taken = calloc(n, sizeof *g.taken);
    g.dirty = calloc(n, 1);
    g.seen = calloc(n, sizeof *g.seen);
    g.q = calloc(n, sizeof *g.q);
    g.recs = calloc(n, sizeof *g.recs);
    g.fused_n = calloc(n, sizeof *g.fused_n);
    g.taken_last = calloc(n, sizeof *g.taken_last);
    g.taken_cyc = calloc(n, sizeof *g.taken_cyc);
    g.got = calloc(n, sizeof *g.got);
    g.window = 1;
    if (!g.sent || !g.taken || !g.dirty || !g.seen || !g.q || !g.recs || !g.got) fatal("out of memory");

    /* the runner's order: DUT in reset, outputs live, stream sources live; released by
     * ocv_dpi_go() once the testbench is built (it decides the squash windows first) */
    ocv_dut_reset(&g.env, 1);
    for (int ch = 0; ch < n; ch++) {
        ocv_ep_wr(&g.env, ch, OCV_EP_REG_THROTTLE, 0);
        if (dut->channels[ch].kind != OCV_CH_SOURCE)
            ocv_ep_wr(&g.env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
    }
    for (int ch = 0; ch < n; ch++)
        if (dut->channels[ch].kind == OCV_CH_SOURCE) {
            ocv_ep_wr(&g.env, ch, OCV_EP_REG_LENGTH, 0);
            ocv_ep_wr(&g.env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
        }
    if (!getenv("OCV_NO_DMA")) ocv_ring_setup(&g.env, 0);   /* outputs into PS memory, if built so */
    g.open = 1;
    ocv_check_set_deliver(deliver);         /* checked records on to UVM subscribers (coverage) */
    g.t0 = now_s();
    return 1;
}

/* the testbench is built: set the squash windows (+OCV_SQUASH), let the DUT run */
int ocv_dpi_set_squash(int n);
int ocv_dpi_go(int squash)
{
    if (!g.open) return 0;
    if (!ocv_dpi_set_squash(squash)) return 0;
    ocv_dut_reset(&g.env, 0);
    return 1;
}

/* publish what was written: raise LENGTH of the sources that got records */
static void flush(void)
{
    for (int ch = 0; ch < g.env.dut->n_channels; ch++)
        if (g.dirty[ch]) { ocv_ep_wr(&g.env, ch, OCV_EP_REG_LENGTH, g.sent[ch]); g.dirty[ch] = 0; }
}

int ocv_dpi_send(int ch, const uint32_t *rec)
{
    const ocv_channel_t *c = chan(ch, 1);
    uint32_t k = g.sent[ch];
    if (k >= g.taken[ch] + c->depth) {               /* ring looks full: publish, look again */
        flush();
        g.taken[ch] = ocv_ep_rd(&g.env, ch, OCV_EP_REG_COUNT);
        if (k >= g.taken[ch] + c->depth) { g.waits++; return 0; }
    }
    ocv_rec_write(&g.env, ch, k % c->depth, rec);
    g.sent[ch] = k + 1;
    g.dirty[ch] = 1;
    g.recs[ch]++;
    return 1;
}

static void fifo_push(fifo_t *f, unsigned words, const uint32_t *src, uint32_t n)
{
    if (f->head && f->head == f->n) f->head = f->n = 0;        /* drained: rewind */
    if (f->n + n > f->cap) {
        if (f->head) {                                         /* compact before growing */
            memmove(f->w, f->w + (size_t)f->head * words, (size_t)(f->n - f->head) * words * 4u);
            f->n -= f->head;
            f->head = 0;
        }
        if (f->n + n > f->cap) {
            uint32_t cap = f->cap ? f->cap : 1024;
            while (f->n + n > cap) cap *= 2;
            uint32_t *w = realloc(f->w, (size_t)cap * words * 4u);
            if (!w) fatal("out of memory");
            f->w = w;
            f->cap = cap;
        }
    }
    memcpy(f->w + (size_t)f->n * words, src, (size_t)n * words * 4u);
    f->n += n;
}

static uint32_t sq_win[256];         /* squash window set on each channel's endpoint */
#define SQUASH_QUIET 4096u   /* DUT cycles without a record before an open window is emitted */

/* checked records handed on to UVM (ocv_check_set_deliver): queued as if they came from the hub */
static void deliver(int ch, const uint32_t *recs, uint32_t n)
{
    const ocv_channel_t *c = &g.env.dut->channels[ch];
    const uint32_t sw = ocv_store_words(c);
    static uint32_t *tmp;
    static size_t cap;
    if ((size_t)n * sw > cap) {
        cap = (size_t)n * sw;
        if (!(tmp = realloc(tmp, cap * 4u))) fatal("out of memory");
    }
    memset(tmp, 0, (size_t)n * sw * 4u);
    for (uint32_t i = 0; i < n; i++) memcpy(tmp + (size_t)i * sw, recs + (size_t)i * c->rec_words, c->rec_words * 4u);
    fifo_push(&g.q[ch], sw, tmp, n);
}

static int poll(void)
{
    int moved = 0;
    flush();
    g.polls++;
    for (int ch = 0; ch < g.env.dut->n_channels; ch++) {
        const ocv_channel_t *c = &g.env.dut->channels[ch];
        if (c->kind == OCV_CH_SOURCE) continue;
        const int ring = ocv_ring_on(&g.env, ch);     /* a DMA ring: records from PS memory */
        uint32_t n = ocv_ep_rd(&g.env, ch, OCV_EP_REG_COUNT);
        if (ring ? n != g.env.ep[ch].tail : n > g.seen[ch]) {
            uint32_t k = ring ? 1u << g.env.ep[ch].ring_log2 : n - g.seen[ch];
            static uint32_t *tmp;
            static size_t cap;
            const uint32_t sw = ocv_store_words(c);   /* a squashed channel stores 3 more words */
            if ((size_t)k * sw > cap) {
                cap = (size_t)k * sw;
                if (!(tmp = realloc(tmp, cap * 4u))) fatal("out of memory");
            }
            if (ring) k = ocv_ring_take(&g.env, ch, tmp, k);
            else      ocv_rec_read_block(&g.env, ch, g.seen[ch], k, tmp);
            if (c->squash)                       /* records covered so far: the count word */
                for (uint32_t i = 0; i < k; i++) g.fused_n[ch] += tmp[(size_t)i * sw + c->rec_words];
            if (ocv_check_active(ch))
                for (uint32_t i = 0; i < k; i++) ocv_check_record(ch, tmp + (size_t)i * sw);
            else
                fifo_push(&g.q[ch], sw, tmp, k);
            g.seen[ch] = n;
            g.recs[ch] += k;
            moved = 1;
            g.t_last = now_s();
            if (!g.t_first) g.t_first = g.t_last;
        }
        /* quiet with a window open: emit it. Quiet = no record for SQUASH_QUIET DUT cycles - not
         * merely none since the last poll, which a divide or a memory wait also gives */
        if (c->squash && sq_win[ch] > 1 && (ring || n < c->depth)) {
            uint32_t t = ocv_ep_rd(&g.env, ch, OCV_EP_REG_TAKEN);
            uint64_t cyc = ocv_cycles(&g.env);
            if (t != g.taken_last[ch]) { g.taken_last[ch] = t; g.taken_cyc[ch] = cyc; }
            else if ((uint32_t)g.fused_n[ch] != t && cyc - g.taken_cyc[ch] >= SQUASH_QUIET)
                ocv_squash_flush(&g.env, ch);
        }
        if (!ring && n == c->depth) {                /* full and read: restart, the DUT goes on */
            ocv_ep_wr(&g.env, ch, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);
            g.seen[ch] = 0;
        }
    }
    return moved;
}

/* +OCV_SQUASH=N: squashed channels checked by the engine fuse windows of N records; the others
 * (their records go to UVM monitors) stay at 1. Returns 0 if an endpoint did not take it. */
int ocv_dpi_set_squash(int n)
{
    if (!g.open) return 0;
    uint32_t w = n > 1 ? (uint32_t)n : 1;
    g.window = w;
    ocv_check_set_window(w);
    for (int ch = 0; ch < g.env.dut->n_channels; ch++) {
        const ocv_channel_t *c = &g.env.dut->channels[ch];
        if (c->kind == OCV_CH_SOURCE || !c->squash) continue;
        /* the signatures must cover what the checker compares: the endpoint's run-time mask set
         * to it, or (an older image) the build's mask equal to it */
        const uint32_t *m = ocv_check_active(ch) ? ocv_check_mask(ch) : NULL;
        int on = m && (ocv_squash_mask(&g.env, ch, m, c->rec_words) || ocv_check_squash_ok(ch));
        if (on) {                                /* records the model takes a DUT value from */
            static uint32_t bm[4][32], bv[4][32];
            memset(bm, 0, sizeof bm); memset(bv, 0, sizeof bv);
            int nb = ocv_check_breaks(ch, bm, bv);
            if (nb && !ocv_squash_breaks(&g.env, ch, nb, bm, bv, c->rec_words)) {
                fprintf(stderr, "ocv_uvm: channel '%s': the model takes DUT values but this FPGA image has no break "
                        "patterns - checked record by record in C (no squash)\n", c->name);
                on = 0;
            }
        }
        if (w > 1 && ocv_check_active(ch) && !on)
            fprintf(stderr, "ocv_uvm: channel '%s': %s - checked record by record in C (no squash)\n", c->name,
                    m ? "the scoreboard compares other bits than the FPGA signs" : "the scoreboard compares with a tolerance");
        uint32_t want = on ? w : 1;
        ocv_check_set_squashed(ch, on && w > 1);
        ocv_squash_window(&g.env, ch, want);
        if (ch < 256) sq_win[ch] = want;
        if (ocv_ep_rd(&g.env, ch, OCV_EP_REG_SQUASH) != want) {
            fprintf(stderr, "ocv_uvm: channel '%s' did not take squash window %u\n", c->name, want);
            return 0;
        }
    }
    return 1;
}

long long ocv_dpi_service(int *moved)
{
    *moved = 0;
    if (!g.open) return 0;
    uint32_t before[256];
    int n = g.env.dut->n_channels;
    for (int ch = 0; ch < n; ch++) before[ch] = g.taken[ch];
    *moved = poll();
    for (int ch = 0; ch < n; ch++)                      /* the DUT took records: ring space freed */
        if (g.env.dut->channels[ch].kind == OCV_CH_SOURCE && g.sent[ch] != g.taken[ch]) {
            g.taken[ch] = ocv_ep_rd(&g.env, ch, OCV_EP_REG_COUNT);
            if (g.taken[ch] != before[ch]) *moved = 1;
        }
    return (long long)ocv_cycles(&g.env);
}

int ocv_dpi_recv(int ch, uint32_t *rec)
{
    const ocv_channel_t *c = chan(ch, 0);
    fifo_t *f = &g.q[ch];
    if (f->head == f->n) return 0;
    memset(rec, 0, OCV_UVM_REC_WORDS * 4u);
    memcpy(rec, f->w + (size_t)f->head * ocv_store_words(c), c->rec_words * 4u);   /* the record itself */
    f->head++;
    g.got[ch]++;
    return 1;
}

/* records still in a source's ring that the DUT has not taken (the test waits for 0 to end) */
int ocv_dpi_pending(int ch)
{
    chan(ch, 1);
    flush();
    g.taken[ch] = ocv_ep_rd(&g.env, ch, OCV_EP_REG_COUNT);
    return (int)(g.sent[ch] - g.taken[ch]);
}


/* Where the first error is, for its waveform on a PC: the number of the record in its channel,
 * 1-based as scoreboards count. The C checker knows the very record (ocv_uvm_wave_hint); for a
 * scoreboard in SystemVerilog it is the last record each output channel gave to UVM (a scoreboard
 * checks a record when its monitor writes it). */
static struct { int set; uint64_t at[256]; uint8_t has[256]; } wv;

void ocv_uvm_wave_hint(int ch, uint64_t record)
{
    if (wv.set || ch < 0 || ch >= 256) return;
    wv.set = 1;
    wv.has[ch] = 1;
    wv.at[ch] = record;
}

void ocv_dpi_first_error(void)
{
    static int shown;
    if (shown || !g.open) return;
    shown = 1;
    if (!wv.set)
        for (int ch = 0; ch < g.env.dut->n_channels && ch < 256; ch++)
            if (g.env.dut->channels[ch].kind != OCV_CH_SOURCE && g.got[ch]) { wv.has[ch] = 1; wv.at[ch] = g.got[ch]; }
    /* the test's own arguments (not the board's +OCV_*), then the record */
    static char buf[16384], line[20000];
    int o = snprintf(line, sizeof line, "OCV: waveform on a PC (the same test in simulation, build_board.sh wave):");
    FILE *f = fopen("/proc/self/cmdline", "rb");
    size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0;
    if (f) fclose(f);
    for (size_t i = strlen(buf) + 1; i < n && o < (int)sizeof line; i += strlen(buf + i) + 1)
        if (strncmp(buf + i, "+OCV_", 5))
            o += snprintf(line + o, sizeof line - o, " %s", buf + i);
    const char *sep = " +OCV_WAVE=";
    int any = 0;
    for (int ch = 0; ch < g.env.dut->n_channels && ch < 256 && o < (int)sizeof line; ch++)
        if (wv.has[ch]) {
            o += snprintf(line + o, sizeof line - o, "%s%s:%llu", sep, g.env.dut->channels[ch].name,
                          (unsigned long long)wv.at[ch]);
            sep = ",";
            any = 1;
        }
    if (any) { printf("%s\n", line); fflush(stdout); }
}

/* close the hub; returns the statistics line (shown by the testbench as a UVM message) */
const char *ocv_dpi_close(void)
{
    static char line[1024];
    if (!g.open) return "";
    double t = now_s() - g.t0;
    int o = snprintf(line, sizeof line, "%s:", g.env.dut->name);
    for (int ch = 0; ch < g.env.dut->n_channels && o < (int)sizeof line; ch++)
        o += snprintf(line + o, sizeof line - o, " %s=%llu", g.env.dut->channels[ch].name, (unsigned long long)g.recs[ch]);
    if (o < (int)sizeof line)
        o += snprintf(line + o, sizeof line - o, " records; %llu DUT cycles; %.3f s with the hub open; %llu polls, %llu full-ring waits",
                      (unsigned long long)ocv_cycles(&g.env), t, (unsigned long long)g.polls, (unsigned long long)g.waits);
    /* where the time went: the stages of the run, wall clock */
    double tc = now_s(), tf = g.t_first ? g.t_first : tc, tl = g.t_last ? g.t_last : tc;
    if (o < (int)sizeof line)
        o += snprintf(line + o, sizeof line - o, "; time: startup %.3f s, until the first DUT output %.3f s, "
                      "first..last output %.3f s, after it %.3f s",
                      g.t0 - g.t_prog, tf - g.t0, tl - tf, tc - tl);
    if (ocv_fast_random_stats && o < (int)sizeof line) {
        uint64_t fast, slow;
        ocv_fast_random_stats(&fast, &slow);
        snprintf(line + o, sizeof line - o, "; randomize(): %llu in-process, %llu by the SMT solver",
                 (unsigned long long)fast, (unsigned long long)slow);
    }
    ocv_env_close(&g.env);
    ocv_uvm_bus_close(&g.bus);
    g.open = 0;
    return line;
}
