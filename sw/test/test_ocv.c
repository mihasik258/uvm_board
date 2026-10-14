/* test_ocv.c - unit tests of the OCV software core (ocv.c) against a fake bus.
 *
 *   cc -std=c99 -Wall -Wextra -Werror -I../include test_ocv.c ../lib/ocv.c -o test_ocv && ./test_ocv
 */
#include <stdio.h>
#include <string.h>

#include "ocv.h"

static int failures;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

/* ---------------- fields ---------------- */
static void test_fields(void)
{
    /* a 40-bit signed field starting at bit 20 spans words 0 and 1 */
    ocv_field_t f = { "x", 20, 40, 1, OCV_CMP_EXACT, 0, 0 };
    uint32_t rec[3] = { 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu };
    ocv_set_raw(rec, &f, 0x8000000001ull);
    CHECK(ocv_get_raw(rec, &f) == 0x8000000001ull);
    CHECK(ocv_get_int(rec, &f) == -549755813887LL);      /* 0x8000000001 as signed 40-bit */
    CHECK((rec[0] & 0xFFFFF) == 0xFFFFF);                 /* bits below the field untouched */
    CHECK((rec[1] >> 28) == 0xF && rec[2] == 0xFFFFFFFFu); /* bits above untouched */

    ocv_field_t u = { "u", 0, 64, 0, OCV_CMP_EXACT, 0, 0 };
    uint32_t r2[2] = { 0, 0 };
    ocv_set_raw(r2, &u, 0xDEADBEEFCAFEF00Dull);
    CHECK(r2[0] == 0xCAFEF00Du && r2[1] == 0xDEADBEEFu);
    CHECK(ocv_get_raw(r2, &u) == 0xDEADBEEFCAFEF00Dull);

    ocv_field_t one = { "b", 31, 1, 0, OCV_CMP_EXACT, 0, 0 };
    uint32_t r3[1] = { 0 };
    ocv_set_raw(r3, &one, 3);                              /* truncated to 1 bit */
    CHECK(r3[0] == 0x80000000u && ocv_get_raw(r3, &one) == 1);
}

/* ---------------- compare rules ---------------- */
static uint32_t f32(float x) { uint32_t b; memcpy(&b, &x, 4); return b; }

static void test_compare(void)
{
    ocv_field_t ex = { "e", 0, 16, 0, OCV_CMP_EXACT, 0, 0 };
    CHECK(ocv_field_match(&ex, 0x1234, 0x1234));
    CHECK(!ocv_field_match(&ex, 0x1234, 0x1235));
    CHECK(ocv_field_match(&ex, 0x11234, 0x1234));          /* bits beyond width ignored */

    ocv_field_t ig = { "i", 0, 16, 0, OCV_CMP_IGNORE, 0, 0 };
    CHECK(ocv_field_match(&ig, 1, 2));

    ocv_field_t mk = { "m", 0, 16, 0, OCV_CMP_MASK, 0, 0xFF00 };
    CHECK(ocv_field_match(&mk, 0x12AA, 0x12BB));
    CHECK(!ocv_field_match(&mk, 0x13AA, 0x12AA));

    ocv_field_t ab = { "a", 0, 8, 1, OCV_CMP_ABS, 0, 2 };   /* signed 8-bit, |diff| <= 2 */
    CHECK(ocv_field_match(&ab, 0xFF, 0x01));                /* -1 vs 1 */
    CHECK(!ocv_field_match(&ab, 0xFE, 0x01));               /* -2 vs 1 */
    CHECK(!ocv_field_match(&ab, 0x80, 0x7F));               /* -128 vs 127: far apart, no wrap */
    ocv_field_t au = { "a", 0, 64, 1, OCV_CMP_ABS, 0, 1 };  /* full-range signed, no overflow */
    CHECK(!ocv_field_match(&au, 0x8000000000000000ull, 0x7FFFFFFFFFFFFFFFull));
    CHECK(ocv_field_match(&au, 0x8000000000000000ull, 0x8000000000000001ull));

    ocv_field_t fp = { "f", 0, 32, 0, OCV_CMP_ULP, OCV_FP32, 1 };
    uint32_t one = f32(1.0f), next = one + 1, next2 = one + 2;
    CHECK(ocv_field_match(&fp, one, next));
    CHECK(!ocv_field_match(&fp, one, next2));
    CHECK(ocv_field_match(&fp, f32(0.0f), f32(-0.0f)));     /* +0 == -0 */
    CHECK(ocv_field_match(&fp, 0x7FC00000u, 0x7FC00001u));  /* NaN == NaN (any payload) */
    CHECK(!ocv_field_match(&fp, 0x7FC00000u, one));
    CHECK(!ocv_field_match(&fp, f32(1.0f), f32(-1.0f)));
    CHECK(ocv_field_match(&fp, 0x00000001u, 0x80000001u) == 0);  /* +/- smallest denormals: 2 ulp */
    ocv_field_t fp2 = fp; fp2.arg = 2;
    CHECK(ocv_field_match(&fp2, 0x00000001u, 0x80000001u));

    /* record-level: first mismatching field index */
    ocv_field_t fs[2] = { { "lo", 0, 16, 0, OCV_CMP_EXACT, 0, 0 }, { "hi", 16, 16, 0, OCV_CMP_IGNORE, 0, 0 } };
    ocv_channel_t c = { "c", OCV_CH_SINK, 1, 1, 16, 2, fs, 0, 0, 0, 0 };
    uint32_t d = 0xAAAA1234u, m1 = 0xBBBB1234u, m2 = 0xAAAA1235u;
    CHECK(ocv_rec_mismatch(&c, &d, &m1) == -1);
    CHECK(ocv_rec_mismatch(&c, &d, &m2) == 0);
}

