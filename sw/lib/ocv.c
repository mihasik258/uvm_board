/* ocv.c - OCV software core. See ocv.h. Portable C99, no dependencies beyond libc. */
#include "ocv.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ environment */

static uint32_t hub_rd(ocv_env_t *env, uint32_t reg) { return env->bus->rd(env->bus, reg); }
static void hub_wr(ocv_env_t *env, uint32_t reg, uint32_t v) { env->bus->wr(env->bus, reg, v); }

static int fail(char *err, size_t n, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    if (err && n) vsnprintf(err, n, fmt, ap);
    va_end(ap);
    return -1;
}

int ocv_env_open(ocv_env_t *env, ocv_bus_t *bus, const ocv_dut_t *dut, char *err, size_t errlen)
{
    memset(env, 0, sizeof(*env));
    env->bus = bus;
    env->dut = dut;

    uint32_t id = hub_rd(env, OCV_HUB_REG_ID);
    if (id != OCV_HUB_ID_VALUE)
        return fail(err, errlen, "no OCV hub at this address (ID 0x%08x, expected 0x%08x)",
                    id, OCV_HUB_ID_VALUE);
    uint32_t dut_id = hub_rd(env, OCV_HUB_REG_DUT_ID);
    if (dut_id != dut->dut_id)
        return fail(err, errlen, "bitstream is for another DUT: hub DUT_ID 0x%08x, metadata '%s' is 0x%08x",
                    dut_id, dut->name, dut->dut_id);
    uint32_t layout = hub_rd(env, OCV_HUB_REG_LAYOUT);
    if (OCV_LAYOUT_ENDPOINTS(layout) != dut->n_channels)
        return fail(err, errlen, "hub has %u endpoints, metadata %u",
                    OCV_LAYOUT_ENDPOINTS(layout), dut->n_channels);
    env->slot_log2 = OCV_LAYOUT_SLOT_LOG2(layout);

    env->ep = calloc(dut->n_channels, sizeof(*env->ep));
    if (!env->ep) return fail(err, errlen, "out of memory");

    for (int ch = 0; ch < dut->n_channels; ch++) {
        const ocv_channel_t *c = &dut->channels[ch];
        ocv_ep_t *ep = &env->ep[ch];
        ep->base = (uint32_t)c->slot << env->slot_log2;
        uint32_t epid = ocv_ep_rd(env, ch, OCV_EP_REG_ID);
        if (epid != OCV_EP_ID_VALUE)
            return fail(err, errlen, "channel '%s': no endpoint in slot %u (ID 0x%08x)", c->name, c->slot, epid);
        ep->kind = ocv_ep_rd(env, ch, OCV_EP_REG_KIND);
        uint32_t want = (c->kind == OCV_CH_SOURCE) ? OCV_EP_KIND_SOURCE : OCV_EP_KIND_SINK;
        if (OCV_KIND_OF(ep->kind) != want)
            return fail(err, errlen, "channel '%s': endpoint kind %u, expected %u", c->name,
                        OCV_KIND_OF(ep->kind), want);
        if (c->kind == OCV_CH_SOURCE && (!!(ep->kind & OCV_KIND_STREAM) != !!c->stream
                                         || !!(ep->kind & OCV_KIND_FREEZE_STARVED) != !!c->freeze_starved))
            return fail(err, errlen, "channel '%s': stream/freeze_when_starved differ between hardware and metadata",
                        c->name);
        if (c->kind != OCV_CH_SOURCE && !!(ep->kind & OCV_KIND_SQUASH) != !!c->squash)
            return fail(err, errlen, "channel '%s': squash is %s in hardware but %s in the metadata", c->name,
                        (ep->kind & OCV_KIND_SQUASH) ? "on" : "off", c->squash ? "on" : "off");
        if (c->kind != OCV_CH_SOURCE && !!(ep->kind & OCV_KIND_LOSSLESS) != !!c->lossless)
            return fail(err, errlen, "channel '%s': lossless is %s in hardware but %s in the metadata", c->name,
                        (ep->kind & OCV_KIND_LOSSLESS) ? "on" : "off", c->lossless ? "on" : "off");
        uint32_t g = ocv_ep_rd(env, ch, OCV_EP_REG_GEOMETRY);
        if (OCV_GEOM_REC_WORDS(g) != ocv_store_words(c) || (1u << OCV_GEOM_LOG2_DEPTH(g)) != c->depth)
            return fail(err, errlen, "channel '%s': hardware has %u words x %u records, metadata %u x %u",
                        c->name, OCV_GEOM_REC_WORDS(g), 1u << OCV_GEOM_LOG2_DEPTH(g), ocv_store_words(c), c->depth);
        ep->buf_off = (uint32_t)OCV_GEOM_BUF_OFFSET(g);
        ep->stride_log2 = OCV_GEOM_LOG2_STRIDE(g);
        /* a ring left on by an earlier process (it keeps its registers until the FPGA is reset): off, else the
         * records go on into memory that process no longer owns and the buffer reads over the bus are the DMA's */
        if (c->kind != OCV_CH_SOURCE && (ep->kind & OCV_KIND_DMA)) ocv_ep_wr(env, ch, OCV_EP_REG_RING_LOG2, 0);
    }
    return 0;
}

