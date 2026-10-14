/* cv32_gen.c - random test programs for CV32E40P in machine mode, generated on the PS during the run,
 * and aimed at what the coverage (cv32_cov) has not seen yet.
 *
 * The shape of examples/scr1/scr1_gen.c (registers from corner values, a block of random operations run
 * `loops` times, then a jump to SIM_EXIT), with what CV32E40P adds: CSR accesses, exceptions (ecall,
 * ebreak, illegal instructions of every kind) taken by a handler, compressed instructions, misaligned
 * loads and stores. Directed mode replaces part of the block with one operation per coverage bin not
 * hit so far.
 *
 * Memory (a core under gen/cpu_wrap.py with this map): a jump to the code at 0x80 (for a core that boots
 * there, as core-v-verif's), vector table at 0x100 (mtvec; 32 jumps to the
 * handler at 0x180), code at 0x200, data 0x8000..0x8FFF, the handler's save area 0xA0..0xAF; x30 = loop
 * counter, x31 = data base, random operations use x1..x29. The handler reads mcause and mepc into x28/x29
 * (so both are compared), steps mepc over an excepting instruction (2 or 4 bytes; an interrupt returns
 * where it came), returns with mret, and keeps x26..x29 (an interrupt may come anywhere). Interrupts:
 * the prologue enables all 19 lines and mstatus.MIE, and so does the block every 64 operations (random
 * CSR writes turn them off in between); the lines follow cv32_irq_schedule. Compressed instructions come in pairs (one 32-bit word), so a branch skips whole
 * words; a compressed jump or branch is the first of its pair and goes to the next word.
 */
#include "cv32_gen.h"

#include <string.h>

enum { BOOT = 0x80, HANDLER = 0x100, HANDLER_CODE = 0x180, SAVE = 0xA0, RESET = 0x200, DATA = 0x8000, DATA_BYTES = 0x1000,
       SIM_EXIT = 0xF8 };

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