/* ---------------- environment checks against a fake hub ---------------- */
typedef struct {
    uint32_t mem[1 << 14];    /* 64 KiB of registers */
    int      clock;           /* CYCLES_LO advances on every read */
    uint32_t ro_off;          /* writes to this offset are lost (0 = none) */
} fake_t;

static uint32_t fk_rd(ocv_bus_t *b, uint32_t off)
{
    fake_t *f = b->priv;
    if (off == OCV_HUB_REG_CYCLES_LO && f->clock) f->mem[off >> 2] += 7;
    return f->mem[(off >> 2) & 0x3FFF];
}
static void fk_wr(ocv_bus_t *b, uint32_t off, uint32_t v)
{
    fake_t *f = b->priv;
    if (f->ro_off && off == f->ro_off) return;
    f->mem[(off >> 2) & 0x3FFF] = v;
}

static void fk_rd_block(ocv_bus_t *b, uint32_t off, uint32_t *dst, uint32_t n)
{
    fake_t *f = b->priv;
    memcpy(dst, &f->mem[(off >> 2) & 0x3FFF], n * 4u);
}

static void fake_setup(fake_t *f, uint32_t dut_id)
{
    memset(f, 0, sizeof *f);
    const unsigned slot_log2 = 12;
    f->clock = 1;
    f->mem[OCV_HUB_REG_ID / 4] = OCV_HUB_ID_VALUE;
    f->mem[OCV_HUB_REG_VERSION / 4] = OCV_HUB_VERSION_VALUE;
    f->mem[OCV_HUB_REG_DUT_ID / 4] = dut_id;
    f->mem[OCV_HUB_REG_LAYOUT / 4] = (slot_log2 << 8) | 2;
    for (unsigned s = 1; s <= 2; s++) {
        uint32_t *ep = &f->mem[(s << slot_log2) / 4];
        ep[OCV_EP_REG_ID / 4] = OCV_EP_ID_VALUE;
        ep[OCV_EP_REG_KIND / 4] = (s == 1) ? OCV_EP_KIND_SOURCE : (OCV_EP_KIND_SINK | OCV_KIND_BACKPRESSURE);
        /* 2 words/record, 16 records, stride 2 words, buffer at 1 << 11 */
        ep[OCV_EP_REG_GEOMETRY / 4] = (11u << 24) | (1u << 16) | (4u << 8) | 2u;
    }
}