/* the rings this environment turned on go off with it (a process that dies without closing leaves them on:
 * the next ocv_env_open turns them off) */
void ocv_env_close(ocv_env_t *env)
{
    if (env->ep)
        for (int ch = 0; ch < env->dut->n_channels; ch++)
            if (env->ep[ch].ring) { ocv_ep_wr(env, ch, OCV_EP_REG_RING_LOG2, 0); env->ep[ch].ring = NULL; }
    free(env->ep);
    env->ep = NULL;
}

void ocv_dut_reset(ocv_env_t *env, int hold)
{
    hub_wr(env, OCV_HUB_REG_DUT_CTRL, hold ? OCV_DUT_CTRL_RESET : 0);
    if (hold)                                    /* the endpoints restart: so do their rings */
        for (int ch = 0; ch < env->dut->n_channels; ch++) env->ep[ch].tail = 0;
}

uint64_t ocv_cycles(ocv_env_t *env)
{
    uint64_t lo = hub_rd(env, OCV_HUB_REG_CYCLES_LO);   /* snapshots HI */
    uint64_t hi = hub_rd(env, OCV_HUB_REG_CYCLES_HI);
    return (hi << 32) | lo;
}

uint32_t ocv_ep_rd(ocv_env_t *env, int ch, uint32_t reg)
{
    return env->bus->rd(env->bus, env->ep[ch].base + reg);
}

void ocv_ep_wr(ocv_env_t *env, int ch, uint32_t reg, uint32_t v)
{
    env->bus->wr(env->bus, env->ep[ch].base + reg, v);
    if (reg == OCV_EP_REG_CTRL && (v & OCV_CTRL_CLEAR)) env->ep[ch].tail = 0;   /* the ring restarts too */
}

/* ---------------- DMA rings ---------------- */
int ocv_ring_setup(ocv_env_t *env, size_t max_bytes)
{
    ocv_bus_t *bus = env->bus;
    int n = 0;
    for (int ch = 0; ch < env->dut->n_channels; ch++)
        if (env->dut->channels[ch].kind != OCV_CH_SOURCE && (env->ep[ch].kind & OCV_KIND_DMA)) n++;
    if (!n || !bus->dma_va || !bus->dma_size) return 0;
    /* one share per ring: the largest power of two that fits, aligned in bus address space */
    size_t share = 1;
    while (share * 2 <= bus->dma_size / (size_t)n) share *= 2;
    if (max_bytes && share > max_bytes) { share = 1; while (share * 2 <= max_bytes) share *= 2; }
    uint64_t pa;
    for (;; share /= 2) {                         /* smaller shares if the alignment does not fit */
        pa = (bus->dma_pa + share - 1) & ~(uint64_t)(share - 1);
        if (share < 64 || pa + (uint64_t)share * (uint64_t)n <= bus->dma_pa + bus->dma_size) break;
    }
    int done = 0;
    for (int ch = 0; ch < env->dut->n_channels; ch++) {
        ocv_ep_t *ep = &env->ep[ch];
        if (env->dut->channels[ch].kind == OCV_CH_SOURCE || !(ep->kind & OCV_KIND_DMA)) continue;
        if (pa + share > bus->dma_pa + bus->dma_size) break;    /* alignment ate the last share */
        uint32_t lg = ocv_ep_rd(env, ch, OCV_EP_REG_RING_LOG2);
        uint32_t slot_log2 = OCV_RING_SLOT_LOG2(lg), ring_log2 = 0;
        while (((size_t)1 << (ring_log2 + 1 + slot_log2)) <= share && ring_log2 < 24) ring_log2++;
        if (ring_log2 < 1) continue;
        ocv_ep_wr(env, ch, OCV_EP_REG_RING_LO, (uint32_t)pa);
        ocv_ep_wr(env, ch, OCV_EP_REG_RING_HI, (uint32_t)(pa >> 32));
        ocv_ep_wr(env, ch, OCV_EP_REG_RING_LOG2, ring_log2);
        if ((ocv_ep_rd(env, ch, OCV_EP_REG_RING_LOG2) & 0x1Fu) != ring_log2) continue;
        ep->ring = (const uint8_t *)bus->dma_va + (pa - bus->dma_pa);
        ep->ring_log2 = ring_log2;
        ep->slot_log2 = slot_log2;
        ep->tail = ocv_ep_rd(env, ch, OCV_EP_REG_RING_TAIL);
        pa += share;
        done++;
    }
    return done;
}