static uint32_t CSR(uint32_t csr, uint32_t rs1, uint32_t f3, uint32_t rd) { return (csr << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73; }
static uint32_t pair(uint32_t lo, uint32_t hi) { return (lo & 0xFFFF) | (hi & 0xFFFF) << 16; }

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
static uint32_t creg(uint64_t *s) { return range(s, 8, 15); }      /* x8..x15: the registers of RVC's 3-bit fields */
static const uint32_t C_NOP = 0x0001;

/* ---- compressed instructions (RV32C) ---- */
static uint32_t c_ci(uint32_t f3, uint32_t rd, int32_t imm, uint32_t q)       /* c.addi c.li c.lui c.slli ... */
{ uint32_t u = (uint32_t)imm; return f3 << 13 | ((u >> 5) & 1) << 12 | rd << 7 | (u & 31) << 2 | q; }
static uint32_t c_arith(uint32_t k, uint32_t rd, uint32_t rs2)              /* c.sub c.xor c.or c.and */
{ return 4u << 13 | 3u << 10 | (rd - 8) << 7 | k << 5 | (rs2 - 8) << 2 | 1; }
static uint32_t c_shift(uint32_t k, uint32_t rd, uint32_t sh)               /* c.srli c.srai c.andi (k 0 1 2) */
{ return 4u << 13 | ((sh >> 5) & 1) << 12 | k << 10 | (rd - 8) << 7 | (sh & 31) << 2 | 1; }
static uint32_t c_cr(uint32_t b12, uint32_t rd, uint32_t rs2)               /* c.jr c.mv c.jalr c.add c.ebreak */
{ return 4u << 13 | b12 << 12 | rd << 7 | rs2 << 2 | 2; }
static uint32_t c_lw(uint32_t store, uint32_t r, uint32_t base, uint32_t off)  /* c.lw / c.sw, off 0..124 */
{ return (store ? 6u : 2u) << 13 | ((off >> 3) & 7) << 10 | (base - 8) << 7 | ((off >> 2) & 1) << 6 | ((off >> 6) & 1) << 5 | (r - 8) << 2; }
static uint32_t c_lwsp(uint32_t rd, uint32_t off)                           /* off 0..252 */
{ return 2u << 13 | ((off >> 5) & 1) << 12 | rd << 7 | ((off >> 2) & 7) << 4 | ((off >> 6) & 3) << 2 | 2; }
static uint32_t c_swsp(uint32_t rs2, uint32_t off)
{ return 6u << 13 | ((off >> 2) & 15) << 9 | ((off >> 6) & 3) << 7 | rs2 << 2 | 2; }
static uint32_t c_j(uint32_t f3, int32_t off)                               /* c.j / c.jal */
{
    uint32_t u = (uint32_t)off;
    return f3 << 13 | ((u >> 11) & 1) << 12 | ((u >> 4) & 1) << 11 | ((u >> 8) & 3) << 9 | ((u >> 10) & 1) << 8 |
           ((u >> 6) & 1) << 7 | ((u >> 7) & 1) << 6 | ((u >> 1) & 7) << 3 | ((u >> 5) & 1) << 2 | 1;
}
static uint32_t c_b(uint32_t bnez, uint32_t rs1, int32_t off)               /* c.beqz / c.bnez */
{
    uint32_t u = (uint32_t)off;
    return (bnez ? 7u : 6u) << 13 | ((u >> 8) & 1) << 12 | ((u >> 3) & 3) << 10 | (rs1 - 8) << 7 |
           ((u >> 6) & 3) << 5 | ((u >> 1) & 3) << 3 | ((u >> 5) & 1) << 2 | 1;
}
static uint32_t c_addi4spn(uint32_t rd, uint32_t nzuimm)                    /* nzuimm 4..1020, multiple of 4 */
{ return ((nzuimm >> 4) & 3) << 11 | ((nzuimm >> 6) & 15) << 7 | ((nzuimm >> 2) & 1) << 6 | ((nzuimm >> 3) & 1) << 5 | (rd - 8) << 2; }
static uint32_t c_addi16sp(int32_t imm)                                     /* imm multiple of 16, not 0 */
{
    uint32_t u = (uint32_t)imm;
    return 3u << 13 | ((u >> 9) & 1) << 12 | 2u << 7 | ((u >> 4) & 1) << 6 | ((u >> 6) & 1) << 5 | ((u >> 7) & 3) << 3 |
           ((u >> 5) & 1) << 2 | 1;
}

static int32_t nz6(uint64_t *s) { int32_t v = (int32_t)range(s, 1, 63) - 32; return v ? v : 1; }

/* one compressed form (COV_C_*) as one word; a jump or branch goes to the next word */
static void compressed(code_t *c, int k, uint64_t *s)
{
    const uint32_t r = reg(s), a = creg(s), b = creg(s);
    switch (k) {
    case COV_C_ADDI4SPN: put(c, pair(c_addi4spn(a, range(s, 1, 255) * 4), C_NOP)); break;
    case COV_C_LW: case COV_C_SW:                  /* x15 = data base for the pair */
        put(c, I(0, 31, 0, 15, 0x13));
        put(c, pair(c_lw(k == COV_C_SW, a == 15 ? 9 : a, 15, range(s, 0, 31) * 4), c_lw(1, b, 15, range(s, 0, 31) * 4)));
        break;
    case COV_C_NOP:   put(c, pair(C_NOP, C_NOP)); break;
    case COV_C_ADDI:  put(c, pair(c_ci(0, r, nz6(s), 1), c_ci(0, reg(s), nz6(s), 1))); break;
    case COV_C_JAL:   put(c, pair(c_j(1, 4), C_NOP)); break;
    case COV_C_LI:    put(c, pair(c_ci(2, r, (int32_t)range(s, 0, 63) - 32, 1), C_NOP)); break;
    case COV_C_ADDI16SP: { int32_t v = (int32_t)range(s, 1, 31) - 16; put(c, pair(c_addi16sp((v ? v : 1) * 16), C_NOP)); break; }
    case COV_C_LUI: { uint32_t rd = r == 2 ? 3 : r; put(c, pair(c_ci(3, rd, nz6(s), 1), C_NOP)); break; }
    case COV_C_SRLI: case COV_C_SRAI: case COV_C_ANDI:
        put(c, pair(c_shift((uint32_t)(k - COV_C_SRLI), a, k == COV_C_ANDI ? (uint32_t)(range(s, 0, 63)) : range(s, 1, 31)), C_NOP));
        break;
    case COV_C_SUB: case COV_C_XOR: case COV_C_OR: case COV_C_AND:
        put(c, pair(c_arith((uint32_t)(k - COV_C_SUB), a, b), c_arith(range(s, 0, 3), creg(s), creg(s))));
        break;
    case COV_C_J:     put(c, pair(c_j(5, 4), C_NOP)); break;
    case COV_C_BEQZ: case COV_C_BNEZ: put(c, pair(c_b(k == COV_C_BNEZ, a, 4), c_ci(0, b, nz6(s), 1))); break;
    case COV_C_SLLI:  put(c, pair(c_ci(0, r, (int32_t)range(s, 1, 31), 2), C_NOP)); break;
    case COV_C_LWSP: case COV_C_SWSP:              /* sp = data base */
        put(c, I(0, 31, 0, 2, 0x13));
        put(c, pair(k == COV_C_LWSP ? c_lwsp(r == 2 ? 3 : r, range(s, 0, 63) * 4) : c_swsp(r, range(s, 0, 63) * 4), C_NOP));
        break;
    case COV_C_JR: case COV_C_JALR: {              /* x5 = the next word after the pair */
        put(c, U(0, 5, 0x17));                     /* auipc x5, 0 */
        put(c, I(12, 5, 0, 5, 0x13));              /* addi x5, x5, 12 */
        put(c, pair(c_cr(k == COV_C_JALR, 5, 0), C_NOP));
        break;
    }
    case COV_C_MV:    put(c, pair(c_cr(0, r, reg(s)), C_NOP)); break;
    case COV_C_ADD:   put(c, pair(c_cr(1, r, reg(s)), C_NOP)); break;
    default:          put(c, pair(c_cr(1, 0, 0), C_NOP)); break;        /* c.ebreak */
    }
}

/* one compressed form that is a single word and no control flow (inside a branch's skip) */
static void compressed_word(code_t *c, uint64_t *s)
{
    static const int k[] = { COV_C_ADDI4SPN, COV_C_NOP, COV_C_ADDI, COV_C_LI, COV_C_ADDI16SP, COV_C_LUI, COV_C_SRLI,
                             COV_C_SRAI, COV_C_ANDI, COV_C_SUB, COV_C_XOR, COV_C_OR, COV_C_AND, COV_C_SLLI, COV_C_MV,
                             COV_C_ADD, COV_C_EBREAK };
    compressed(c, k[range(s, 0, sizeof k / sizeof k[0] - 1)], s);
}

/* ---- CSR accesses, exceptions, misaligned accesses ---- */
static const uint32_t BAD_CSR_CV32[] = { 0x001, 0x002, 0x003, 0x306, 0x7B0, 0x7B1, 0x7B2, 0x3A0, 0x3B0, 0x000, 0x800,
                                         0xCC0, 0xB01, 0xC01 };
/* CVA6 (cv32a60x): no F, U, S, debug, triggers, user counters; pmpcfg/pmpaddr exist (no entries) */
static const uint32_t BAD_CSR_CVA6[] = { 0x001, 0x002, 0x003, 0x306, 0x30A, 0x7B0, 0x7B1, 0x7B2, 0x7A0, 0x7A1, 0x000,
                                         0x800, 0xCC0, 0xB01, 0xC01, 0xC00, 0xC02, 0x180, 0x100 };
static int gen_cva6;
void cv32_gen_profile(int core) { gen_cva6 = core == 1; cov_profile(core); }

/* a CSR access: op (0..5 = rw rs rc rwi rsi rci), the CSR, source zero or not; mtvec keeps its base (traps) */
static void csr_op(code_t *c, uint32_t op, uint32_t csr, int src_nz, uint64_t *s)
{
    static const uint32_t f3[6] = { 1, 2, 3, 5, 6, 7 };
    const uint32_t imm = op >= 3, rd = reg(s);
    uint32_t src = src_nz ? (imm ? range(s, 1, 31) : reg(s)) : 0;
    if (csr == 0x305 && (op == 0 || op == 3 || src)) {   /* a write of mtvec: then the handler's address again */
        put(c, CSR(0x300, 8, 7, 27));                    /* csrrci x27, mstatus, MIE: no interrupt meanwhile */
        put(c, CSR(csr, src, f3[op], rd));
        li(c, 26, HANDLER | (uint32_t)(rnd(s) & 1));
        put(c, CSR(csr, 26, 1, 0));
        put(c, CSR(0x300, 27, 1, 0));                    /* csrw mstatus, x27 */
        return;
    }
    put(c, CSR(csr, src, f3[op], rd));
}

/* an exception (COV_X_*) as one word, the handler returns to the next */
static void exception(code_t *c, int k, uint64_t *s)
{
    switch (k) {
    case COV_X_ECALL:   put(c, 0x00000073u); break;
    case COV_X_EBREAK:  put(c, 0x00100073u); break;
    case COV_X_CEBREAK: put(c, pair(c_cr(1, 0, 0), C_NOP)); break;
    case COV_X_ONES:    put(c, 0xFFFFFFFFu); break;
    case COV_X_LOAD:    put(c, I(0, 31, range(s, 0, 1) ? 3 : range(s, 6, 7), reg(s), 0x03)); break;
    case COV_X_STORE:   put(c, S(0, reg(s), 31, range(s, 3, 7))); break;
    case COV_X_SHIFT:   put(c, I((int32_t)(range(s, 1, 0x7F) << 5 | range(s, 0, 31)), reg(s), 1, reg(s), 0x13)); break;
    case COV_X_OP:      put(c, R(range(s, 2, 0x1F), reg(s), reg(s), range(s, 0, 7), reg(s))); break;
    case COV_X_JALR:    put(c, I(0, 5, range(s, 1, 7), 0, 0x67)); break;
    case COV_X_BRANCH:  put(c, B(8, reg(s), reg(s), range(s, 2, 3))); break;
    case COV_X_FENCE:   put(c, I(0, 0, range(s, 2, 7), 0, 0x0f)); break;
    case COV_X_SYS4:    put(c, CSR(0x340, reg(s), 4, reg(s))); break;
    case COV_X_URET:    put(c, 0x00200073u); break;
    case COV_X_DRET:    put(c, 0x7B200073u); break;
    case COV_X_CSR:     csr_op(c, range(s, 0, 5), gen_cva6 ? BAD_CSR_CVA6[range(s, 0, sizeof BAD_CSR_CVA6 / 4 - 1)]
                                                           : BAD_CSR_CV32[range(s, 0, sizeof BAD_CSR_CV32 / 4 - 1)],
                               (int)range(s, 0, 1), s); break;
    case COV_X_CSR_RO:  csr_op(c, range(s, 0, 1) ? 0 : 3, 0xF11 + range(s, 0, 3), 1, s); break;
    case COV_X_CUSTOM:  { static const uint32_t o[] = { 0x0B, 0x2B, 0x5B, 0x7B, 0x07, 0x27, 0x43, 0x53, 0x57 };
                          put(c, (uint32_t)(rnd(s) & ~0x7Fu) | o[range(s, 0, 8)]); break; }
    case COV_X_AMO:     put(c, R(range(s, 0, 0x7F), reg(s), 31, 2, reg(s)) ^ 0x33u ^ 0x2Fu); break;
    case COV_X_C0:      put(c, pair(0x0000, C_NOP)); break;
    default:            put(c, 0x00000073u); break;    /* mret: by the handler */
    }
}

/* a misaligned access (COV_M_*) in the data area */
static void misaligned(code_t *c, int k, uint64_t *s)
{
    static const uint32_t f3[COV_NM] = { 1, 1, 5, 5, 2, 2, 2, 1, 1, 2, 2, 2 };
    static const uint32_t off[COV_NM] = { 1, 3, 1, 3, 1, 2, 3, 1, 3, 1, 2, 3 };
    const int32_t a = (int32_t)(range(s, 0, DATA_BYTES / 4 - 2) * 4 + off[k]);
    if (k >= COV_M_SH1) put(c, S(a, reg(s), 31, f3[k]));
    else put(c, I(a, 31, f3[k], reg(s), 0x03));
}
static uint32_t src(uint64_t *s) { uint32_t r = range(s, 0, 29); return r; }

/* one random operation (as gen_random_prog.py, and CV32E40P's additions); returns how many following
 * ops a branch skips; with remaining = 0 (inside a skip) it is one word and no control flow */
static unsigned random_op(code_t *c, uint64_t *s, unsigned remaining)
{
    double k = (double)(rnd(s) % 10000) / 10000.0;
    if (k < 0.20) {                                /* CV32E40P: 20% of the mix */
        if (k < 0.06) {
            const uint32_t csr = cov_csrs[range(s, 0, COV_NCSR - 1)];
            if (csr == 0x305 && remaining == 0) { put(c, CSR(csr, 0, 2, reg(s))); return 0; }   /* read mtvec */
            csr_op(c, range(s, 0, 5), csr, (int)range(s, 0, 1), s);
        } else if (k < 0.09) {
            int x = (int)range(s, 0, COV_NX - 1);
            exception(c, x == COV_X_MRET ? COV_X_ECALL : x, s);   /* (mret: the handler's) */
            if (remaining == 0) return 0;
        } else if (k < 0.16) {
            if (remaining == 0) compressed_word(c, s); else compressed(c, (int)range(s, 0, COV_NC - 1), s);
        } else {
            misaligned(c, (int)range(s, 0, COV_NM - 1), s);
        }
        return 0;
    }
    k = (k - 0.20) / 0.80;
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
    case COV_G_CSR: {
        const uint32_t csr = cov_csrs[b->c1];
        if (b->c2 && b->op < 3) li(c, ra, value_of(range(s, 0, COV_NV - 1), s));
        static const uint32_t f3[6] = { 1, 2, 3, 5, 6, 7 };
        const uint32_t src = b->c2 ? (b->op >= 3 ? range(s, 1, 31) : ra) : 0;
        if (csr == 0x305 && (b->op == 0 || b->op == 3 || src)) {
            put(c, CSR(0x300, 8, 7, 27));
            put(c, CSR(csr, src, f3[b->op], rd));
            li(c, 26, HANDLER);
            put(c, CSR(csr, 26, 1, 0));
            put(c, CSR(0x300, 27, 1, 0));
        } else {
            put(c, CSR(csr, src, f3[b->op], rd));
        }
        break;
    }
    case COV_G_EXC:  if (b->op != COV_X_MRET) exception(c, b->op, s); break;   /* mret: every exception */
    case COV_G_RVC:  compressed(c, b->op, s); break;
    case COV_G_MIS:  misaligned(c, b->op, s); break;
    default:                                            /* loads/stores: the random mix covers them */
        random_op(c, s, 0);
        break;
    }
}