static void test_env(void)
{
    static fake_t f;
    ocv_bus_t bus = { fk_rd, fk_wr, &f, NULL, NULL, 0, 0, NULL };
    ocv_field_t fi[1] = { { "v", 0, 64, 0, OCV_CMP_EXACT, 0, 0 } };
    ocv_channel_t ch[2] = { { "in", OCV_CH_SOURCE, 1, 2, 16, 1, fi, 0, 0, 0, 0 }, { "out", OCV_CH_SINK, 2, 2, 16, 1, fi, 0, 0, 0, 0 } };
    ocv_dut_t dut = { "t", 0x1234ABCDu, 2, ch };
    ocv_env_t env;
    char err[256];

    fake_setup(&f, 0x1234ABCDu);
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == 0);
    /* record 3 of 'in' goes to slot 1 base + buffer offset + (3 << 1) words */
    uint32_t rec[2] = { 0x11111111u, 0x22222222u }, back[2];
    ocv_rec_write(&env, 0, 3, rec);
    CHECK(f.mem[((1u << 12) + (1u << 11) + 6 * 4) / 4] == 0x11111111u);
    CHECK(f.mem[((1u << 12) + (1u << 11) + 7 * 4) / 4] == 0x22222222u);
    ocv_rec_read(&env, 0, 3, back);
    CHECK(back[0] == rec[0] && back[1] == rec[1]);
    ocv_env_close(&env);

    fake_setup(&f, 0x0BADF00Du);                                   /* bitstream for another DUT */
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == -1);
    CHECK(strstr(err, "another DUT") != NULL);
    ocv_env_close(&env);

    fake_setup(&f, 0x1234ABCDu);
    f.mem[((2u << 12) + OCV_EP_REG_GEOMETRY) / 4] = (11u << 24) | (1u << 16) | (5u << 8) | 2u;  /* depth 32 */
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == -1);
    CHECK(strstr(err, "'out'") != NULL);
    ocv_env_close(&env);

    fake_setup(&f, 0x1234ABCDu);
    f.mem[((1u << 12) + OCV_EP_REG_KIND) / 4] = OCV_EP_KIND_SINK;   /* source slot holds a sink */
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == -1);
    CHECK(strstr(err, "kind") != NULL);
    ocv_env_close(&env);

    fake_setup(&f, 0x1234ABCDu);
    f.mem[((2u << 12) + OCV_EP_REG_KIND) / 4] |= OCV_KIND_LOSSLESS;  /* hardware lossless, metadata not */
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == -1);
    CHECK(strstr(err, "lossless") != NULL);
    ocv_env_close(&env);

    memset(&f, 0, sizeof f);                                         /* nothing there at all */
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == -1);
    CHECK(strstr(err, "no OCV hub") != NULL);
    ocv_env_close(&env);
}

static void test_word_masks(void)
{
    ocv_field_t fs[4] = { { "a", 0, 12, 0, OCV_CMP_EXACT, 0, 0 },  { "b", 12, 8, 0, OCV_CMP_IGNORE, 0, 0 },
                          { "c", 20, 20, 0, OCV_CMP_MASK, 0, 0xF000Fu }, { "d", 40, 3, 0, OCV_CMP_EXACT, 0, 0 } };
    ocv_channel_t c = { "c", OCV_CH_SINK, 1, 2, 16, 4, fs, 0, 0, 0, 0 };
    uint32_t m[2];
    CHECK(ocv_channel_word_masks(&c, m) == 1);
    /* a: bits 0..11; c: mask 0xF000F at bits 20.. -> bits 20..23 and 36..39; d: bits 40..42 */
    CHECK(m[0] == 0x00F00FFFu);
    CHECK(m[1] == 0x000007F0u);
    /* the mask decides exactly as the field rules do, over random records */
    uint64_t st = 99;
    for (int k = 0; k < 20000; k++) {
        uint32_t d[2] = { (uint32_t)ocv_rand(&st), (uint32_t)ocv_rand(&st) }, e[2] = { d[0], d[1] };
        e[ocv_rand(&st) & 1] ^= 1u << (ocv_rand(&st) & 31);
        int by_mask = ((d[0] ^ e[0]) & m[0]) || ((d[1] ^ e[1]) & m[1]);
        CHECK(by_mask == (ocv_rec_mismatch(&c, d, e) >= 0));
    }
    fs[1].cmp = OCV_CMP_ABS;                               /* a rule that needs the value */
    CHECK(ocv_channel_word_masks(&c, m) == 0);
}