uint32_t ocv_ring_take(ocv_env_t *env, int ch, uint32_t *rec, uint32_t max)
{
    ocv_ep_t *ep = &env->ep[ch];
    const uint32_t words = ocv_store_words(&env->dut->channels[ch]);
    uint32_t n = ocv_ep_rd(env, ch, OCV_EP_REG_RING_HEAD) - ep->tail;
    if (n > max) n = max;
    if (!n) return 0;
    const uint32_t mask = (1u << ep->ring_log2) - 1u, slot = 1u << ep->slot_log2;
    for (uint32_t done = 0; done < n;) {         /* up to the ring's end, then from its start */
        uint32_t first = (ep->tail + done) & mask, k = n - done;
        if (k > mask + 1u - first) k = mask + 1u - first;
        const uint8_t *src = ep->ring + ((size_t)first << ep->slot_log2);
        if (env->bus->dma_sync) env->bus->dma_sync(env->bus, src, (size_t)k << ep->slot_log2);
        uint32_t *dst = rec + (size_t)done * words;
        if (slot == words * 4u) memcpy(dst, src, (size_t)k * slot);
        else for (uint32_t i = 0; i < k; i++) memcpy(dst + (size_t)i * words, src + (size_t)i * slot, words * 4u);
        done += k;
    }
    ep->tail += n;
    ocv_ep_wr(env, ch, OCV_EP_REG_RING_TAIL, ep->tail);
    return n;
}

uint32_t ocv_ring_pending(ocv_env_t *env, int ch)
{
    return ocv_ep_rd(env, ch, OCV_EP_REG_COUNT) - env->ep[ch].tail;
}

static uint32_t word_addr(const ocv_ep_t *ep, uint32_t i, uint32_t j)
{
    return ep->base + ep->buf_off + (((i << ep->stride_log2) + j) << 2);
}

void ocv_rec_write(ocv_env_t *env, int ch, uint32_t i, const uint32_t *rec)
{
    const ocv_ep_t *ep = &env->ep[ch];
    for (uint32_t j = 0; j < env->dut->channels[ch].rec_words; j++)
        env->bus->wr(env->bus, word_addr(ep, i, j), rec[j]);
}

void ocv_rec_read(ocv_env_t *env, int ch, uint32_t i, uint32_t *rec)
{
    const ocv_ep_t *ep = &env->ep[ch];
    for (uint32_t j = 0; j < ocv_store_words(&env->dut->channels[ch]); j++)
        rec[j] = env->bus->rd(env->bus, word_addr(ep, i, j));
}

void ocv_rec_read_block(ocv_env_t *env, int ch, uint32_t first, uint32_t n, uint32_t *rec)
{
    const ocv_ep_t *ep = &env->ep[ch];
    uint32_t words = ocv_store_words(&env->dut->channels[ch]), stride = 1u << ep->stride_log2;
    if (!env->bus->rd_block || n == 0) {
        for (uint32_t i = 0; i < n; i++) ocv_rec_read(env, ch, first + i, rec + (size_t)i * words);
        return;
    }
    if (stride == words) {                          /* slots are packed: read straight into rec */
        env->bus->rd_block(env->bus, word_addr(ep, first, 0), rec, n * words);
        return;
    }
    static uint32_t *tmp;                           /* slots have padding: read, then compact */
    static size_t tmp_cap;
    if ((size_t)n * stride > tmp_cap) {
        tmp_cap = (size_t)n * stride;
        tmp = realloc(tmp, tmp_cap * sizeof *tmp);
        if (!tmp) { fprintf(stderr, "ocv: out of memory\n"); exit(1); }
    }
    env->bus->rd_block(env->bus, word_addr(ep, first, 0), tmp, n * stride);
    for (uint32_t i = 0; i < n; i++) memcpy(rec + (size_t)i * words, tmp + (size_t)i * stride, words * 4u);
}

/* ------------------------------------------------------------------ diagnostics */

/* ocv_hub_info (runner --info). Unlike ocv_env_open it does not stop at the first difference, so
 * on a new board it shows at once whether the bridge, the clock and the image are right. Writes go
 * to the THROTTLE register of every endpoint and to the first and last record of every source
 * buffer. */
