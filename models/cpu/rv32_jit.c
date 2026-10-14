/* rv32_jit.c - "jit": the light ISS ("iss"/"fast" semantics) translated block by block into AArch64
 * code, for the board (Cortex-A72). Built as a part of cpu_model.c on aarch64 only.
 *
 * A block is a run of instructions from a pc up to the first branch/jump (included), at most 64. The
 * model still retires one instruction per cpu_step: a block runs at once and leaves per instruction
 * what changes at run time (result, next pc of a branch, store address and data) in a buffer; cpu_step
 * hands the retirements out one by one, the static part (pc, instruction, rd) from the block's table.
 *
 * Never ahead of the testbench: a block stops before a CSR instruction (a counter the testbench hands
 * in before that step), before ecall/ebreak/illegal, and - checked in the generated code - before a
 * load or store outside the memory regions (device registers): those instructions are executed by
 * the "fast" interpreter at their own step, on the same state. A store into a page holding translated
 * code ends the block after it and drops the translations (self-modifying code).
 *
 * Checked against "iss" retirement by retirement (models/cpu/t_fast.c with "jit", under qemu-aarch64 on
 * the PC, and on the board).
 */
#if defined(__aarch64__)
#include <stddef.h>
#include <sys/mman.h>

#define JIT_MAX     64              /* instructions per block */
#define JIT_CODE    (16u << 20)     /* code buffer */
#define JIT_PAGE    4               /* code-map granule: 16 bytes (256 put the generator's trap save area at
                                     * 0xA0 in one granule with the code at 0x80: a flush on every trap) */

typedef struct { uint32_t wdata, next, maddr, mdata; } jout_t;

typedef struct {
    uint32_t pc, insn, next;               /* next: pc of the next instruction unless dyn_next */
    uint32_t m_next, m_rd, m_store;        /* all ones: take that value from the block's output */
    uint8_t  rd, len, store, dyn_next;     /* rd 0: no register written; store: bytes (0: none) */
} jins_t;

typedef struct jblock {
    int (*fn)(void *state, jout_t *out);
    uint32_t n;                            /* instructions translated (0: the first one is not) */
    jins_t  *ins;                          /* in the pool */
} jblock_t;

#define JIT_BLOCKS  (1u << 16)
#define JIT_POOL    (1u << 19)             /* jins_t entries */

typedef struct {
    fast_t     f;                          /* registers, pc, order, regions: shared with "fast" */
    jblock_t **map[8];                     /* per region: block by (pc - base) / 2 */
    uint8_t   *code_map[8];                /* per region: a 256-byte page holds translated code */
    uint8_t   *hits[8];                    /* per region: entries at a pc not translated yet (see hot) */
    uint32_t   hot;                        /* translate a block on its hot-th entry (OCV_JIT_HOT, default 3):
                                            * code run once (generated straight-line tests) stays in the
                                            * interpreter - translating it costs more than it saves */
    uint8_t   *code, *code_end, *code_cur;
    jblock_t  *blocks; uint32_t nblocks;
    jins_t    *pool; uint32_t npool;
    jout_t     out[JIT_MAX];
    jins_t     keep[JIT_MAX];              /* the running block's table when the translations go */
    const jins_t *cur; uint32_t cur_n, cur_i;
    uint64_t   cur_order;
    uint32_t   x0[32];                     /* registers before the running block (cpu_xreg inside it) */
    uint64_t   single;                     /* cpu_sync: instructions still to run one by one */
    int        smc;                        /* a store hit translated code */
    uint64_t   n_blocks, n_trans, n_flush, n_interp, n_cold;   /* OCV_JIT_STATS: printed at the end */
    /* for the generated code: [x19 + JIT_OFF_*] */
    uint8_t   *host[2]; uint64_t base[2], size[2]; uint8_t *cmap[2];
} jit_t;

/* ---------------------------------------------------------------- AArch64 encoder */
typedef struct { uint32_t *p, *end; int ok; } em_t;
static void emit(em_t *e, uint32_t w) { if (e->p < e->end) *e->p++ = w; else e->ok = 0; }