/* the vector table at HANDLER (32 jumps) and the handler at HANDLER_CODE: x26..x29 saved, mcause and mepc
 * into x28/x29, mepc past an excepting instruction, x26..x29 back, mret */
static unsigned handler(uint32_t *w)
{
    code_t c = { w, 0, 64 };
    for (unsigned i = 0; i < 32; i++) put(&c, J((int32_t)(HANDLER_CODE - HANDLER - 4 * i), 0));
    for (unsigned r = 26; r <= 29; r++) put(&c, S((int32_t)(SAVE + 4 * (r - 26)), r, 0, 2));    /* sw xr, save */
    put(&c, CSR(0x342, 0, 2, 28));                 /* csrr  x28, mcause */
    put(&c, CSR(0x341, 0, 2, 29));                 /* csrr  x29, mepc */
    put(&c, B(32, 0, 28, 4));                      /* blt   x28, x0, +32: an interrupt returns where it came */
    put(&c, I(0, 29, 5, 27, 0x03));                /* lhu   x27, 0(x29) */
    put(&c, I(3, 27, 7, 27, 0x13));                /* andi  x27, x27, 3 */
    put(&c, I(2, 29, 0, 29, 0x13));                /* addi  x29, x29, 2 */
    put(&c, I(3, 0, 0, 26, 0x13));                 /* addi  x26, x0, 3 */
    put(&c, B(8, 26, 27, 1));                      /* bne   x27, x26, +8: compressed */
    put(&c, I(2, 29, 0, 29, 0x13));                /* addi  x29, x29, 2 */
    put(&c, CSR(0x341, 29, 1, 0));                 /* csrw  mepc, x29 */
    for (unsigned r = 26; r <= 29; r++) put(&c, I((int32_t)(SAVE + 4 * (r - 26)), 0, 2, r, 0x03));   /* lw */
    put(&c, 0x30200073u);                          /* mret */
    return c.n;
}

