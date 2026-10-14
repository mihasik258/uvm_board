/* mac16_model.c - reference model of the mac16 demo IP for the OCV runner.
 *
 * Knows only the arithmetic of the IP; record layout comes from the generated metadata and
 * fields are found by name - once, not for every record (a lookup is a search by name).
 */
#include "ocv.h"
#include "ocv_model.h"
#include "mac16_ocv_meta.h"

enum { CH_OPERANDS = 0, CH_RESULTS = 1, CH_PRODUCTS = 2 };

const ocv_dut_t *const ocv_model_dut = &mac16_dut;

static int64_t acc;
static const ocv_field_t *f_a, *f_b, *f_clr, *f_acc, *f_prod;

static void find_fields(void)
{
    if (f_a) return;
    f_a    = ocv_field(&mac16_dut.channels[CH_OPERANDS], "a");
    f_b    = ocv_field(&mac16_dut.channels[CH_OPERANDS], "b");
    f_clr  = ocv_field(&mac16_dut.channels[CH_OPERANDS], "clr");
    f_acc  = ocv_field(&mac16_dut.channels[CH_RESULTS], "acc");
    f_prod = ocv_field(&mac16_dut.channels[CH_PRODUCTS], "prod");
}

static int64_t wrap40(int64_t v)
{
    uint64_t u = (uint64_t)v & ((1ull << 40) - 1);
    if (u >> 39) u |= ~((1ull << 40) - 1);
    return (int64_t)u;
}

static void reset(void) { acc = 0; find_fields(); }

/* Biased operands: extremes often, a clear rarely, so the 40-bit accumulator wraps. */
static int stimulus(int ch, uint64_t index, uint32_t *rec, uint64_t *rng)
{
    (void)ch;
    find_fields();
    uint64_t r = ocv_rand(rng);
    static const int16_t edge[] = { -32768, 32767, -1, 0, 1 };
    int16_t a = (int16_t)r, b = (int16_t)(r >> 16);
    if (((r >> 32) & 7) == 0) a = edge[(r >> 35) % 5];
    if (((r >> 38) & 7) == 0) b = edge[(r >> 41) % 5];
    ocv_set_raw(rec, f_a, (uint16_t)a);
    ocv_set_raw(rec, f_b, (uint16_t)b);
    ocv_set_raw(rec, f_clr, index == 0 || ((r >> 48) & 2047) == 0);
    return 1;                                       /* endless: the run is bounded by --batches */
}

static void input(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    (void)ch;
    int64_t prod = ocv_get_int(rec, f_a) * ocv_get_int(rec, f_b);
    acc = wrap40((ocv_get_raw(rec, f_clr) ? 0 : acc) + prod);

    uint32_t out[2] = { 0, 0 };
    ocv_set_raw(out, f_acc, (uint64_t)acc);         /* ts is compared with rule "ignore" */
    io->emit(io, CH_RESULTS, out);

    uint32_t p[1] = { 0 };
    ocv_set_raw(p, f_prod, (uint64_t)prod);
    io->emit(io, CH_PRODUCTS, p);
}

const ocv_model_t ocv_model = { "mac16 reference", NULL, reset, stimulus, input, NULL };