enum { W0 = 0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, XO = 14, XS = 15, XZR = 31 };   /* x15: jit_t, x14: out */

static void movw(em_t *e, int rd, uint32_t v)                  /* 32-bit constant */
{
    emit(e, 0x52800000u | ((v & 0xFFFF) << 5) | rd);           /* movz wd, #lo */
    if (v >> 16) emit(e, 0x72A00000u | ((v >> 16) << 5) | rd); /* movk wd, #hi, lsl 16 */
}
static void ldr_w(em_t *e, int rt, int rn, uint32_t off) { emit(e, 0xB9400000u | ((off / 4) << 10) | (rn << 5) | rt); }
static void str_w(em_t *e, int rt, int rn, uint32_t off) { emit(e, 0xB9000000u | ((off / 4) << 10) | (rn << 5) | rt); }
static void ldr_x(em_t *e, int rt, int rn, uint32_t off) { emit(e, 0xF9400000u | ((off / 8) << 10) | (rn << 5) | rt); }

#define OFF_X     offsetof(jit_t, f.x)
#define OFF_PC    offsetof(jit_t, f.pc)
#define OFF_SMC   offsetof(jit_t, smc)
#define OFF_HOST  offsetof(jit_t, host)
#define OFF_BASE  offsetof(jit_t, base)
#define OFF_SIZE  offsetof(jit_t, size)
#define OFF_CMAP  offsetof(jit_t, cmap)

/* guest register into a host register (x0 reads 0) */
static int greg(em_t *e, int host, int g)
{
    if (!g) return XZR;
    ldr_w(e, host, XS, (uint32_t)OFF_X + 4u * (uint32_t)g);
    return host;
}
static void dp3(em_t *e, uint32_t op, int rd, int rn, int rm) { emit(e, op | (rm << 16) | (rn << 5) | rd); }

#define ADDW  0x0B000000u
#define SUBW  0x4B000000u
#define ANDW  0x0A000000u
#define ORRW  0x2A000000u
#define EORW  0x4A000000u
#define LSLV  0x1AC02000u
#define LSRV  0x1AC02400u
#define ASRV  0x1AC02800u
#define MULW  0x1B007C00u
#define SDIVW 0x1AC00C00u
#define UDIVW 0x1AC00800u
#define SUBSW 0x6B000000u

static void cset(em_t *e, int rd, int cond) { emit(e, 0x1A9F07E0u | ((cond ^ 1) << 12) | rd); }  /* csinc wd, wzr, wzr, !cond */
enum { EQ = 0, NE = 1, HS = 2, LO = 3, HI = 8, LS = 9, GE = 10, LT = 11 };

/* ---------------------------------------------------------------- translation */

/* exit before instruction k (not executed): pc = its pc, return k */
static void exit_before(em_t *e, uint32_t pc, uint32_t k)
{
    movw(e, W9, pc); str_w(e, W9, XS, OFF_PC);
    movw(e, W0, k);
    emit(e, 0xD65F03C0u);           /* ret */
}