static void chk(FILE *out, int *bad, int ok, const char *what, uint32_t got, uint32_t want)
{
    fprintf(out, "  %-28s 0x%08x  %s", what, got, ok ? "ok" : "MISMATCH");
    if (!ok) { fprintf(out, " (expected 0x%08x)", want); (*bad)++; }
    fprintf(out, "\n");
}

int ocv_hub_info(ocv_bus_t *bus, const ocv_dut_t *dut, FILE *out)
{
    int bad = 0;
    fprintf(out, "hub (metadata: '%s', %d channel(s)):\n", dut->name, dut->n_channels);
    uint32_t id = bus->rd(bus, OCV_HUB_REG_ID);
    chk(out, &bad, id == OCV_HUB_ID_VALUE, "ID", id, OCV_HUB_ID_VALUE);
    if (id != OCV_HUB_ID_VALUE) {
        fprintf(out, "no OCV hub at this address: wrong --base, or the FPGA image has no OCV environment\n");
        return 1;
    }
    uint32_t v = bus->rd(bus, OCV_HUB_REG_VERSION);
    chk(out, &bad, v == OCV_HUB_VERSION_VALUE, "VERSION", v, OCV_HUB_VERSION_VALUE);
    v = bus->rd(bus, OCV_HUB_REG_DUT_ID);
    chk(out, &bad, v == dut->dut_id, "DUT_ID (descriptor CRC32)", v, dut->dut_id);
    uint32_t layout = bus->rd(bus, OCV_HUB_REG_LAYOUT);
    chk(out, &bad, OCV_LAYOUT_ENDPOINTS(layout) == (uint32_t)dut->n_channels, "LAYOUT (endpoints)",
        OCV_LAYOUT_ENDPOINTS(layout), (uint32_t)dut->n_channels);
    unsigned slot_log2 = OCV_LAYOUT_SLOT_LOG2(layout);
    fprintf(out, "  %-28s %u bytes\n", "slot size", 1u << slot_log2);

    uint32_t ctrl = bus->rd(bus, OCV_HUB_REG_DUT_CTRL);
    bus->wr(bus, OCV_HUB_REG_DUT_CTRL, 0);             /* counter runs only out of reset */
    uint32_t c0 = bus->rd(bus, OCV_HUB_REG_CYCLES_LO);
    uint32_t c1 = bus->rd(bus, OCV_HUB_REG_CYCLES_LO);
    fprintf(out, "  %-28s %u -> %u  %s\n", "CYCLES (two reads)", c0, c1, c1 != c0 ? "ok, clock runs" : "STOPPED");
    if (c1 == c0) bad++;
    bus->wr(bus, OCV_HUB_REG_DUT_CTRL, ctrl);

    unsigned n = OCV_LAYOUT_ENDPOINTS(layout);
    for (unsigned k = 0; k < n; k++) {
        const ocv_channel_t *c = (k < (unsigned)dut->n_channels) ? &dut->channels[k] : NULL;
        uint32_t base = (k + 1u) << slot_log2;
        fprintf(out, "slot %u: %s\n", k + 1, c ? c->name : "(not in the metadata)");
        uint32_t eid = bus->rd(bus, base + OCV_EP_REG_ID);
        chk(out, &bad, eid == OCV_EP_ID_VALUE, "ID", eid, OCV_EP_ID_VALUE);
        if (eid != OCV_EP_ID_VALUE) continue;
        uint32_t kind = bus->rd(bus, base + OCV_EP_REG_KIND);
        uint32_t g = bus->rd(bus, base + OCV_EP_REG_GEOMETRY);
        fprintf(out, "  %-28s %s%s%s%s%s, %u word(s) x %u records\n", "endpoint",
               OCV_KIND_OF(kind) == OCV_EP_KIND_SOURCE ? "source" : "sink",
               (kind & OCV_KIND_BACKPRESSURE) ? ", backpressure" : "",
               (kind & OCV_KIND_LOSSLESS) ? ", lossless" : "",
               (kind & OCV_KIND_STREAM) ? ", stream" : "",
               (kind & OCV_KIND_FREEZE_STARVED) ? ", freeze when starved" :
               (kind & OCV_KIND_SQUASH) ? ", squash" : "",
               OCV_GEOM_REC_WORDS(g), 1u << OCV_GEOM_LOG2_DEPTH(g));
        if (c) {
            uint32_t want = (c->kind == OCV_CH_SOURCE) ? OCV_EP_KIND_SOURCE : OCV_EP_KIND_SINK;
            chk(out, &bad, OCV_KIND_OF(kind) == want, "KIND", OCV_KIND_OF(kind), want);
            if (c->kind != OCV_CH_SOURCE)
                chk(out, &bad, !!(kind & OCV_KIND_LOSSLESS) == !!c->lossless, "lossless",
                    !!(kind & OCV_KIND_LOSSLESS), !!c->lossless);
            else {
                chk(out, &bad, !!(kind & OCV_KIND_STREAM) == !!c->stream, "stream",
                    !!(kind & OCV_KIND_STREAM), !!c->stream);
                chk(out, &bad, !!(kind & OCV_KIND_FREEZE_STARVED) == !!c->freeze_starved, "freeze when starved",
                    !!(kind & OCV_KIND_FREEZE_STARVED), !!c->freeze_starved);
            }
            if (c->kind != OCV_CH_SOURCE)
                chk(out, &bad, !!(kind & OCV_KIND_SQUASH) == !!c->squash, "squash",
                    !!(kind & OCV_KIND_SQUASH), !!c->squash);
            chk(out, &bad, OCV_GEOM_REC_WORDS(g) == ocv_store_words(c), "record words", OCV_GEOM_REC_WORDS(g),
                ocv_store_words(c));
            chk(out, &bad, (1u << OCV_GEOM_LOG2_DEPTH(g)) == c->depth, "depth",
                1u << OCV_GEOM_LOG2_DEPTH(g), c->depth);
        }
        /* write path: the THROTTLE register of every endpoint */
        uint32_t thr = bus->rd(bus, base + OCV_EP_REG_THROTTLE);
        int wr_ok = 1;
        for (uint32_t pat = 0x5A; pat; pat = (pat == 0x5A) ? 0xA5 : 0) {
            bus->wr(bus, base + OCV_EP_REG_THROTTLE, pat);
            wr_ok &= (bus->rd(bus, base + OCV_EP_REG_THROTTLE) & 0xFF) == pat;
        }
        bus->wr(bus, base + OCV_EP_REG_THROTTLE, thr);
        fprintf(out, "  %-28s %s\n", "register write/read", wr_ok ? "ok" : "FAILED");
        if (!wr_ok) bad++;
        /* buffer path: first and last record of a source buffer (sink buffers are DUT-written) */
        if (OCV_KIND_OF(kind) == OCV_EP_KIND_SOURCE) {
            uint32_t off = (uint32_t)OCV_GEOM_BUF_OFFSET(g), words = OCV_GEOM_REC_WORDS(g);
            uint32_t stride = 4u << OCV_GEOM_LOG2_STRIDE(g), last = (1u << OCV_GEOM_LOG2_DEPTH(g)) - 1;
            int ram_ok = 1;
            for (uint32_t r = 0; r <= last; r += last ? last : 1) {
                for (uint32_t w = 0; w < words; w++) {
                    uint32_t a = base + off + r * stride + 4 * w, keep = bus->rd(bus, a);
                    uint32_t pat = 0xC0DE0000u ^ (r << 8) ^ w;
                    bus->wr(bus, a, pat);
                    ram_ok &= bus->rd(bus, a) == pat;
                    bus->wr(bus, a, keep);
                }
                if (!last) break;
            }
            fprintf(out, "  %-28s %s\n", "buffer write/read", ram_ok ? "ok" : "FAILED");
            if (!ram_ok) bad++;
        }
    }
    fprintf(out, "INFO: %s\n", bad ? "PROBLEMS FOUND" : "hub, endpoints and bus OK");
    return bad;
}