static void test_block(void)
{
    static fake_t f;
    ocv_field_t fi[1] = { { "v", 0, 64, 0, OCV_CMP_EXACT, 0, 0 } };
    ocv_field_t f3[1] = { { "v", 0, 64, 0, OCV_CMP_EXACT, 0, 0 } };     /* record of 3 words */
    ocv_channel_t ch[2] = { { "in", OCV_CH_SOURCE, 1, 2, 16, 1, fi, 0, 0, 0, 0 }, { "out", OCV_CH_SINK, 2, 3, 16, 1, f3, 0, 0, 0, 0 } };
    ocv_dut_t dut = { "t", 0x1234ABCDu, 2, ch };
    ocv_env_t env;
    char err[256];
    uint32_t want[16 * 3], got[16 * 3];

    for (int with_block = 0; with_block < 2; with_block++) {
        ocv_bus_t bus = { fk_rd, fk_wr, &f, with_block ? fk_rd_block : NULL, NULL, 0, 0, NULL };
        fake_setup(&f, 0x1234ABCDu);
        /* 'out': 3 words per record in slots of 4 (padding), buffer at 1 << 11 of slot 2 */
        f.mem[((2u << 12) + OCV_EP_REG_GEOMETRY) / 4] = (11u << 24) | (2u << 16) | (4u << 8) | 3u;
        for (uint32_t i = 0; i < 16; i++)
            for (uint32_t j = 0; j < 4; j++)
                f.mem[((2u << 12) + (1u << 11)) / 4 + i * 4 + j] = j < 3 ? 0xA0000000u + i * 16 + j : 0xDEADu;
        CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == 0);
        for (uint32_t i = 0; i < 16; i++) ocv_rec_read(&env, 1, i, want + i * 3);
        memset(got, 0, sizeof got);
        ocv_rec_read_block(&env, 1, 3, 10, got);              /* records 3..12, padding dropped */
        CHECK(memcmp(got, want + 3 * 3, 10 * 3 * 4) == 0);
        /* 'in': packed slots (2 words, stride 2) */
        uint32_t in_w[4], in_g[4];
        for (uint32_t k = 0; k < 4; k++) f.mem[((1u << 12) + (1u << 11)) / 4 + 10 + k] = 0x5000u + k;
        ocv_rec_read(&env, 0, 5, in_w); ocv_rec_read(&env, 0, 6, in_w + 2);
        ocv_rec_read_block(&env, 0, 5, 2, in_g);
        CHECK(memcmp(in_g, in_w, sizeof in_w) == 0);
        ocv_env_close(&env);
    }
}

static void test_info(void)
{
    static fake_t f;
    ocv_bus_t bus = { fk_rd, fk_wr, &f, NULL, NULL, 0, 0, NULL };
    ocv_field_t fi[1] = { { "v", 0, 64, 0, OCV_CMP_EXACT, 0, 0 } };
    ocv_channel_t ch[2] = { { "in", OCV_CH_SOURCE, 1, 2, 16, 1, fi, 0, 0, 0, 0 }, { "out", OCV_CH_SINK, 2, 2, 16, 1, fi, 0, 0, 0, 0 } };
    ocv_dut_t dut = { "t", 0x1234ABCDu, 2, ch };
    FILE *null = fopen("/dev/null", "w");

    fake_setup(&f, 0x1234ABCDu);
    f.mem[((1u << 12) + (1u << 11)) / 4] = 0x600DDA7Au;             /* stimulus already loaded */
    CHECK(ocv_hub_info(&bus, &dut, null) == 0);
    CHECK(f.mem[((1u << 12) + (1u << 11)) / 4] == 0x600DDA7Au);     /* restored after the test */

    fake_setup(&f, 0x0BADF00Du);                                   /* image for another DUT */
    CHECK(ocv_hub_info(&bus, &dut, null) == 1);

    fake_setup(&f, 0x1234ABCDu);                                   /* PL clock not running */
    f.clock = 0;
    CHECK(ocv_hub_info(&bus, &dut, null) == 1);

    fake_setup(&f, 0x1234ABCDu);                                   /* a write that does not land */
    f.ro_off = (2u << 12) + OCV_EP_REG_THROTTLE;
    CHECK(ocv_hub_info(&bus, &dut, null) == 1);

    fake_setup(&f, 0x1234ABCDu);                                   /* source buffer not writable */
    f.ro_off = (1u << 12) + (1u << 11) + 15 * 8 + 4;               /* last record, word 1 */
    CHECK(ocv_hub_info(&bus, &dut, null) == 1);

    fake_setup(&f, 0x1234ABCDu);                                   /* two differences, both reported */
    f.mem[((2u << 12) + OCV_EP_REG_KIND) / 4] = OCV_EP_KIND_SOURCE;
    f.mem[((2u << 12) + OCV_EP_REG_GEOMETRY) / 4] = (11u << 24) | (1u << 16) | (5u << 8) | 2u;
    CHECK(ocv_hub_info(&bus, &dut, null) == 2);

    memset(&f, 0, sizeof f);                                       /* nothing at this address */
    CHECK(ocv_hub_info(&bus, &dut, null) == 1);
    fclose(null);
}