/* a memory access at w3 (guest address), n bytes: x4 = host pointer, or out to `miss` (patched later) */
static uint32_t *mem_check(em_t *e, int n, uint32_t **miss_slot)
{
    /* region 0: x5 = addr - base0; ok if x5 + n <= size0 */
    ldr_x(e, 5, XS, OFF_BASE);                      /* x5 = base0 */
    emit(e, 0x4B050065u);                           /* sub w5, w3, w5: offset, huge if below */
    ldr_x(e, 6, XS, OFF_SIZE);                      /* x6 = size0 */
    emit(e, 0x910000A7u | ((uint32_t)n << 10));     /* add x7, x5, #n */
    emit(e, 0xEB0600FFu);                           /* cmp x7, x6 */
    uint32_t *b1 = e->p; emit(e, 0x54000008u);      /* b.hi region1 (patched) */
    ldr_x(e, 4, XS, OFF_HOST);                      /* x4 = host0 + x5 */
    emit(e, 0x8B050084u);                           /* add x4, x4, x5 */
    ldr_x(e, 8, XS, OFF_CMAP);                      /* x8 = code map 0 */
    uint32_t *b_ok = e->p; emit(e, 0x14000000u);    /* b ok (patched) */
    /* region 1 */
    uint32_t *r1 = e->p;
    *b1 = 0x54000008u | ((uint32_t)((r1 - b1) & 0x7FFFF) << 5);
    ldr_x(e, 5, XS, OFF_BASE + 8);
    emit(e, 0x4B050065u);
    ldr_x(e, 6, XS, OFF_SIZE + 8);
    emit(e, 0x910000A7u | ((uint32_t)n << 10));
    emit(e, 0xEB0600FFu);
    *miss_slot = e->p; emit(e, 0x54000008u);        /* b.hi miss (patched by the caller) */
    ldr_x(e, 4, XS, OFF_HOST + 8);
    emit(e, 0x8B050084u);
    ldr_x(e, 8, XS, OFF_CMAP + 8);
    uint32_t *ok = e->p;
    *b_ok = 0x14000000u | (uint32_t)((ok - b_ok) & 0x3FFFFFF);
    return ok;
}
static void patch_bcond(uint32_t *at, uint32_t *to) { *at = (*at & 0xFF00001Fu) | ((uint32_t)((to - at) & 0x7FFFF) << 5); }

/* core profile cva6: a misaligned access traps - leave before it (the interpreter takes the exception) */
static void misaligned_exit(em_t *e, const jit_t *j, int n, uint32_t k, uint32_t **patches, uint32_t *target,
                            int *np)
{
    if (!j->f.cva6 || n == 1) return;
    emit(e, n == 2 ? 0x7200007Fu : 0x7200047Fu);   /* tst w3, #1 / #3 */
    patches[*np] = e->p; target[(*np)++] = k;
    emit(e, 0x54000001u);                           /* b.ne miss (patched with the others) */
}

static int translatable(const dec_t *d)
{
    return d->op != OP_CSR && d->op != OP_SYSTEM_TRAP && d->op != OP_ILLEGAL;
}
static int ends_block(const dec_t *d)
{
    return d->op == OP_JAL || d->op == OP_JALR || (d->op >= OP_BEQ && d->op <= OP_BGEU);
}

/* bytes [a, a+n) hold decoded instructions: a store from 3 bytes before up to the end drops them */
static void mark_code(jit_t *j, uint32_t a, uint32_t n)
{
    fregion_t *r = region_of(&j->f, a, 1);
    if (!r) return;
    const int ri = (int)(r - j->f.reg);
    uint32_t lo = a - r->base, hi = lo + n - 1;
    lo = lo >= 3 ? lo - 3 : 0;
    if (hi >= r->size) hi = r->size - 1;
    for (uint32_t pg = lo >> JIT_PAGE; pg <= hi >> JIT_PAGE; pg++) j->code_map[ri][pg] = 1;
}
static int is_code(jit_t *j, uint32_t a, uint32_t n)
{
    fregion_t *r = region_of(&j->f, a, n);
    if (!r) return 0;
    const int ri = (int)(r - j->f.reg);
    const uint32_t o = a - r->base;
    return j->code_map[ri][o >> JIT_PAGE] | j->code_map[ri][(o + n - 1) >> JIT_PAGE];
}