/* ------------------------------------------------------------------ fields */

static uint64_t width_mask(unsigned w) { return w >= 64 ? ~0ull : ((1ull << w) - 1); }

const ocv_field_t *ocv_field(const ocv_channel_t *c, const char *name)
{
    for (int i = 0; i < c->n_fields; i++)
        if (!strcmp(c->fields[i].name, name)) return &c->fields[i];
    return NULL;
}

uint64_t ocv_get_raw(const uint32_t *rec, const ocv_field_t *f)
{
    uint64_t v = 0;
    for (unsigned b = 0; b < f->width; ) {
        unsigned bit = f->lsb + b, w = bit >> 5, o = bit & 31;
        unsigned take = 32 - o;
        if (take > f->width - b) take = f->width - b;
        uint64_t chunk = (rec[w] >> o) & width_mask(take);
        v |= chunk << b;
        b += take;
    }
    return v;
}

int64_t ocv_get_int(const uint32_t *rec, const ocv_field_t *f)
{
    uint64_t v = ocv_get_raw(rec, f);
    if (f->is_signed && f->width < 64 && (v >> (f->width - 1)) & 1)
        v |= ~width_mask(f->width);
    return (int64_t)v;
}

void ocv_set_raw_any(uint32_t *rec, const ocv_field_t *f, uint64_t v)
{
    v &= width_mask(f->width);
    for (unsigned b = 0; b < f->width; ) {
        unsigned bit = f->lsb + b, w = bit >> 5, o = bit & 31;
        unsigned take = 32 - o;
        if (take > f->width - b) take = f->width - b;
        uint32_t m = (uint32_t)(width_mask(take) << o);
        rec[w] = (rec[w] & ~m) | ((uint32_t)((v >> b) << o) & m);
        b += take;
    }
}