static uint32_t end_store;
void cv32_gen_end(uint32_t store_addr) { end_store = store_addr; }

int cv32_irq_schedule(uint64_t seed, unsigned k, uint32_t aim, uint64_t *until, uint32_t *value)
{
    enum { PULSES = 120 };
    static const uint8_t ids[19] = { 3, 7, 11, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
    uint8_t want[19];
    unsigned nw = 0;
    for (unsigned i = 0; i < 19; i++) if (aim >> ids[i] & 1) want[nw++] = ids[i];
    if (k > 2 * PULSES) return 0;
    if (k == 2 * PULSES) { *until = ~0ull; *value = 0; return 1; }    /* quiet for ever */
    uint64_t s = seed ^ 0xC2B2AE3D27D4EB4Full, t = 0;
    uint32_t v = 0;
    for (unsigned i = 0; i <= k; i++) {            /* gaps and pulses, the same from the same seed */
        if (i % 2 == 0) { t += range(&s, 100, 3000); v = 0; }                     /* lines low */
        else {
            const unsigned pick = nw && range(&s, 0, 3) ? want[range(&s, 0, nw - 1)] : ids[range(&s, 0, 18)];
            v = 1u << pick;
            if (range(&s, 0, 3) == 0) v |= 1u << ids[range(&s, 0, 18)];         /* two at once */
            t += range(&s, 1, 300);                                               /* held this long */
        }
    }
    *until = t;
    *value = v;
    return 1;
}

unsigned cv32_gen(uint8_t *image, unsigned image_bytes, uint64_t seed, unsigned ops, unsigned loops,
                  const cov_bin_t *aim, unsigned n_aim)
{
    static uint32_t words[(DATA - RESET) / 4];
    code_t c = { words, 0, (DATA - RESET) / 4 };
    uint64_t s = seed ^ 0x9E3779B97F4A7C15ull;
    for (uint32_t r = 1; r < 30; r++)
        li(&c, r, (rnd(&s) % 10 < 6) ? CORNERS[rnd(&s) % NCORN] : (uint32_t)rnd(&s));
    li(&c, 26, HANDLER);
    put(&c, CSR(0x305, 26, 1, 0));                                                  /* csrw mtvec, x26 */
    li(&c, 26, 0xFFFF0888u);
    put(&c, CSR(0x304, 26, 1, 0));                                                  /* csrw mie: all lines */
    put(&c, CSR(0x300, 8, 6, 0));                                                   /* csrsi mstatus, MIE */
    li(&c, 31, DATA);
    li(&c, 30, loops);
    unsigned loop_top = c.n, n = 0, next_aim = 0;
    /* aimed operations spread evenly through the block */
    unsigned every = n_aim ? (ops / n_aim ? ops / n_aim : 1) : 0;
    while (n < ops) {
        if (n % 64 == 0) {                         /* interrupts back on now and then (random CSR writes turn them off) */
            li(&c, 26, 0xFFFF0888u);
            put(&c, CSR(0x304, 26, 2, 0));         /* csrs mie, x26 */
            put(&c, CSR(0x300, 8, 6, 0));          /* csrsi mstatus, MIE */
        }
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
    put(&c, CSR(0x300, 8, 7, 0));                                                   /* csrci mstatus, MIE: */
    if (end_store) {                                                                /* no interrupt at the end */
        li(&c, 5, end_store);
        put(&c, S(0, 0, 5, 2));                                                     /* sw x0, 0(x5): the end */
        put(&c, J(0, 0));                                                           /* j .             */
    } else {
        li(&c, 5, SIM_EXIT);
        put(&c, I(0, 5, 0, 0, 0x67));                                               /* jalr x0,0(x5)   */
    }
    if (c.n > c.max || image_bytes < DATA + DATA_BYTES) return 0;
    memset(image, 0, image_bytes);
    for (unsigned i = 0; i < c.n; i++) memcpy(image + RESET + 4 * i, &words[i], 4);
    uint32_t hw[64];
    unsigned nh = handler(hw);
    for (unsigned i = 0; i < nh; i++) memcpy(image + HANDLER + 4 * i, &hw[i], 4);
    const uint32_t boot = J(RESET - BOOT, 0);                   /* a core that starts at 0x80: on to the code */
    memcpy(image + BOOT, &boot, 4);
    for (unsigned a = DATA; a < DATA + DATA_BYTES; a += 4) {
        uint32_t v = (rnd(&s) % 10 < 3) ? CORNERS[rnd(&s) % NCORN] : (uint32_t)rnd(&s);
        memcpy(image + a, &v, 4);
    }
    return c.n;
}