static jblock_t *translate(jit_t *j, uint32_t pc)
{
    if (j->nblocks == JIT_BLOCKS || j->npool + JIT_MAX > JIT_POOL || j->code_end - j->code_cur < 64 * 1024)
        return NULL;                                              /* full: the caller flushes */
    jblock_t *b = &j->blocks[j->nblocks++];
    b->ins = &j->pool[j->npool];
    b->n = 0; b->fn = NULL;
    em_t e = { (uint32_t *)j->code_cur, (uint32_t *)j->code_end, 1 };
    uint32_t *start = e.p;
    emit(&e, 0xAA0003EFu);              /* mov x15, x0: jit_t */
    emit(&e, 0xAA0103EEu);              /* mov x14, x1: out */
    uint32_t *miss_patches[2 * JIT_MAX], miss_target[2 * JIT_MAX];   /* region miss; cva6: misaligned */
    int nmiss = 0;
    uint32_t p = pc;
    fregion_t *creg = region_of(&j->f, pc, 2);
    for (uint32_t k = 0; k < JIT_MAX && e.ok; k++) {
        dec_t tmp;
        const dec_t *d = fetch(&j->f, p, &tmp);
        mark_code(j, p, d->len);
        if (!translatable(d) || region_of(&j->f, p, d->len) != creg) break;   /* (code within one region) */
        jins_t *I = &b->ins[k];
        I->pc = p; I->insn = d->insn; I->len = d->len; I->store = 0; I->dyn_next = 0;
        I->next = d->op == OP_JAL ? p + (uint32_t)d->imm : p + d->len;
        I->rd = (d->rd && d->op != OP_SB && d->op != OP_SH && d->op != OP_SW && d->op != OP_SNONE &&
                 !(d->op >= OP_BEQ && d->op <= OP_BGEU) && d->op != OP_FENCE) ? d->rd : 0;
        const uint32_t ob = 16u * k;                              /* this instruction's jout_t */
        int ra, rb, wr = 1;                                       /* wr: w2 holds the result for rd */
        switch (d->op) {
        case OP_LUI:   movw(&e, W2, (uint32_t)d->imm); break;
        case OP_AUIPC: movw(&e, W2, p + (uint32_t)d->imm); break;
        case OP_JAL:   movw(&e, W2, p + d->len); break;
        case OP_JALR:
            ra = greg(&e, W0, d->rs1);
            movw(&e, W1, (uint32_t)d->imm); dp3(&e, ADDW, W9, ra, W1);
            emit(&e, 0x121F7929u);                                /* and w9, w9, #~1 */
            movw(&e, W2, p + d->len);
            I->dyn_next = 1;
            break;
        case OP_BEQ: case OP_BNE: case OP_BLT: case OP_BGE: case OP_BLTU: case OP_BGEU: {
            static const int cc[] = { EQ, NE, LT, GE, LO, HS };
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            dp3(&e, SUBSW, XZR, ra, rb);
            movw(&e, W10, p + (uint32_t)d->imm); movw(&e, W11, p + d->len);
            emit(&e, 0x1A800000u | (W11 << 16) | ((uint32_t)cc[d->op - OP_BEQ] << 12) | (W10 << 5) | W9);  /* csel w9, w10, w11, cc */
            I->dyn_next = 1; wr = 0;
            break;
        }
        case OP_LB: case OP_LH: case OP_LW: case OP_LBU: case OP_LHU: {
            static const int sz[] = { 1, 2, 4, 1, 2 };
            static const uint32_t ld[] = { 0x39C00082u, 0x79C00082u, 0xB9400082u, 0x39400082u, 0x79400082u };  /* ldrsb/ldrsh/ldr/ldrb/ldrh w2, [x4] */
            ra = greg(&e, W0, d->rs1);
            movw(&e, W1, (uint32_t)d->imm); dp3(&e, ADDW, W3, ra, W1);
            misaligned_exit(&e, j, sz[d->op - OP_LB], k, miss_patches, miss_target, &nmiss);
            uint32_t *slot; mem_check(&e, sz[d->op - OP_LB], &slot);
            miss_patches[nmiss] = slot; miss_target[nmiss++] = k;
            emit(&e, ld[d->op - OP_LB]);
            break;
        }
        case OP_LNONE: movw(&e, W2, 0); break;
        case OP_SB: case OP_SH: case OP_SW: {
            static const int sz[] = { 1, 2, 4 };
            static const uint32_t st[] = { 0x39000081u, 0x79000081u, 0xB9000081u };   /* strb/strh/str w1, [x4] */
            const int n = sz[d->op - OP_SB];
            ra = greg(&e, W0, d->rs1);
            movw(&e, W2, (uint32_t)d->imm); dp3(&e, ADDW, W3, ra, W2);
            misaligned_exit(&e, j, n, k, miss_patches, miss_target, &nmiss);
            uint32_t *slot; mem_check(&e, n, &slot);
            miss_patches[nmiss] = slot; miss_target[nmiss++] = k;
            rb = greg(&e, W1, d->rs2);
            if (rb == XZR) { emit(&e, 0x2A1F03E1u); rb = W1; }      /* mov w1, wzr */
            emit(&e, st[d->op - OP_SB]);
            /* out: address, data masked to the width */
            str_w(&e, W3, XO, ob + 8);
            if (n == 1) emit(&e, 0x12001C21u);                      /* and w1, w1, #0xff */
            else if (n == 2) emit(&e, 0x12003C21u);                 /* and w1, w1, #0xffff */
            str_w(&e, W1, XO, ob + 12);
            /* translated code in this page: done with this store, leave and drop translations */
            emit(&e, 0xD340FCA6u | ((uint32_t)JIT_PAGE << 16));    /* lsr x6, x5, #JIT_PAGE */
            emit(&e, 0x38666906u);                                  /* ldrb w6, [x8, x6] */
            uint32_t *cb = e.p; emit(&e, 0x34000006u);               /* cbz w6, cont (patched) */
            movw(&e, W9, 1); str_w(&e, W9, XS, OFF_SMC);
            exit_before(&e, p + d->len, k + 1);
            *cb = 0x34000006u | ((uint32_t)((e.p - cb) & 0x7FFFF) << 5);
            I->store = (uint8_t)n; wr = 0;
            break;
        }
        case OP_SNONE: case OP_FENCE: wr = 0; break;
        case OP_ADDI: case OP_XORI: case OP_ORI: case OP_ANDI: {
            static const uint32_t op[] = { ADDW, 0, 0, EORW, ORRW, ANDW };
            ra = greg(&e, W0, d->rs1); movw(&e, W1, (uint32_t)d->imm);
            dp3(&e, op[d->op - OP_ADDI], W2, ra, W1);
            break;
        }
        case OP_SLTI: case OP_SLTIU:
            ra = greg(&e, W0, d->rs1); movw(&e, W1, (uint32_t)d->imm);
            dp3(&e, SUBSW, XZR, ra, W1); cset(&e, W2, d->op == OP_SLTI ? LT : LO);
            break;
        case OP_SLLI: case OP_SRLI: case OP_SRAI: {
            static const uint32_t op[] = { LSLV, LSRV, ASRV };
            ra = greg(&e, W0, d->rs1); movw(&e, W1, (uint32_t)d->imm);
            dp3(&e, op[d->op - OP_SLLI], W2, ra, W1);
            break;
        }
        case OP_ADD: case OP_SUB: case OP_SLL: case OP_XOR: case OP_SRL: case OP_SRA: case OP_OR: case OP_AND: {
            uint32_t op = d->op == OP_ADD ? ADDW : d->op == OP_SUB ? SUBW : d->op == OP_SLL ? LSLV : d->op == OP_XOR ? EORW :
                          d->op == OP_SRL ? LSRV : d->op == OP_SRA ? ASRV : d->op == OP_OR ? ORRW : ANDW;
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            dp3(&e, op, W2, ra, rb);
            break;
        }
        case OP_SLT: case OP_SLTU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            dp3(&e, SUBSW, XZR, ra, rb); cset(&e, W2, d->op == OP_SLT ? LT : LO);
            break;
        case OP_MUL:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); dp3(&e, MULW, W2, ra, rb);
            break;
        case OP_MULH: case OP_MULHU: case OP_MULHSU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            if (ra == XZR) { emit(&e, 0x2A1F03E0u); ra = W0; }
            if (rb == XZR) { emit(&e, 0x2A1F03E1u); rb = W1; }
            if (d->op == OP_MULH) emit(&e, 0x9B207C02u | (rb << 16) | (ra << 5));      /* smull x2, w0, w1 */
            else if (d->op == OP_MULHU) emit(&e, 0x9BA07C02u | (rb << 16) | (ra << 5)); /* umull x2, w0, w1 */
            else {
                emit(&e, 0x93407C00u | (ra << 5));                 /* sxtw x0, w0 */
                emit(&e, 0x2A0003E1u | (rb << 16));                 /* mov w1, wrb (zero-extends) */
                emit(&e, 0x9B017C02u);                              /* mul x2, x0, x1 */
            }
            emit(&e, 0xD360FC42u);                                  /* lsr x2, x2, #32 */
            break;
        case OP_DIV: case OP_DIVU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            dp3(&e, d->op == OP_DIV ? SDIVW : UDIVW, W2, ra, rb);
            dp3(&e, SUBSW, XZR, rb, XZR);                           /* cmp b, #0 */
            emit(&e, 0x5A9F1042u);                                  /* csinv w2, w2, wzr, ne */
            break;
        case OP_REM: case OP_REMU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            dp3(&e, d->op == OP_REM ? SDIVW : UDIVW, W3, ra, rb);
            emit(&e, 0x1B008062u | (rb << 16) | (ra << 10));       /* msub w2, w3, wb, wa */
            break;
        default:
            wr = 0;
            break;
        }
        if (wr && I->rd) {
            str_w(&e, W2, XS, OFF_X + 4u * I->rd);
            str_w(&e, W2, XO, ob);
        }
        if (I->dyn_next) str_w(&e, W9, XO, ob + 4);
        I->m_next = I->dyn_next ? ~0u : 0; I->m_rd = I->rd ? ~0u : 0; I->m_store = I->store ? ~0u : 0;
        b->n = k + 1;
        p += d->len;
        if (ends_block(d)) {
            if (d->op == OP_JAL) movw(&e, W9, I->next);
            str_w(&e, W9, XS, OFF_PC);
            movw(&e, W0, k + 1);
            emit(&e, 0xD65F03C0u);                                /* ret */
            goto done;
        }
    }
    exit_before(&e, p, b->n);                                     /* no branch: continue at p */