static const ocv_field_t *field_or_die(const ocv_channel_t *c, const char *name)
{
    const ocv_field_t *f = ocv_field(c, name);
    if (!f) {
        fprintf(stderr, "ocv: channel '%s' has no field '%s'\n", c->name, name);
        abort();
    }
    return f;
}

int64_t ocv_get(const ocv_channel_t *c, const uint32_t *rec, const char *field)
{
    return ocv_get_int(rec, field_or_die(c, field));
}

void ocv_set(const ocv_channel_t *c, uint32_t *rec, const char *field, uint64_t v)
{
    ocv_set_raw(rec, field_or_die(c, field), v);
}

/* ------------------------------------------------------------------ comparison */

static int64_t sext(uint64_t v, unsigned w)
{
    if (w < 64 && (v >> (w - 1)) & 1) v |= ~width_mask(w);
    return (int64_t)v;
}

/* Map IEEE-754 bits to an integer that is monotonic in the value, so that the distance in
 * units in the last place is a subtraction. +0 and -0 both map to 0. */
static int64_t fp_ordered(uint64_t bits, unsigned w)
{
    uint64_t sign = 1ull << (w - 1);
    int64_t mag = (int64_t)(bits & (sign - 1));
    return (bits & sign) ? -mag : mag;
}

static int fp_is_nan(uint64_t bits, unsigned w)
{
    unsigned eb = (w == 16) ? 5 : (w == 32) ? 8 : 11;
    unsigned mb = w - 1 - eb;
    uint64_t exp = (bits >> mb) & width_mask(eb);
    return exp == width_mask(eb) && (bits & width_mask(mb)) != 0;
}

int ocv_field_match(const ocv_field_t *f, uint64_t dut, uint64_t model)
{
    uint64_t m = width_mask(f->width);
    dut &= m;
    model &= m;
    switch (f->cmp) {
    case OCV_CMP_IGNORE:
        return 1;
    case OCV_CMP_MASK:
        return ((dut ^ model) & f->arg) == 0;
    case OCV_CMP_ABS: {
        uint64_t diff;
        if (f->is_signed) {
            int64_t a = sext(dut, f->width), b = sext(model, f->width);
            diff = a > b ? (uint64_t)a - (uint64_t)b : (uint64_t)b - (uint64_t)a;
        } else {
            diff = dut > model ? dut - model : model - dut;
        }
        return diff <= f->arg;
    }
    case OCV_CMP_ULP: {
        unsigned w = f->fp;
        int dn = fp_is_nan(dut, w), mn = fp_is_nan(model, w);
        if (dn || mn) return dn && mn;
        int64_t a = fp_ordered(dut, w), b = fp_ordered(model, w);
        uint64_t diff = a > b ? (uint64_t)a - (uint64_t)b : (uint64_t)b - (uint64_t)a;
        return diff <= f->arg;
    }
    case OCV_CMP_EXACT:
    default:
        return dut == model;
    }
}

int ocv_channel_word_masks(const ocv_channel_t *c, uint32_t *mask)
{
    memset(mask, 0, c->rec_words * 4u);
    for (int i = 0; i < c->n_fields; i++) {
        const ocv_field_t *f = &c->fields[i];
        uint64_t bits;
        switch (f->cmp) {
        case OCV_CMP_EXACT:  bits = width_mask(f->width); break;
        case OCV_CMP_MASK:   bits = f->arg & width_mask(f->width); break;
        case OCV_CMP_IGNORE: bits = 0; break;
        default:             return 0;
        }
        ocv_set_raw(mask, f, bits);
    }
    return 1;
}

int ocv_rec_mismatch(const ocv_channel_t *c, const uint32_t *dut, const uint32_t *model)
{
    for (int i = 0; i < c->n_fields; i++) {
        const ocv_field_t *f = &c->fields[i];
        if (!ocv_field_match(f, ocv_get_raw(dut, f), ocv_get_raw(model, f))) return i;
    }
    return -1;
}