/* ---------------- squash signatures ---------------- */
/* bit-serial reference: what ocv_sink's crc_rec computes (reflected, LSB first, word 0 first) */
static uint32_t crc_ref(uint32_t crc, uint32_t w, uint32_t poly)
{
    for (int b = 0; b < 32; b++) crc = (crc >> 1) ^ (poly & (0u - ((crc ^ (w >> b)) & 1u)));
    return crc;
}

static void test_squash(void)
{
    uint64_t rng = 12345;
    const uint32_t mask[4] = { ~0u, 0xFFFF0000u, ~0u, 0x3Fu };
    uint32_t cc = ~0u, cz = ~0u, rc = ~0u, rz = ~0u;
    for (int i = 0; i < 1000; i++) {
        uint32_t rec[4];
        for (int j = 0; j < 4; j++) rec[j] = (uint32_t)ocv_rand(&rng);
        ocv_squash_add(&cc, &cz, rec, mask, 4);
        for (int j = 0; j < 4; j++) {
            rc = crc_ref(rc, rec[j] & mask[j], 0x82F63B78u);
            rz = crc_ref(rz, rec[j] & mask[j], 0xEDB88320u);
        }
    }
    CHECK(cc == rc);
    CHECK(cz == rz);
    /* the masked-out bits do not count */
    uint32_t a[4] = { 1, 0x1234, 3, 0x40 }, b[4] = { 1, 0x5678, 3, 0x80 };
    uint32_t ac = ~0u, az = ~0u, bc = ~0u, bz = ~0u;
    ocv_squash_add(&ac, &az, a, mask, 4);
    ocv_squash_add(&bc, &bz, b, mask, 4);
    CHECK(ac == bc && az == bz);
    ocv_channel_t c = { "c", OCV_CH_MONITOR, 1, 4, 16, 0, NULL, 1, 0, 0, 1 };
    CHECK(ocv_store_words(&c) == 7);
}

/* ---------------- DMA rings: setup, records out of PS memory, wrap, padding, tail ---------------- */
static int syncs;
static void fk_sync(ocv_bus_t *b, const void *p, size_t n) { (void)b; (void)p; (void)n; syncs++; }