done:
    for (int i = 0; i < nmiss; i++) {                             /* device registers: out before k */
        patch_bcond(miss_patches[i], e.p);
        exit_before(&e, b->ins[miss_target[i]].pc, miss_target[i]);
    }
    if (!e.ok || b->n == 0) { b->n = 0; return b; }               /* the interpreter runs it */
    __builtin___clear_cache((char *)start, (char *)e.p);
    b->fn = (int (*)(void *, jout_t *))(void *)start;
    j->code_cur = (uint8_t *)e.p;
    j->npool += b->n;
    j->n_trans++;
    return b;
}

static void jit_flush(jit_t *j)
{
    j->n_flush++;
    /* only the pages marked as code hold translations and decodings (mark_code): clearing the whole region
     * instead (megabytes per flush) made a test that writes near its code many times slower */
    for (int i = 0; i < j->f.nreg; i++) {
        fregion_t *r = &j->f.reg[i];
        const uint32_t npg = (r->size >> JIT_PAGE) + 1;
        for (uint32_t pg = 0; pg < npg; pg++) {
            if (!j->code_map[i][pg]) continue;
            j->code_map[i][pg] = 0;
            const uint32_t lo = (pg << JIT_PAGE) / 2, hi = ((pg + 1) << JIT_PAGE) / 2;
            for (uint32_t k = lo; k < hi && k < r->size / 2; k++) { j->map[i][k] = NULL; r->dec[k].valid = 0; }
        }
    }
    j->nblocks = 0; j->npool = 0;
    j->code_cur = j->code;
}

