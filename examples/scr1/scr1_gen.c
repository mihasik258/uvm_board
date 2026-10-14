/* scr1_gen.c - random RV32IM test programs for SCR1, generated on the PS during the run, and aimed
 * at what the coverage (scr1_cov) has not seen yet.
 *
 * Same program shape as gen_random_prog.py: registers start from corner values, a block of random
 * operations (ALU, shifts, compares, multiply/divide, forward branches, loads/stores in a data
 * area, LUI/AUIPC) runs `loops` times, then the program jumps to SIM_EXIT. Directed mode replaces
 * part of the block with one operation per coverage bin not hit so far: its operands loaded with
 * values of the wanted classes, then the operation itself.
 *
 * Memory (scr1_ocv_dut): code at 0x200, data 0x8000..0x8FFF; x30 = loop counter, x31 = data base,
 * random operations use x1..x29.
 */
#include "scr1_gen.h"

#include <string.h>

enum { RESET = 0x200, DATA = 0x8000, DATA_BYTES = 0x1000, SIM_EXIT = 0xF8 };

static uint64_t rnd(uint64_t *s)
{
    uint64_t x = *s ? *s : 1;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    *s = x;
    return x * 0x2545F4914F6CDD1Dull;
}
static uint32_t range(uint64_t *s, uint32_t lo, uint32_t hi) { return lo + (uint32_t)(rnd(s) % (hi - lo + 1)); }