static void test_ring(void)
{
    static fake_t f;
    static uint8_t mem[3 * 4096];
    fake_setup(&f, 0x1234ABCDu);
    uint32_t *sink = &f.mem[(2u << 12) / 4];
    sink[OCV_EP_REG_KIND / 4] = OCV_EP_KIND_SINK | OCV_KIND_LOSSLESS | OCV_KIND_DMA;
    sink[OCV_EP_REG_RING_LOG2 / 4] = (4u << 16) | (4u << 8);      /* 16-byte slots, 16-byte beats */
    /* the DMA memory starts off any alignment: setup aligns the ring inside it */
    ocv_bus_t bus = { fk_rd, fk_wr, &f, NULL, mem + 64, 0x10000040u, 2 * 4096, fk_sync };
    ocv_field_t fi[1] = { { "v", 0, 64, 0, OCV_CMP_EXACT, 0, 0 } };
    ocv_channel_t ch[2] = { { "in", OCV_CH_SOURCE, 1, 2, 16, 1, fi, 0, 0, 0, 0 }, { "out", OCV_CH_SINK, 2, 2, 16, 1, fi, 1, 0, 0, 0 } };
    ocv_dut_t dut = { "t", 0x1234ABCDu, 2, ch };
    ocv_env_t env;
    char err[256];
    sink[OCV_EP_REG_RING_LOG2 / 4] |= 5;                          /* a ring an earlier process left on */
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == 0);
    CHECK((sink[OCV_EP_REG_RING_LOG2 / 4] & 0x1Fu) == 0);          /* off at open */
    sink[OCV_EP_REG_RING_LOG2 / 4] = (4u << 16) | (4u << 8);      /* (the fake: bits 23:8 read-only in hardware) */
    CHECK(ocv_ring_setup(&env, 64) == 1);                          /* at most 64 bytes: 4 slots */
    CHECK(ocv_ring_on(&env, 1) && !ocv_ring_on(&env, 0));
    uint64_t pa = ((uint64_t)sink[OCV_EP_REG_RING_HI / 4] << 32) | sink[OCV_EP_REG_RING_LO / 4];
    CHECK(sink[OCV_EP_REG_RING_LOG2 / 4] == 2 && pa % 64 == 0 && pa >= 0x10000040u && pa + 64 <= 0x10000040u + 2 * 4096);
    uint8_t *ring = mem + 64 + (pa - 0x10000040u);
    /* the FPGA writes records k = 0..6 (2 words + 2 words of padding each) */
    uint32_t got[16 * 2], n;
    for (uint32_t k = 0; k < 3; k++) {
        uint32_t w[4] = { 0x100 + k, 0x200 + k, 0xEEEEEEEE, 0xEEEEEEEE };
        memcpy(ring + (k % 4) * 16, w, 16);
    }
    sink[OCV_EP_REG_RING_HEAD / 4] = 3;
    syncs = 0;
    n = ocv_ring_take(&env, 1, got, 16);
    CHECK(n == 3 && got[0] == 0x100 && got[1] == 0x200 && got[4] == 0x102 && got[5] == 0x202 && syncs == 1);
    CHECK(sink[OCV_EP_REG_RING_TAIL / 4] == 3 && ocv_ring_take(&env, 1, got, 16) == 0);
    for (uint32_t k = 3; k < 7; k++) {                           /* wraps after slot 3 */
        uint32_t w[4] = { 0x100 + k, 0x200 + k, 0, 0 };
        memcpy(ring + (k % 4) * 16, w, 16);
    }
    sink[OCV_EP_REG_RING_HEAD / 4] = 7;
    syncs = 0;
    n = ocv_ring_take(&env, 1, got, 2);                           /* at most 2 */
    CHECK(n == 2 && got[0] == 0x103 && got[2] == 0x104 && sink[OCV_EP_REG_RING_TAIL / 4] == 5);
    CHECK(syncs == 2);                                            /* slot 3, then slot 0: two pieces */
    n = ocv_ring_take(&env, 1, got, 16);
    CHECK(n == 2 && got[0] == 0x105 && got[3] == 0x206 && syncs == 3);   /* slots 1-2: one piece */
    sink[OCV_EP_REG_COUNT / 4] = 9;
    CHECK(ocv_ring_pending(&env, 1) == 2);
    ocv_ep_wr(&env, 1, OCV_EP_REG_CTRL, OCV_CTRL_ENABLE | OCV_CTRL_CLEAR);   /* a clear restarts it */
    CHECK(env.ep[1].tail == 0);
    /* no DMA memory: no ring, the bus path stays */
    ocv_env_close(&env);
    bus.dma_va = NULL;
    CHECK(ocv_env_open(&env, &bus, &dut, err, sizeof err) == 0 && ocv_ring_setup(&env, 0) == 0 && !ocv_ring_on(&env, 1));
    ocv_env_close(&env);
}

int main(void)
{
    test_fields();
    test_compare();
    test_env();
    test_info();
    test_block();
    test_word_masks();
    test_squash();
    test_ring();
    printf(failures ? "TEST_OCV: %d FAILURES\n" : "TEST_OCV: PASS\n", failures);
    return failures != 0;
}