static inline void hand_out(jit_t *j, cpu_retire_t *r)
{
    const jins_t *I = &j->cur[j->cur_i];                    /* without branches: masks pick the values */
    const jout_t *o = &j->out[j->cur_i];
    r->order = j->cur_order + j->cur_i; r->pc = I->pc;
    r->pc_next = (o->next & I->m_next) | (I->next & ~I->m_next);
    r->rd_addr = I->rd; r->rd_wdata = o->wdata & I->m_rd;
    r->trap = 0; r->insn = I->insn; r->timing_csr = 0;
    r->mem_we = I->m_store & 1; r->mem_wmask = ((1u << I->store) - 1) & I->m_store;
    r->mem_addr = o->maddr & I->m_store; r->mem_wdata = o->mdata & I->m_store;
    r->csr_we = 0; r->csr_wcmd = 0; r->csr_waddr = 0; r->csr_wdata = 0;
    j->cur_i++;
}

/* the next unit: a translated block into the buffer (returns 1), or one instruction by the interpreter
 * into *r (returns 0) */
static int run_next(jit_t *j, cpu_retire_t *r)
{
    const uint32_t pc = j->f.pc;
    fregion_t *reg = j->single ? NULL : region_of(&j->f, pc, 2);   /* (cpu_sync: the interpreter) */
    if (j->single) j->single--;
    if (reg) {
        const int ri = (int)(reg - j->f.reg);
        jblock_t *b = j->map[ri][(pc - reg->base) >> 1];
        uint8_t *h = &j->hits[ri][(pc - reg->base) >> 1];
        if (!b && *h + 1u < j->hot) { (*h)++; j->n_cold++; }   /* not hot yet: the interpreter */
        else if (!b) {
            if (!(b = translate(j, pc))) { jit_flush(j); b = translate(j, pc); }
            j->map[ri][(pc - reg->base) >> 1] = b;
        }
        if (b && b->n) {
            j->smc = 0;
            memcpy(j->x0, j->f.x, sizeof j->x0);
            const uint32_t n = (uint32_t)b->fn(j, j->out);
            if (n) {
                j->n_blocks++;
                j->cur = b->ins; j->cur_n = n; j->cur_i = 0; j->cur_order = j->f.order;
                j->f.order += n;
                if (j->smc) {                                     /* code written: translate again */
                    memcpy(j->keep, b->ins, n * sizeof *j->keep);
                    j->cur = j->keep;
                    jit_flush(j);
                }
                return 1;
            }
        }
    }
    /* CSR, ecall/ebreak, illegal, a device register, code outside the regions: the interpreter */
    j->n_interp++;
    fast_step(&j->f.base, r);
    mark_code(j, r->pc, 4);
    if (r->mem_we && is_code(j, r->mem_addr, r->mem_wmask == 1 ? 1 : r->mem_wmask == 3 ? 2 : 4)) jit_flush(j);
    return 0;
}

