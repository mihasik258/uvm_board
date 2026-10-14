/* bench_model.c - the reference model path alone (no DUT): generated programs through the model as the runner
 * drives it - stimulus, input(), and every expected record emitted and folded into its squash window as the
 * runner does (ocv_squash_add) - to measure and improve the model side, which is most of a run on the board.
 *
 *   bench_model [--batches N] [--model-opt key=value ...]      (hw/cpu/run.sh <core.bind> bench [...])
 *
 * The DUT's records are not there: observed() finds none (no interrupts taken, device reads answer 0), so the
 * programs run as on a core that raises no interrupt. Prints instructions, seconds, ns per instruction. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ocv.h"
#include "ocv_model.h"

static uint64_t n_rec[256], n_win[256];
static uint32_t sq_c[256], sq_z[256], sq_n[256], window = 4096, ones[64];
static uint32_t last[256][64];
static uint64_t sig;                          /* every closed window's two CRCs: the same for two models that agree */
static int crc_off;                           /* --crc-off: the PC has no CRC32 instruction (the A72 has) */

static void emit(ocv_model_io_t *io, int ch, const uint32_t *rec)
{
    (void)io;
    const ocv_channel_t *c = &ocv_model_dut->channels[ch];
    n_rec[ch]++;
    if (c->squash) {                          /* as the runner's emit(): fold, keep the last, close the window */
        if (sq_n[ch] == 0) sq_c[ch] = sq_z[ch] = 0xFFFFFFFFu;
        if (!crc_off) ocv_squash_add(&sq_c[ch], &sq_z[ch], rec, ones, c->rec_words);
        for (uint32_t j = 0; j < c->rec_words; j++) last[ch][j] = rec[j];
        if (++sq_n[ch] >= window) { sq_n[ch] = 0; n_win[ch]++; sig = sig * 1000003u + ((uint64_t)sq_c[ch] << 32 | sq_z[ch]); }
    }
}
static void emit_n(ocv_model_io_t *io, int ch, const uint32_t *recs, uint32_t n, uint32_t stride)
{   /* as the runner's emit_n(): the window state in locals */
    const ocv_channel_t *c = &ocv_model_dut->channels[ch];
    if (!c->squash) { for (uint32_t i = 0; i < n; i++) emit(io, ch, recs + (size_t)i * stride); return; }
    uint32_t a = sq_c[ch], z = sq_z[ch], k = sq_n[ch];
    const uint32_t W = c->rec_words;
    n_rec[ch] += n;
    for (uint32_t i = 0; i < n; i++) {
        const uint32_t *rec = recs + (size_t)i * stride;
        if (k == 0) a = z = 0xFFFFFFFFu;
        if (!crc_off) ocv_squash_add(&a, &z, rec, ones, W);
        if (++k >= window) { for (uint32_t j = 0; j < W; j++) last[ch][j] = rec[j]; k = 0; n_win[ch]++;
                             sig = sig * 1000003u + ((uint64_t)a << 32 | z); }
    }
    sq_c[ch] = a; sq_z[ch] = z; sq_n[ch] = k;
}
static int observed(ocv_model_io_t *io, int ch, uint32_t index, uint32_t *rec) { (void)io; (void)ch; (void)index; (void)rec; return 0; }
static void send(ocv_model_io_t *io, int ch, const uint32_t *rec) { (void)io; (void)ch; (void)rec; }

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    int batches = 8;
    for (int i = 0; i < 64; i++) ones[i] = ~0u;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--batches") && i + 1 < argc) batches = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--window") && i + 1 < argc) window = (uint32_t)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--crc-off")) crc_off = 1;
        else if (!strcmp(argv[i], "--model-opt") && i + 1 < argc) {
            char kv[256];
            snprintf(kv, sizeof kv, "%s", argv[++i]);
            char *eq = strchr(kv, '=');
            if (!eq || !ocv_model.configure || ocv_model.configure(kv, (*eq = 0, eq + 1))) {
                fprintf(stderr, "bench_model: bad --model-opt %s\n", argv[i]);
                return 1;
            }
        } else { fprintf(stderr, "usage: %s [--batches N] [--window W] [--model-opt k=v ...]\n", argv[0]); return 1; }
    }
    const ocv_dut_t *d = ocv_model_dut;
    ocv_model_io_t io = { emit, observed, NULL, send, 0, emit_n };
    uint64_t rng = 1, idx[256] = { 0 };
    double t_stim = 0, t_model = 0;
    uint32_t rec[64];
    const ocv_field_t *last_f = ocv_field(&d->channels[0], "last");   /* (once: not part of what is measured) */
    const uint32_t words = d->channels[0].rec_words;
    for (int b = 0; b < batches; b++) {
        io.batch = (uint64_t)b;
        if (ocv_model.reset) ocv_model.reset();
        /* the program source (channel 0) to its last word, as the runner sends it; then the model runs */
        for (;;) {
            double t0 = now_s();
            memset(rec, 0, words * 4u);
            int got = ocv_model.stimulus ? ocv_model.stimulus(0, idx[0]++, rec, &rng) : 0;
            double t1 = now_s();
            t_stim += t1 - t0;
            if (!got) break;
            ocv_model.input(0, rec, &io);
            t_model += now_s() - t1;
            if (ocv_get_raw(rec, last_f)) break;
        }
    }
    uint64_t instr = 0, recs = 0;
    for (int ch = 0; ch < d->n_channels; ch++) recs += n_rec[ch];
    for (int ch = 0; ch < d->n_channels; ch++)
        if (!strcmp(d->channels[ch].name, "issue") || !strcmp(d->channels[ch].name, "retire")) instr = n_rec[ch];
    printf("bench_model: %s, %d program(s): %llu instructions, %llu records; model %.3f s = %.0f ns per instruction"
           " (generator %.3f s), signature %016llx\n", d->name, batches, (unsigned long long)instr, (unsigned long long)recs, t_model,
           instr ? t_model / (double)instr * 1e9 : 0.0, t_stim,
           (unsigned long long)sig);
    return 0;
}