void ocv_rec_format(const ocv_channel_t *c, const uint32_t *rec, char *buf, size_t n)
{
    size_t o = 0;
    buf[0] = 0;
    for (int i = 0; i < c->n_fields && o < n; i++) {
        const ocv_field_t *f = &c->fields[i];
        uint64_t raw = ocv_get_raw(rec, f);
        int k;
        if (f->is_signed)
            k = snprintf(buf + o, n - o, "%s%s=%lld", i ? " " : "", f->name, (long long)ocv_get_int(rec, f));
        else
            k = snprintf(buf + o, n - o, "%s%s=0x%llx", i ? " " : "", f->name, (unsigned long long)raw);
        if (k < 0) break;
        o += (size_t)k;
    }
}

uint64_t ocv_rand(uint64_t *state)
{
    uint64_t x = *state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *state = x;
    return x * 0x2545F4914F6CDD1Dull;
}

/* ---------------- squash ---------------- */
/* CRC32C (Castagnoli) and CRC32 (IEEE), reflected, 32-bit word at a time, no inversion: the ARMv8
 * crc32cw / crc32w instructions; a table fallback elsewhere */
#if defined(__ARM_FEATURE_CRC32)
#include <arm_acle.h>
#include <arm_neon.h>
static inline uint32_t crc_c(uint32_t c, uint32_t w) { return __crc32cw(c, w); }
static inline uint32_t crc_z(uint32_t c, uint32_t w) { return __crc32w(c, w); }
#else
static uint32_t tab_c[4][256], tab_z[4][256];
static void crc_tables(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t a = i, b = i;
        for (int k = 0; k < 8; k++) {
            a = (a >> 1) ^ (0x82F63B78u & (0u - (a & 1)));
            b = (b >> 1) ^ (0xEDB88320u & (0u - (b & 1)));
        }
        tab_c[0][i] = a; tab_z[0][i] = b;
    }
    for (uint32_t i = 0; i < 256; i++)
        for (int t = 1; t < 4; t++) {
            tab_c[t][i] = (tab_c[t - 1][i] >> 8) ^ tab_c[0][tab_c[t - 1][i] & 0xFF];
            tab_z[t][i] = (tab_z[t - 1][i] >> 8) ^ tab_z[0][tab_z[t - 1][i] & 0xFF];
        }
}
static inline uint32_t crc_word(uint32_t (*t)[256], uint32_t c, uint32_t w)
{
    c ^= w;
    return t[3][c & 0xFF] ^ t[2][(c >> 8) & 0xFF] ^ t[1][(c >> 16) & 0xFF] ^ t[0][c >> 24];
}
static inline uint32_t crc_c(uint32_t c, uint32_t w) { return crc_word(tab_c, c, w); }
static inline uint32_t crc_z(uint32_t c, uint32_t w) { return crc_word(tab_z, c, w); }
#endif

void ocv_squash_add(uint32_t *crc32c, uint32_t *crc32, const uint32_t *rec, const uint32_t *mask, uint32_t words)
{
#if !defined(__ARM_FEATURE_CRC32)
    static int ready;
    if (!ready) { crc_tables(); ready = 1; }
#endif
    uint32_t a = *crc32c, b = *crc32;
    uint32_t j = 0;
#if defined(__ARM_FEATURE_CRC32)
    /* two words at a time: crc32cd/crc32d over a little-endian doubleword = two crc32cw/crc32w */
    for (; j + 1 < words; j += 2) {
        const uint64_t d = (uint64_t)(rec[j] & mask[j]) | ((uint64_t)(rec[j + 1] & mask[j + 1]) << 32);
        a = __crc32cd(a, d);
        b = __crc32d(b, d);
    }
#endif
    for (; j < words; j++) {
        uint32_t w = rec[j] & mask[j];
        a = crc_c(a, w);
        b = crc_z(b, w);
    }
    *crc32c = a;
    *crc32 = b;
}

/* a * b modulo the (bit-reflected) polynomial p, reflected: 1 is 0x80000000 (zlib's multmodp) */
static uint32_t gf_mul(uint32_t a, uint32_t b, uint32_t p)
{
    uint32_t m = 1u << 31, r = 0;
    for (; m; m >>= 1) {
        if (a & m) r ^= b;
        b = (b >> 1) ^ (p & (0u - (b & 1)));
    }
    return r;
}
static uint32_t gf_xpow(uint64_t e, uint32_t p)             /* x^e modulo p */
{
    uint32_t r = 1u << 31, x = 1u << 30;
    for (; e; e >>= 1, x = gf_mul(x, x, p)) if (e & 1) r = gf_mul(r, x, p);
    return r;
}