static void jit_step(cpu_model_t *mm, cpu_retire_t *r)
{
    jit_t *j = (jit_t *)mm;
    if (j->cur_i < j->cur_n || run_next(j, r)) hand_out(j, r);   /* (else the interpreter filled *r) */
}

/* the rest of the running block, or the next block, or one interpreted instruction */
static int jit_step_n(cpu_model_t *mm, cpu_retire_t *r, int n)
{
    jit_t *j = (jit_t *)mm;
    if (j->cur_i == j->cur_n && !run_next(j, r)) return 1;
    int k = 0;
    while (k < n && j->cur_i < j->cur_n) hand_out(j, &r[k++]);
    return k;
}

static const cpu_impl_t cpu_jit_impl;

static void jit_sync(cpu_model_t *mm, uint64_t n)
{
    jit_t *j = (jit_t *)mm;
    if (n > j->single) j->single = n;
}

static int jit_interrupt(cpu_model_t *mm, uint32_t id)
{
    jit_t *j = (jit_t *)mm;
    if (j->cur_i < j->cur_n) {                  /* ran ahead: cpu_sync was not called in time */
        fprintf(stderr, "jit: interrupt inside a block already run (call cpu_sync before)\n");
        exit(2);
    }
    return fast_interrupt(&j->f.base, id);
}