static uint32_t R(uint32_t f7, uint32_t rs2, uint32_t rs1, uint32_t f3, uint32_t rd)
{ return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x33; }
static uint32_t I(int32_t imm, uint32_t rs1, uint32_t f3, uint32_t rd, uint32_t op)
{ return (((uint32_t)imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op; }
static uint32_t S(int32_t imm, uint32_t rs2, uint32_t rs1, uint32_t f3)
{ uint32_t u = (uint32_t)imm; return (((u >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((u & 0x1F) << 7) | 0x23; }
static uint32_t B(int32_t imm, uint32_t rs2, uint32_t rs1, uint32_t f3)
{
    uint32_t u = (uint32_t)imm;
    return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12)
         | (((u >> 1) & 0xF) << 8) | (((u >> 11) & 1) << 7) | 0x63;
}
static uint32_t U(uint32_t imm, uint32_t rd, uint32_t op) { return (imm & 0xFFFFF000u) | (rd << 7) | op; }
static uint32_t J(int32_t imm, uint32_t rd)
{
    uint32_t u = (uint32_t)imm;
    return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3FF) << 21) | (((u >> 11) & 1) << 20) | (((u >> 12) & 0xFF) << 12)
         | (rd << 7) | 0x6F;
}

typedef struct { uint32_t *w; unsigned n, max; } code_t;
static void put(code_t *c, uint32_t w) { if (c->n < c->max) c->w[c->n] = w; c->n++; }
static void li(code_t *c, uint32_t rd, uint32_t v)
{
    int32_t lo = (int32_t)(v & 0xFFF);
    if (lo >= 0x800) lo -= 0x1000;
    put(c, U(v - (uint32_t)lo, rd, 0x37));
    put(c, I(lo, rd, 0, rd, 0x13));
}

static const uint32_t CORNERS[] = { 0, 1, 2, 0xFFFFFFFF, 0xFFFFFFFE, 0x7FFFFFFF, 0x80000000, 0x80000001, 0x0000FFFF,
                                    0xFFFF0000, 0x00008000, 0xFFFF8000, 0x55555555, 0xAAAAAAAA, 31, 32 };
#define NCORN (sizeof CORNERS / sizeof CORNERS[0])
static const uint32_t RTYPE[10][2] = { {0,0},{0x20,0},{0,1},{0,2},{0,3},{0,4},{0,5},{0x20,5},{0,6},{0,7} };
static const uint32_t ITYPE[6] = { 0, 2, 3, 4, 6, 7 };

static uint32_t reg(uint64_t *s) { return range(s, 1, 29); }
static uint32_t src(uint64_t *s) { uint32_t r = range(s, 0, 29); return r; }

/* one random operation (as gen_random_prog.py); returns how many following ops a branch skips */
static unsigned random_op(code_t *c, uint64_t *s, unsigned remaining)
{
    double k = (double)(rnd(s) % 10000) / 10000.0;
    if (k < 0.25) { const uint32_t *t = RTYPE[range(s, 0, 9)]; put(c, R(t[0], src(s), src(s), t[1], reg(s))); return 0; }
    if (k < 0.40) { put(c, R(1, src(s), src(s), range(s, 0, 7), reg(s))); return 0; }
    if (k < 0.55) {
        static const int32_t pick[5] = { 0, 1, -1, 2047, -2048 };
        uint32_t w = range(s, 0, 5);
        int32_t imm = w < 5 ? pick[w] : (int32_t)range(s, 0, 4095) - 2048;
        put(c, I(imm, src(s), ITYPE[range(s, 0, 5)], reg(s), 0x13));
        return 0;
    }
    if (k < 0.68) {
        static const uint32_t sh[3][2] = { {1,0},{5,0},{5,0x20} };
        const uint32_t *t = sh[range(s, 0, 2)];
        uint32_t w = range(s, 0, 3), amt = w == 0 ? 0 : w == 1 ? 1 : w == 2 ? 31 : range(s, 0, 31);
        put(c, I((int32_t)((t[1] << 5) | amt), src(s), t[0], reg(s), 0x13));
        return 0;
    }
    if (k < 0.78 && remaining > 5) {
        static const uint32_t f3s[6] = { 0, 1, 4, 5, 6, 7 };
        unsigned skip = range(s, 1, 4);
        put(c, B((int32_t)((skip + 1) * 4), src(s), src(s), f3s[range(s, 0, 5)]));
        return skip;
    }
    if (k < 0.86) {
        static const uint32_t ld[5][2] = { {0,1},{4,1},{1,2},{5,2},{2,4} };
        const uint32_t *t = ld[range(s, 0, 4)];
        put(c, I((int32_t)(range(s, 0, DATA_BYTES / t[1] - 1) * t[1]), 31, t[0], reg(s), 0x03));
        return 0;
    }
    if (k < 0.94) {
        static const uint32_t st[3][2] = { {0,1},{1,2},{2,4} };
        const uint32_t *t = st[range(s, 0, 2)];
        put(c, S((int32_t)(range(s, 0, DATA_BYTES / t[1] - 1) * t[1]), src(s), 31, t[0]));
        return 0;
    }
    put(c, U((uint32_t)rnd(s), reg(s), k < 0.97 ? 0x37 : 0x17));
    return 0;
}

static uint32_t value_of(int cls, uint64_t *s)
{
    switch (cls) {
    case COV_V_ZERO: return 0;
    case COV_V_ONE:  return 1;
    case COV_V_M1:   return 0xFFFFFFFFu;
    case COV_V_MIN:  return 0x80000000u;
    case COV_V_MAX:  return 0x7FFFFFFFu;
    case COV_V_POS:  return range(s, 2, 0x7FFFFFFE);
    default:         return range(s, 0x80000001u, 0xFFFFFFFEu);
    }
}

/* one operation aimed at bin b: operands loaded with the wanted classes, then the operation */
static void directed_op(code_t *c, const cov_bin_t *b, uint64_t *s)
{
    uint32_t ra = reg(s), rb = reg(s), rd = reg(s);
    while (rb == ra) rb = reg(s);
    switch (b->group) {
    case COV_G_ALU: {
        li(c, ra, value_of(b->c1, s)); li(c, rb, value_of(b->c2, s));
        const uint32_t *t = RTYPE[b->op];
        put(c, R(t[0], rb, ra, t[1], rd));
        break;
    }
    case COV_G_MUL:
        li(c, ra, value_of(b->c1, s)); li(c, rb, value_of(b->c2, s));
        put(c, R(1, rb, ra, (uint32_t)b->op, rd));
        break;
    case COV_G_ALUI: {
        static const int32_t fixed[3] = { 0, 1, -1 };
        int32_t imm = b->c2 < COV_I_POS ? fixed[b->c2] : b->c2 == COV_I_POS ? (int32_t)range(s, 2, 2047)
                                                                             : -(int32_t)range(s, 2, 2048);
        li(c, ra, value_of(b->c1, s));
        put(c, I(imm, ra, ITYPE[b->op], rd, 0x13));
        break;
    }
    case COV_G_SHI: {
        static const uint32_t sh[3][2] = { {1,0},{5,0},{5,0x20} };
        uint32_t amt = b->c2 == COV_S_ZERO ? 0 : b->c2 == COV_S_ONE ? 1 : b->c2 == COV_S_31 ? 31 : range(s, 2, 30);
        li(c, ra, value_of(b->c1, s));
        put(c, I((int32_t)((sh[b->op][1] << 5) | amt), ra, sh[b->op][0], rd, 0x13));
        break;
    }
    case COV_G_BR: {
        static const uint32_t f3s[6] = { 0, 1, 4, 5, 6, 7 };
        li(c, ra, value_of(b->c1, s)); li(c, rb, value_of(b->c2, s));
        put(c, B(8, rb, ra, f3s[b->op]));               /* taken: skips the next instruction */
        put(c, I((int32_t)range(s, 0, 100), rd, 0, rd, 0x13));
        break;
    }
    default:                                            /* loads/stores: the random mix covers them */
        random_op(c, s, 0);
        break;
    }
}

unsigned scr1_gen(uint8_t *image, unsigned image_bytes, uint64_t seed, unsigned ops, unsigned loops,
                  const cov_bin_t *aim, unsigned n_aim)
{
    static uint32_t words[(DATA - RESET) / 4];
    code_t c = { words, 0, (DATA - RESET) / 4 };
    uint64_t s = seed ^ 0x9E3779B97F4A7C15ull;
    for (uint32_t r = 1; r < 30; r++)
        li(&c, r, (rnd(&s) % 10 < 6) ? CORNERS[rnd(&s) % NCORN] : (uint32_t)rnd(&s));
    li(&c, 31, DATA);
    li(&c, 30, loops);
    unsigned loop_top = c.n, n = 0, next_aim = 0;
    /* aimed operations spread evenly through the block */
    unsigned every = n_aim ? (ops / n_aim ? ops / n_aim : 1) : 0;
    while (n < ops) {
        if (every && next_aim < n_aim && n % every == 0) {
            directed_op(&c, &aim[next_aim++], &s);
            n++;
            continue;
        }
        unsigned skip = random_op(&c, &s, ops - n);
        n++;
        for (unsigned k = 0; k < skip && n < ops; k++, n++) random_op(&c, &s, 0);   /* never a branch */
    }
    put(&c, I(-1, 30, 0, 30, 0x13));                                                /* addi x30,x30,-1 */
    put(&c, B(8, 0, 30, 0));                                                        /* beq x30,x0,+8   */
    put(&c, J((int32_t)(loop_top - c.n) * 4, 0));                                   /* jal x0,loop_top */
    li(&c, 5, SIM_EXIT);
    put(&c, I(0, 5, 0, 0, 0x67));                                                   /* jalr x0,0(x5)   */
    if (c.n > c.max || image_bytes < DATA + DATA_BYTES) return 0;
    memset(image, 0, image_bytes);
    for (unsigned i = 0; i < c.n; i++) memcpy(image + RESET + 4 * i, &words[i], 4);
    for (unsigned a = DATA; a < DATA + DATA_BYTES; a += 4) {
        uint32_t v = (rnd(&s) % 10 < 3) ? CORNERS[rnd(&s) % NCORN] : (uint32_t)rnd(&s);
        memcpy(image + a, &v, 4);
    }
    return c.n;
}