int ocv_fold_make(ocv_fold_t *f, const uint32_t *recs, uint32_t n, uint32_t stride, const uint32_t *mask, uint32_t words)
{
    const uint64_t bytes = (uint64_t)n * words * 4u;
    if (words > 16 || n * words < 2) return 0;
    f->n = n; f->words = words; f->c = 0; f->z = 0;
    for (uint32_t i = 0; i < n; i++) ocv_squash_add(&f->c, &f->z, recs + (size_t)i * stride, mask, words);
    for (uint32_t j = 0; j < words; j++) f->last[j] = recs[(size_t)(n - 1) * stride + j];
    /* crc(s, zeros of `bytes`) = s * x^(8 bytes); with the 64-bit carry-less product reduced by the CRC
     * instruction (one more x^32, and the product's reflected bit order: one less) the constant is x^(8 bytes - 33) */
    f->kc = gf_xpow(8 * bytes - 33, 0x82F63B78u);
    f->kz = gf_xpow(8 * bytes - 33, 0xEDB88320u);
    return 1;
}

#if defined(__aarch64__) && defined(__ARM_FEATURE_CRC32)
__attribute__((target("+crypto")))                          /* (PMULL: the A72 has it, -mcpu=cortex-a72 not) */
static inline uint64_t clmul32(uint32_t a, uint32_t b) { return (uint64_t)vmull_p64(a, b); }
void ocv_fold_apply(uint32_t *crc32c, uint32_t *crc32, const ocv_fold_t *f)
{
    *crc32c = __crc32cd(0, clmul32(*crc32c, f->kc)) ^ f->c;
    *crc32  = __crc32d(0, clmul32(*crc32, f->kz)) ^ f->z;
}
#else
void ocv_fold_apply(uint32_t *crc32c, uint32_t *crc32, const ocv_fold_t *f)   /* (the PC: slowly) */
{
    *crc32c = gf_mul(gf_mul(f->kc, gf_xpow(33, 0x82F63B78u), 0x82F63B78u), *crc32c, 0x82F63B78u) ^ f->c;
    *crc32  = gf_mul(gf_mul(f->kz, gf_xpow(33, 0xEDB88320u), 0xEDB88320u), *crc32, 0xEDB88320u) ^ f->z;
}
#endif

void ocv_squash_window(ocv_env_t *env, int ch, uint32_t n) { ocv_ep_wr(env, ch, OCV_EP_REG_SQUASH, n); }

int ocv_squash_mask(ocv_env_t *env, int ch, const uint32_t *mask, uint32_t words)
{
    if (!(ocv_ep_rd(env, ch, OCV_EP_REG_KIND) & OCV_KIND_SQMASK)) return 0;
    for (uint32_t j = 0; j < words; j++) {
        ocv_ep_wr(env, ch, OCV_EP_REG_SQMASK_SEL, j);
        ocv_ep_wr(env, ch, OCV_EP_REG_SQMASK, mask[j]);
        if (ocv_ep_rd(env, ch, OCV_EP_REG_SQMASK) != mask[j]) return 0;
    }
    return 1;
}

int ocv_squash_breaks(ocv_env_t *env, int ch, int n, uint32_t mask[][32], uint32_t value[][32], uint32_t words)
{
    if (!(ocv_ep_rd(env, ch, OCV_EP_REG_KIND) & OCV_KIND_SQBRK)) return 0;
    const uint32_t en = n >= 4 ? 0xFu : ((1u << n) - 1u);
    for (int p = 0; p < 4; p++)
        for (uint32_t j = 0; j < words; j++)
            for (uint32_t isval = 0; isval < 2; isval++) {
                const uint32_t v = p < n ? (isval ? value[p][j] : mask[p][j]) : 0;
                ocv_ep_wr(env, ch, OCV_EP_REG_BRK_SEL, (en << 16) | (isval << 11) | ((uint32_t)p << 8) | j);
                ocv_ep_wr(env, ch, OCV_EP_REG_BRK_DATA, v);
                if (ocv_ep_rd(env, ch, OCV_EP_REG_BRK_DATA) != v) return 0;
            }
    return 1;
}

void ocv_squash_flush(ocv_env_t *env, int ch)
{
    ocv_ep_wr(env, ch, OCV_EP_REG_CTRL, ocv_ep_rd(env, ch, OCV_EP_REG_CTRL) | OCV_CTRL_FLUSH);
}