static void jit_destroy(cpu_model_t *mm)
{
    jit_t *j = (jit_t *)mm;
    if (getenv("OCV_JIT_STATS"))
        fprintf(stderr, "jit: %llu blocks run (%.1f instructions each), %llu translated, %llu flushes, %llu interpreted"
                " (%llu of them not hot yet)\n",
                (unsigned long long)j->n_blocks, j->n_blocks ? (double)(j->f.order - j->n_interp) / (double)j->n_blocks : 0.0,
                (unsigned long long)j->n_trans, (unsigned long long)j->n_flush, (unsigned long long)j->n_interp,
                (unsigned long long)j->n_cold);
    for (int i = 0; i < j->f.nreg; i++) { dec_put(&j->f.reg[i]); free(j->map[i]); free(j->code_map[i]); free(j->hits[i]); }
    if (j->code) munmap(j->code, JIT_CODE);
    free(j->blocks); free(j->pool);
    free(j);
}

static cpu_model_t *jit_create(const char *isa, const cpu_env_t *env, uint32_t reset_pc, char *err, size_t n)
{
    cpu_model_t *f = fast_create(isa, env, reset_pc, err, n);   /* the interpreter's state, moved in */
    if (!f) return NULL;
    jit_t *j = calloc(1, sizeof *j);
    if (!j) { fast_destroy(f); snprintf(err, n, "out of memory"); return NULL; }
    j->f = *(fast_t *)f;
    free(f);
    j->f.base.impl = &cpu_jit_impl;
    for (int i = 0; i < j->f.nreg; i++) {
        j->map[i] = calloc(j->f.reg[i].size / 2, sizeof *j->map[i]);
        j->code_map[i] = calloc((j->f.reg[i].size >> JIT_PAGE) + 1, 1);
        j->hits[i] = calloc(j->f.reg[i].size / 2, 1);
        if (!j->map[i] || !j->code_map[i] || !j->hits[i]) { jit_destroy(&j->f.base); snprintf(err, n, "out of memory"); return NULL; }
    }
    for (int i = 0; i < 2 && i < j->f.nreg; i++) {               /* the regions the generated code reaches */
        j->host[i] = j->f.reg[i].host; j->base[i] = j->f.reg[i].base; j->size[i] = j->f.reg[i].size; j->cmap[i] = j->code_map[i];
    }
    j->blocks = calloc(JIT_BLOCKS, sizeof *j->blocks);
    j->pool = calloc(JIT_POOL, sizeof *j->pool);
    void *c = mmap(NULL, JIT_CODE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    j->code = c == MAP_FAILED ? NULL : c;
    if (!j->code || !j->blocks || !j->pool) {
        jit_destroy(&j->f.base);
        snprintf(err, n, "jit: out of memory or no executable memory (mmap RWX)"); return NULL;
    }
    j->code_end = j->code + JIT_CODE; j->code_cur = j->code;
    const char *hv = getenv("OCV_JIT_HOT");
    j->hot = hv ? (uint32_t)strtoul(hv, 0, 0) : 3;
    if (j->hot > 255) j->hot = 255;
    return &j->f.base;
}

static uint32_t jit_xreg(cpu_model_t *m, int i)
{
    jit_t *j = (jit_t *)m;                                       /* the state after the last handed out */
    if (!(i & 31)) return 0;
    if (j->cur_i < j->cur_n) {
        /* the registers already hold the whole block: the newest value of x[i] up to cur_i */
        for (uint32_t k = j->cur_i; k-- > 0;) if (j->cur[k].rd == (i & 31)) return j->out[k].wdata;
        return j->x0[i & 31];
    }
    return j->f.x[i & 31];
}
static uint32_t jit_pc(cpu_model_t *m)
{
    jit_t *j = (jit_t *)m;
    if (j->cur_i < j->cur_n) return j->cur[j->cur_i].pc;
    return j->f.pc;
}

static const cpu_impl_t cpu_jit_impl = {
    "jit", "\"fast\" translated block by block into AArch64 code (the board's A72)", 0,
    jit_create, jit_step, jit_xreg, jit_pc, jit_destroy, jit_step_n, jit_interrupt, jit_sync, 0
};
#endif
