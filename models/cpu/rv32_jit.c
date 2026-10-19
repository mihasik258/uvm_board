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

typedef cpu_bout_t jout_t;                 /* what a block's code computes, per instruction */
typedef cpu_bins_t jins_t;                 /* the translation's table, per instruction (cpu_model.h) */


enum { JP_ENTER, JP_ARG, JP_OP, JP_OUT, JP_CVA, JP_CVB, JP_CVBIN, JP_CVS, JP_CVM, JP_REC, JP_EXIT, JP_N };

typedef struct jblock {
    int (*fn)(void *state, jout_t *out);
    int (*fnf)(void *state, jout_t *out);  /* the same doing cpu_fuse_t's work too (NULL: not translated so) */
    uint32_t n;                            /* instructions translated (0: the first one is not) */
    uint16_t cntf[2];                      /* records per fused stream, one whole run */
    void    *user;                         /* cpu_block_t.user */
    void    *fnb;                          /* chaining: fnf's body (after its prologue), NULL: not chained into */
    jins_t  *ins;                          /* in the pool */
    /* OCV_JIT_STATS=phases: where the generated code's words go (weighted by the block's runs at the end) */
    uint32_t runs, runsf; uint16_t ph[JP_N], phf[JP_N];
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
    uint64_t   cur_key;                    /* the running block: (flushes << 32) | its index + 1; 0: a copy (smc) */
    int        cur_fused;                  /* it ran its fnf */
    jblock_t  *cur_blk;                    /* it (NULL: a copy, smc) */
    const cpu_fuse_t *fz;                  /* cpu_jit_fuse (NULL: none) */
    uint64_t   cur_order;
    uint32_t   x0[32];                     /* registers up to the last handed out of the running block (cpu_xreg
                                            * and src1/src2 inside it; the block itself already wrote f.x) */
    uint64_t   single;                     /* cpu_sync: instructions still to run one by one */
    int        smc;                        /* a store hit translated code */
    uint64_t   n_blocks, n_trans, n_flush, n_interp, n_cold, n_fused;   /* OCV_JIT_STATS: printed at the end */
    int        phstats;                  /* count where the generated code's words go */
    FILE      *phfile;                   /* OCV_JIT_PHASES: a line per block (start nw off[]) */
    /* for the generated code: [x19 + JIT_OFF_*] */
    uint8_t   *host[2]; uint64_t base[2], size[2]; uint8_t *cmap[2];
    uint8_t   *cov; uint32_t *fst[2];     /* fused code: the coverage bins, the windows' state */
    uint32_t  *ist;                       /* chaining: the issue window's state (NULL: no chaining) */
    jblock_t **map0;                      /* region 0's map: the dispatcher's next block */
    uint32_t   budget;                    /* instructions the call may still run (cpu_block_t.budget) */
    uint64_t   chain_n;                   /* instructions of whole fused blocks run in this call */
    jblock_t  *chain_last;                /* the block running / run last in this call */
    uint64_t   n_chained;                 /* blocks entered from the dispatcher (OCV_JIT_STATS) */
    uint32_t  *dispatch;                  /* the dispatcher (at the code buffer's start) */
} jit_t;

/* ---------------------------------------------------------------- AArch64 encoder */
#define JIT_IV 4096
typedef struct {
    uint32_t *p, *end, *b0, *start; int ok; uint32_t ph[16]; int tag; uint32_t ngreg, nregw;
    uint32_t niv; uint16_t iv_off[JIT_IV]; uint8_t iv_tag[JIT_IV];   /* the phase intervals of this range */
} em_t;
static void emit(em_t *e, uint32_t w) { if (e->p < e->end) *e->p++ = w; else e->ok = 0; }
static void mark(em_t *e)                                      /* close the phase into an interval */
{
    const uint32_t n = (uint32_t)(e->p - e->b0);
    e->ph[e->tag] += n;
    if (n && e->niv < JIT_IV) { e->iv_off[e->niv] = (uint16_t)(e->b0 - e->start); e->iv_tag[e->niv] = (uint8_t)e->tag; e->niv++; }
    e->b0 = e->p;
}
static void set_ph(em_t *e, int tag) { if (tag != e->tag) { mark(e); e->tag = tag; } }

enum { W0 = 0, W1, W2, W3, W4, W5, W6, W7, W8, W9, W10, W11, XO = 14, XS = 15, XZR = 31 };   /* x15: jit_t, x14: out */
/* the fused code keeps the open windows' CRCs in callee-saved registers through the whole block (saved in the
 * prologue, written back and restored at every exit): stream 0 in x19/x20, stream 1 in x21/x22 */
enum { CZ0 = 19, WC0 = 20, CZ1 = 21, WC1 = 22 };

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
#define OFF_COV   offsetof(jit_t, cov)
#define OFF_FST   offsetof(jit_t, fst)
#define OFF_IST   offsetof(jit_t, ist)
#define OFF_MAP0  offsetof(jit_t, map0)
#define OFF_BUD   offsetof(jit_t, budget)
#define OFF_CHN   offsetof(jit_t, chain_n)
#define OFF_CHL   offsetof(jit_t, chain_last)
#define OFF_NCH   offsetof(jit_t, n_chained)

/* guest register into a host register (x0 reads 0) */
static int greg(em_t *e, int host, int g)
{
    if (!g) return XZR;
    e->ngreg++;
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

/* ---------------------------------------------------------------- fused work (cpu_fuse_t) */
/* After an instruction's own code, the fused version of a block counts its coverage bin and folds its records
 * into their windows from the registers that hold the values: x12 the bins (loaded on entry), w10 w11 w13 w16
 * w17 scratch, then w0 w5 the window's CRCs (x17 its state). x9 keeps the next pc of a jump: untouched. */
enum { W12 = 12, W13 = 13, W16 = 16, W17 = 17 };
static void bcond_at(uint32_t *at, const uint32_t *to, int cond) { *at = 0x54000000u | ((uint32_t)((to - at) & 0x7FFFF) << 5) | (uint32_t)cond; }
static void b_at(uint32_t *at, const uint32_t *to) { *at = 0x14000000u | (uint32_t)((to - at) & 0x3FFFFFF); }
static void cbz_at(uint32_t *at, const uint32_t *to, int rt) { *at = 0x34000000u | ((uint32_t)((to - at) & 0x7FFFF) << 5) | (uint32_t)rt; }
static void strb_reg(em_t *e, int rt, int rn, int rm) { emit(e, 0x38206800u | ((uint32_t)rm << 16) | ((uint32_t)rn << 5) | (uint32_t)rt); }
static void add_imm(em_t *e, int rd, int rn, uint32_t v, int tmp)          /* wd = wn + v */
{
    if (v < 4096) emit(e, 0x11000000u | (v << 10) | ((uint32_t)rn << 5) | (uint32_t)rd);
    else { movw(e, tmp, v); dp3(e, ADDW, rd, rn, tmp); }
}

/* wd = the coverage class of ws (cpu_fuse_t.cls; ws XZR: 0); w16 scratch. Most values take no branch. */
static void fz_class(em_t *e, const cpu_fuse_t *f, int wd, int ws, int tag)
{
    set_ph(e, tag);
    if (ws == XZR) { movw(e, wd, f->cls[0]); return; }
    emit(e, 0x11000400u | ((uint32_t)ws << 5) | W16);          /* add w16, ws, #1 */
    emit(e, 0x7100081Fu | (W16 << 5));                         /* cmp w16, #2 */
    uint32_t *b1 = e->p; emit(e, 0);                           /* b.ls: -1 0 1 */
    emit(e, 0x52010000u | ((uint32_t)ws << 5) | W16);          /* eor w16, ws, #0x80000000 */
    emit(e, 0x11000400u | (W16 << 5) | W16);                   /* add w16, w16, #1 */
    emit(e, 0x7100041Fu | (W16 << 5));                         /* cmp w16, #1 */
    uint32_t *b2 = e->p; emit(e, 0);                           /* b.ls: MIN MAX */
    emit(e, 0x531F7C00u | ((uint32_t)ws << 5) | (uint32_t)wd); /* lsr wd, ws, #31 */
    emit(e, 0x11000000u | ((uint32_t)f->cls[5] << 10) | ((uint32_t)wd << 5) | (uint32_t)wd);   /* add wd, wd, #pos */
    uint32_t *j1 = e->p; emit(e, 0);
    if (e->p >= e->end) { e->ok = 0; return; }
    bcond_at(b1, e->p, LS);                                    /* w16 = v + 1: 0 is -1, 1 is 0, 2 is 1 */
    movw(e, wd, f->cls[2]); uint32_t *c0 = e->p; emit(e, 0);
    emit(e, 0x7100041Fu | (W16 << 5));                         /* cmp w16, #1 */
    movw(e, wd, f->cls[0]); uint32_t *c1 = e->p; emit(e, 0);
    movw(e, wd, f->cls[1]); uint32_t *j2 = e->p; emit(e, 0);
    if (e->p >= e->end) { e->ok = 0; return; }
    bcond_at(b2, e->p, LS);                                    /* w16 = (v ^ MIN) + 1: 1 is MIN, 0 is MAX */
    movw(e, wd, f->cls[4]); uint32_t *c2 = e->p; emit(e, 0);
    movw(e, wd, f->cls[3]);
    if (!e->ok) return;
    b_at(j1, e->p); b_at(j2, e->p); cbz_at(c0, e->p, W16); bcond_at(c1, e->p, EQ); cbz_at(c2, e->p, W16);
}

/* the instruction's coverage: va, vb the registers with its operands (-1: none here), w3 a load's / store's
 * address; 0 if it needs an operand it does not have */
static int fz_cov(em_t *e, const cpu_fuse_t *f, const cpu_covp_t *p, int va, int vb, int has_addr)
{
    int mis = 0;
    for (int o = 0; o < 4; o++) mis |= p->mis[o] != 0xFFFF;
    if ((p->kind && va < 0) || (p->kind == 1 && vb < 0) || (mis && !has_addr)) return 0;
    if (p->kind) {
        fz_class(e, f, W13, va, JP_CVA);
        if (p->kind == 1) fz_class(e, f, W10, vb, JP_CVB);
        set_ph(e, JP_CVBIN);
        movw(e, W16, p->nc2);
        emit(e, 0x1B000000u | (W16 << 16) | ((uint32_t)(p->kind == 1 ? W10 : XZR) << 10) | (W13 << 5) | W16);  /* madd w16, w13, w16, w10|wzr */
        add_imm(e, W16, W16, p->v, W11);
        movw(e, W17, 1); strb_reg(e, W17, W12, W16);
    }
    set_ph(e, JP_CVS);
    for (int k = 0; k < 2; k++) {
        const uint16_t b = k ? p->s1 : p->s0;
        if (b == 0xFFFF) continue;
        movw(e, W16, b); movw(e, W17, 1); strb_reg(e, W17, W12, W16);
    }
    if (mis) {
        set_ph(e, JP_CVM);
        emit(e, 0x12000400u | (W3 << 5) | W16);                /* and w16, w3, #3 */
        movw(e, W17, 1);
        for (uint32_t o = 0; o < 4; o++) {
            if (p->mis[o] == 0xFFFF) continue;
            emit(e, 0x7100001Fu | (o << 10) | (W16 << 5));     /* cmp w16, #o */
            uint32_t *bn = e->p; emit(e, 0);
            movw(e, W13, p->mis[o]); strb_reg(e, W17, W12, W13);
            if (!e->ok) return 1;
            bcond_at(bn, e->p, NE);
        }
    }
    return 1;
}

/* a record of fused stream s from its fields (each a register, reg >= 0, or a constant), folded into the
 * window: words in w10 w11 w13 w16 (w17 scratch), the CRCs through w0 w5 */
typedef struct { int reg; uint32_t val; } fzv_t;
static void fz_record(em_t *e, const cpu_fstream_t *fs, int s, const fzv_t *v, uint32_t last_off)
{
    static const int wr[4] = { W10, W11, W13, W16 };
    uint32_t cst[4] = { 0, 0, 0, 0 };
    for (int k = 0; k < 3; k++) {                              /* the constant fields */
        const cpu_ffield_t *fl = &fs->f[k];
        if (!fl->width || v[k].reg >= 0) continue;
        const uint32_t o = fl->lsb & 31u, w = fl->lsb >> 5;
        const uint32_t x = fl->width < 32 ? v[k].val & ((1u << fl->width) - 1u) : v[k].val;
        cst[w] |= x << o;
        if (o && o + fl->width > 32u) cst[w + 1] |= x >> (32u - o);
    }
    for (uint32_t w = 0; w < fs->words; w++) movw(e, wr[w], cst[w]);
    for (int k = 0; k < 3; k++) {                              /* the register fields */
        const cpu_ffield_t *fl = &fs->f[k];
        if (!fl->width || v[k].reg < 0) continue;
        const uint32_t o = fl->lsb & 31u, w = fl->lsb >> 5;
        int src = v[k].reg;
        if (fl->width < 32) { emit(e, 0x53000000u | ((uint32_t)(fl->width - 1) << 10) | ((uint32_t)src << 5) | W17); src = W17; }   /* ubfx w17, src, #0, #width */
        emit(e, 0x2A000000u | ((uint32_t)src << 16) | (o << 10) | ((uint32_t)wr[w] << 5) | (uint32_t)wr[w]);   /* orr ww, ww, src, lsl #o */
        if (o && o + fl->width > 32u)
            emit(e, 0x2A400000u | ((uint32_t)src << 16) | ((32u - o) << 10) | ((uint32_t)wr[w + 1] << 5) | (uint32_t)wr[w + 1]);   /* orr, lsr #32-o */
    }
    if (last_off) {                                            /* the window's last record: this one */
        ldr_x(e, W17, XS, (uint32_t)(OFF_FST + 8u * (uint32_t)s));
        for (uint32_t w = 0; w < fs->words; w++) str_w(e, wr[w], W17, last_off + 4u * w);
    }
    for (uint32_t w = 0; w < fs->words; w++)
        if (fs->mask[w] != ~0u) { movw(e, W17, fs->mask[w]); dp3(e, ANDW, wr[w], wr[w], W17); }
    const int c0 = s ? WC1 : WC0, c1 = s ? CZ1 : CZ0;          /* (in registers since the prologue) */
    uint32_t w = 0;
    for (; w + 1 < fs->words; w += 2) {
        emit(e, 0xAA000000u | ((uint32_t)wr[w + 1] << 16) | (32u << 10) | ((uint32_t)wr[w] << 5) | (uint32_t)wr[w]);   /* orr xa, xa, xb, lsl #32 */
        emit(e, 0x9AC05C00u | ((uint32_t)wr[w] << 16) | (c0 << 5) | c0);   /* crc32cx */
        emit(e, 0x9AC04C00u | ((uint32_t)wr[w] << 16) | (c1 << 5) | c1);   /* crc32x */
    }
    if (w < fs->words) {
        emit(e, 0x1AC05800u | ((uint32_t)wr[w] << 16) | (c0 << 5) | c0);   /* crc32cw */
        emit(e, 0x1AC04800u | ((uint32_t)wr[w] << 16) | (c1 << 5) | c1);   /* crc32w */
    }
}

/* ---------------------------------------------------------------- translation */

/* the fused code's way out: the windows' CRCs back into their state, x19..x22 as they were */
static void fz_crc_out(em_t *e, const cpu_fuse_t *fz)
{
    if (!fz || !fz->nstreams) return;
    ldr_x(e, W17, XS, (uint32_t)(OFF_FST + 0));
    str_w(e, WC0, W17, 4); str_w(e, CZ0, W17, 8);
    if (fz->nstreams > 1) {
        ldr_x(e, W17, XS, (uint32_t)(OFF_FST + 8));
        str_w(e, WC1, W17, 4); str_w(e, CZ1, W17, 8);
    }
    emit(e, 0xA9410000u | (2u << 15) | (22u << 10) | (31u << 5) | 21u);   /* ldp x21, x22, [sp, #16] */
    emit(e, 0xA8C00000u | (4u << 15) | (20u << 10) | (31u << 5) | 19u);   /* ldp x19, x20, [sp], #32 */
}

/* the end of a whole fused block (chaining): its records into the windows' counts, its issue records' piece
 * into the issue window (the next pc is stored), then on to the dispatcher with w0 = its instructions */
static void fz_block_done(em_t *e, const jit_t *j, const cpu_fuse_t *fz, const jblock_t *b, const cpu_piece_t *pc_, uint32_t n)
{
    for (int s = 0; s < fz->nstreams; s++) {
        if (!b->cntf[s]) continue;
        ldr_x(e, W17, XS, (uint32_t)(OFF_FST + 8u * (uint32_t)s));
        ldr_w(e, W16, W17, 0); add_imm(e, W16, W16, b->cntf[s], W11); str_w(e, W16, W17, 0);
    }
    ldr_x(e, W17, XS, (uint32_t)OFF_IST);                      /* the issue window */
    ldr_w(e, W16, W17, 0); add_imm(e, W16, W16, pc_->n, W11); str_w(e, W16, W17, 0);
    for (int k = 0; k < 2; k++) {                               /* CRC32C, then CRC32: crc(0, clmul(state, k)) ^ c */
        ldr_w(e, W0, W17, 4u + 4u * (uint32_t)k);
        movw(e, W16, k ? pc_->kz : pc_->kc);
        emit(e, 0x9E670000u);                                   /* fmov d0, x0 */
        emit(e, 0x9E670201u);                                   /* fmov d1, x16 */
        emit(e, 0x0EE1E000u);                                   /* pmull v0.1q, v0.1d, v1.1d */
        emit(e, 0x9E660000u);                                   /* fmov x0, d0 */
        emit(e, (k ? 0x9AC04C00u : 0x9AC05C00u) | (31u << 5));   /* crc32x / crc32cx w0, wzr, x0 */
        movw(e, W16, k ? pc_->z : pc_->c);
        dp3(e, EORW, W0, W0, W16);
        str_w(e, W0, W17, 4u + 4u * (uint32_t)k);
    }
    for (uint32_t w = 0; w < pc_->words; w++) { movw(e, W16, pc_->last[w]); str_w(e, W16, W17, fz->last_off + 4u * w); }
    movw(e, W0, n);
    emit(e, 0x14000000u | (uint32_t)((j->dispatch - e->p) & 0x3FFFFFF));   /* b dispatch */
}

/* exit before instruction k (not executed): pc = its pc, return k */
static void exit_before(em_t *e, const cpu_fuse_t *fz, uint32_t pc, uint32_t k)
{
    set_ph(e, JP_EXIT);
    fz_crc_out(e, fz);
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

/* the code of block b from pc (its table too), fz: the fused version (cpu_fuse_t) - b->fn, or b->fnf with
 * b->cntf; 0 if it cannot be translated so */
static int gen(jit_t *j, uint32_t pc, jblock_t *b, const cpu_fuse_t *fz)
{
    em_t e = { 0 };
    e.p = e.b0 = e.start = (uint32_t *)j->code_cur; e.end = (uint32_t *)j->code_end; e.ok = 1; e.tag = JP_ENTER;
    uint32_t *start = e.p;
    const uint32_t n0 = b->n;
    if (fz) { b->cntf[0] = b->cntf[1] = 0; }
    emit(&e, 0xAA0003EFu);              /* mov x15, x0: jit_t */
    emit(&e, 0xAA0103EEu);              /* mov x14, x1: out */
    if (fz && fz->cov) ldr_x(&e, W12, XS, OFF_COV);   /* x12: the coverage bins */
    if (fz && fz->nstreams > 0) {                 /* the windows' CRCs, kept in registers through the block */
        emit(&e, 0xA9800000u | ((-4u & 0x7Fu) << 15) | (20u << 10) | (31u << 5) | 19u);   /* stp x19, x20, [sp, #-32]! */
        emit(&e, 0xA9010000u | (2u << 15) | (22u << 10) | (31u << 5) | 21u);             /* stp x21, x22, [sp, #16] */
        ldr_x(&e, W17, XS, (uint32_t)(OFF_FST + 0));
        ldr_w(&e, WC0, W17, 4); ldr_w(&e, CZ0, W17, 8);
        if (fz->nstreams > 1) {
            ldr_x(&e, W17, XS, (uint32_t)(OFF_FST + 8));
            ldr_w(&e, WC1, W17, 4); ldr_w(&e, CZ1, W17, 8);
        }
    }
    uint32_t *body = e.p;                         /* (chaining: where the dispatcher enters) */
    const int chain = fz && fz->istate && fz->nstreams > 0 && j->dispatch;
    set_ph(&e, JP_OP);
    uint32_t *miss_patches[2 * JIT_MAX], miss_target[2 * JIT_MAX];   /* region miss; cva6: misaligned */
    int nmiss = 0;
    uint32_t p = pc;
    fregion_t *creg = region_of(&j->f, pc, 2);
    for (uint32_t k = 0; k < JIT_MAX && e.ok; k++) {
        dec_t tmp;
        const dec_t *d = fetch(&j->f, p, &tmp);
        mark_code(j, p, d->len);
        if (!translatable(d) || region_of(&j->f, p, d->len) != creg) break;   /* (code within one region) */
        if (fz && p == fz->exit_pc) return 0;                     /* (the end: the caller takes it alone) */
        jins_t *I = &b->ins[k];
        I->pc = p; I->insn = d->insn; I->len = d->len; I->store = 0; I->dyn_next = 0;
        I->rs1 = d->rs1; I->rs2 = d->rs2;
        I->raw = d->len == 2 ? (uint16_t)(creg->host[p - creg->base] | creg->host[p - creg->base + 1] << 8) : 0;
        I->next = d->op == OP_JAL ? p + (uint32_t)d->imm : p + d->len;
        I->rd = (d->rd && d->op != OP_SB && d->op != OP_SH && d->op != OP_SW && d->op != OP_SNONE &&
                 !(d->op >= OP_BEQ && d->op <= OP_BGEU) && d->op != OP_FENCE) ? d->rd : 0;
        const uint32_t ob = 16u * k;                              /* this instruction's jout_t */
        set_ph(&e, JP_OP);                                        /* (the instruction's own code) */
        int ra, rb, wr = 1;                                       /* wr: w2 holds the result for rd */
        int va = -1, vb = -1, addr = 0;                           /* (fused: where the operands are) */
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
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); va = ra; vb = rb;
            dp3(&e, SUBSW, XZR, ra, rb);
            movw(&e, W10, p + (uint32_t)d->imm); movw(&e, W11, p + d->len);
            emit(&e, 0x1A800000u | (W11 << 16) | ((uint32_t)cc[d->op - OP_BEQ] << 12) | (W10 << 5) | W9);  /* csel w9, w10, w11, cc */
            I->dyn_next = 1; wr = 0;
            break;
        }
        case OP_LB: case OP_LH: case OP_LW: case OP_LBU: case OP_LHU: {
            static const int sz[] = { 1, 2, 4, 1, 2 };
            static const uint32_t ld[] = { 0x39C00082u, 0x79C00082u, 0xB9400082u, 0x39400082u, 0x79400082u };  /* ldrsb/ldrsh/ldr/ldrb/ldrh w2, [x4] */
            ra = greg(&e, W0, d->rs1); va = ra; addr = 1;
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
            ra = greg(&e, W0, d->rs1); va = ra; addr = 1;
            movw(&e, W2, (uint32_t)d->imm); dp3(&e, ADDW, W3, ra, W2);
            misaligned_exit(&e, j, n, k, miss_patches, miss_target, &nmiss);
            if (fz && !j->f.cva6 && n > 1) {                          /* (fused: a store across words splits its record) */
                emit(&e, 0x12000400u | (W3 << 5) | W16);              /* and w16, w3, #3 */
                emit(&e, 0x7100001Fu | ((uint32_t)(4 - n) << 10) | (W16 << 5));
                miss_patches[nmiss] = e.p; miss_target[nmiss++] = k;
                emit(&e, 0x54000008u);                                /* b.hi miss */
            }
            uint32_t *slot; mem_check(&e, n, &slot);
            miss_patches[nmiss] = slot; miss_target[nmiss++] = k;
            rb = greg(&e, W1, d->rs2);
            if (rb == XZR) { emit(&e, 0x2A1F03E1u); rb = W1; }      /* mov w1, wzr */
            if (fz) {                                             /* fused: into code - out before it, not after */
                emit(&e, 0xD340FCA6u | ((uint32_t)JIT_PAGE << 16));    /* lsr x6, x5, #JIT_PAGE */
                emit(&e, 0x38666906u);                                  /* ldrb w6, [x8, x6] */
                miss_patches[nmiss] = e.p; miss_target[nmiss++] = k;
                emit(&e, 0x35000006u);                                  /* cbnz w6, miss (the interpreter) */
            }
            emit(&e, st[d->op - OP_SB]);
            /* out: address, data masked to the width */
            set_ph(&e, JP_OUT);
            str_w(&e, W3, XO, ob + 8);
            if (n == 1) emit(&e, 0x12001C21u);                      /* and w1, w1, #0xff */
            else if (n == 2) emit(&e, 0x12003C21u);                 /* and w1, w1, #0xffff */
            str_w(&e, W1, XO, ob + 12);
            /* translated code in this page: done with this store, leave and drop translations */
            if (!fz) {
                emit(&e, 0xD340FCA6u | ((uint32_t)JIT_PAGE << 16));    /* lsr x6, x5, #JIT_PAGE */
                emit(&e, 0x38666906u);                                  /* ldrb w6, [x8, x6] */
                uint32_t *cb = e.p; emit(&e, 0x34000006u);               /* cbz w6, cont (patched) */
                movw(&e, W9, 1); str_w(&e, W9, XS, OFF_SMC);
                exit_before(&e, fz, p + d->len, k + 1);
                *cb = 0x34000006u | ((uint32_t)((e.p - cb) & 0x7FFFF) << 5);
            }
            I->store = (uint8_t)n; wr = 0;
            break;
        }
        case OP_SNONE: case OP_FENCE: wr = 0; break;
        case OP_ADDI: case OP_XORI: case OP_ORI: case OP_ANDI: {
            static const uint32_t op[] = { ADDW, 0, 0, EORW, ORRW, ANDW };
            ra = greg(&e, W0, d->rs1); va = ra; movw(&e, W1, (uint32_t)d->imm);
            dp3(&e, op[d->op - OP_ADDI], W2, ra, W1);
            break;
        }
        case OP_SLTI: case OP_SLTIU:
            ra = greg(&e, W0, d->rs1); va = ra; movw(&e, W1, (uint32_t)d->imm);
            dp3(&e, SUBSW, XZR, ra, W1); cset(&e, W2, d->op == OP_SLTI ? LT : LO);
            break;
        case OP_SLLI: case OP_SRLI: case OP_SRAI: {
            static const uint32_t op[] = { LSLV, LSRV, ASRV };
            ra = greg(&e, W0, d->rs1); va = ra; movw(&e, W1, (uint32_t)d->imm);
            dp3(&e, op[d->op - OP_SLLI], W2, ra, W1);
            break;
        }
        case OP_ADD: case OP_SUB: case OP_SLL: case OP_XOR: case OP_SRL: case OP_SRA: case OP_OR: case OP_AND: {
            uint32_t op = d->op == OP_ADD ? ADDW : d->op == OP_SUB ? SUBW : d->op == OP_SLL ? LSLV : d->op == OP_XOR ? EORW :
                          d->op == OP_SRL ? LSRV : d->op == OP_SRA ? ASRV : d->op == OP_OR ? ORRW : ANDW;
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); va = ra; vb = rb;
            dp3(&e, op, W2, ra, rb);
            break;
        }
        case OP_SLT: case OP_SLTU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); va = ra; vb = rb;
            dp3(&e, SUBSW, XZR, ra, rb); cset(&e, W2, d->op == OP_SLT ? LT : LO);
            break;
        case OP_MUL:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); va = ra; vb = rb; dp3(&e, MULW, W2, ra, rb);
            break;
        case OP_MULH: case OP_MULHU: case OP_MULHSU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2);
            if (ra == XZR) { emit(&e, 0x2A1F03E0u); ra = W0; }
            if (rb == XZR) { emit(&e, 0x2A1F03E1u); rb = W1; }
            va = ra; vb = rb;
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
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); va = ra; vb = rb;
            dp3(&e, d->op == OP_DIV ? SDIVW : UDIVW, W2, ra, rb);
            dp3(&e, SUBSW, XZR, rb, XZR);                           /* cmp b, #0 */
            emit(&e, 0x5A9F1042u);                                  /* csinv w2, w2, wzr, ne */
            break;
        case OP_REM: case OP_REMU:
            ra = greg(&e, W0, d->rs1); rb = greg(&e, W1, d->rs2); va = ra; vb = rb;
            dp3(&e, d->op == OP_REM ? SDIVW : UDIVW, W3, ra, rb);
            emit(&e, 0x1B008062u | (rb << 16) | (ra << 10));       /* msub w2, w3, wb, wa */
            break;
        default:
            wr = 0;
            break;
        }
        if (wr && I->rd) {
            set_ph(&e, JP_OUT);
            str_w(&e, W2, XS, OFF_X + 4u * I->rd); e.nregw++;
            str_w(&e, W2, XO, ob);
        }
        if (I->dyn_next) { set_ph(&e, JP_OUT); str_w(&e, W9, XO, ob + 4); }
        set_ph(&e, JP_OP);
        I->m_next = I->dyn_next ? ~0u : 0; I->m_rd = I->rd ? ~0u : 0; I->m_store = I->store ? ~0u : 0;
        if (fz) {                                                 /* coverage, then the records */
            set_ph(&e, (fz->cov ? JP_CVA : JP_REC));
            if (fz->cov) {
                set_ph(&e, JP_CVA);
                cpu_covp_t cp;
                fz->cov_plan(I->len == 2 ? I->raw : I->insn & 0xFFFFu, I->len == 2, I->insn, &cp);
                if (!fz_cov(&e, fz, &cp, va, vb, addr)) return 0;
            }
            set_ph(&e, JP_REC);
            for (int s = 0; s < fz->nstreams; s++) {
                const cpu_fstream_t *fs = &fz->s[s];
                if (!fs->store) {
                    const int load = (I->insn & 0x7f) == 0x03;
                    if (!I->rd || !(fs->filter == 0 || (fs->filter == 1) == load)) continue;
                    if (!wr) return 0;
                    const fzv_t v[3] = { { -1, I->rd }, { W2, 0 }, { -1, 0 } };
                    fz_record(&e, fs, s, v, fz->istate ? fz->last_off : 0);
                } else {
                    if (!I->store) continue;
                    emit(&e, 0x121E7400u | (W3 << 5) | W6);           /* and w6, w3, #~3: the word */
                    emit(&e, 0x12000400u | (W3 << 5) | W7);           /* and w7, w3, #3 */
                    movw(&e, W8, I->store == 1 ? 1u : I->store == 2 ? 3u : 0xFu);
                    dp3(&e, LSLV, W8, W8, W7);                        /* be */
                    emit(&e, 0x531D7000u | (W7 << 5) | W7);           /* lsl w7, w7, #3 */
                    dp3(&e, LSLV, W4, W1, W7);                        /* the data at its bytes */
                    const fzv_t v[3] = { { W6, 0 }, { W8, 0 }, { W4, 0 } };
                    fz_record(&e, fs, s, v, fz->istate ? fz->last_off : 0);
                }
                b->cntf[s]++;
            }
        }
        b->n = k + 1;
        p += d->len;
        if (ends_block(d)) {
            set_ph(&e, JP_EXIT);
            if (d->op == OP_JAL) movw(&e, W9, I->next);
            str_w(&e, W9, XS, OFF_PC);
            if (chain) {                                          /* the whole block: its own work, then on */
                cpu_piece_t pc_;
                if (!fz->piece(b->ins, (int)(k + 1), &pc_)) return 0;
                fz_block_done(&e, j, fz, b, &pc_, k + 1);
                goto done;
            }
            fz_crc_out(&e, fz);
            movw(&e, W0, k + 1);
            emit(&e, 0xD65F03C0u);                                /* ret */
            goto done;
        }
    }
    if (chain) {                                                  /* no branch: continue at p - as above */
        set_ph(&e, JP_EXIT);
        movw(&e, W9, p); str_w(&e, W9, XS, OFF_PC);
        cpu_piece_t pc_;
        if (!b->n || !fz->piece(b->ins, (int)b->n, &pc_)) return 0;
        fz_block_done(&e, j, fz, b, &pc_, b->n);
    } else
        exit_before(&e, fz, p, b->n);
done:
    for (int i = 0; i < nmiss; i++) {                             /* device registers: out before k */
        patch_bcond(miss_patches[i], e.p);
        exit_before(&e, fz, b->ins[miss_target[i]].pc, miss_target[i]);
    }
    if (!e.ok || b->n == 0 || (fz && b->n != n0)) return 0;
    set_ph(&e, JP_N - 1); mark(&e);              /* (the last one) */
    __builtin___clear_cache((char *)start, (char *)e.p);
    int (*fn)(void *, jout_t *) = (int (*)(void *, jout_t *))(void *)start;
    for (int i = 0; i < JP_N; i++) {
        const uint16_t w = (uint16_t)e.ph[i];
        if (fz) b->phf[i] = w; else b->ph[i] = w;
    }
    if (fz) { b->fnf = fn; b->fnb = chain ? (void *)body : NULL; } else b->fn = fn;
    if (getenv("OCV_JIT_DUMPCODE")) {            /* the raw code words of this range, with the phase intervals */
        FILE *f = fopen(getenv("OCV_JIT_DUMPCODE"), "ab");
        if (f) {
            uint32_t w = 0x4F43564A;               /* header: magic, nwords, niv */
            uint32_t nw = (uint32_t)(e.p - start);
            fwrite(&w, 4, 1, f); fwrite(&nw, 4, 1, f); fwrite(&e.niv, 4, 1, f);
            for (uint32_t i = 0; i < e.niv; i++) {
                uint32_t o2 = e.iv_off[i], t = e.iv_tag[i];
                fwrite(&o2, 4, 1, f); fwrite(&t, 4, 1, f);
            }
            fwrite(start, 4, nw, f);
            fclose(f);
        }
    }
    if (j->phfile) {                             /* every code range (the plain and the fused copy), by phase */
        fprintf(j->phfile, "%llx %u %u", (unsigned long long)(uintptr_t)start, (uint32_t)(e.p - start),
                (unsigned)e.niv);
        for (uint32_t i = 0; i < e.niv; i++) fprintf(j->phfile, " %u %u", e.iv_off[i], e.iv_tag[i]);
        fprintf(j->phfile, "\n");
    }
    j->code_cur = (uint8_t *)e.p;
    return 1;
}

/* the dispatcher (chaining), at the code buffer's start: entered at the end of a whole fused block with w0 its
 * instructions (counted), the next pc stored. On to that pc's fused block if there is one in region 0, the
 * budget still holds a block and no window would fill inside it; else out of the chain (back to the caller,
 * returning 0: no block left early) */
static void gen_dispatch(jit_t *j)
{
    const cpu_fuse_t *fz = j->fz;
    j->dispatch = NULL;
    if (!fz || !fz->istate || fz->nstreams <= 0) return;
    em_t e = { 0 };
    e.p = e.b0 = e.start = (uint32_t *)j->code_cur; e.end = (uint32_t *)j->code_end; e.ok = 1; e.tag = JP_EXIT;
    uint32_t *start = e.p, *stop[16]; int ns = 0;
    ldr_x(&e, W16, XS, (uint32_t)OFF_CHN);
    emit(&e, 0x8B204210u);                                       /* add x16, x16, w0, uxtw */
    emit(&e, 0xF9000000u | ((uint32_t)(OFF_CHN / 8) << 10) | (XS << 5) | W16);   /* str x16, chain_n */
    ldr_w(&e, W17, XS, (uint32_t)OFF_BUD);
    dp3(&e, SUBW, W17, W17, W0);
    str_w(&e, W17, XS, (uint32_t)OFF_BUD);
    emit(&e, 0x7100001Fu | (64u << 10) | (W17 << 5));           /* cmp w17, #64 */
    stop[ns] = e.p; emit(&e, 0x54000003u); ns++;                 /* b.lo stop: no whole block left */
    ldr_w(&e, W9, XS, OFF_PC);
    ldr_x(&e, 5, XS, OFF_BASE);
    dp3(&e, SUBW, W5, W9, W5);                                   /* w5 = pc - base0 */
    ldr_x(&e, 6, XS, OFF_SIZE);
    emit(&e, 0xEB0600BFu);                                       /* cmp x5, x6 */
    stop[ns] = e.p; emit(&e, 0x54000002u); ns++;                 /* b.hs stop: not region 0 */
    ldr_x(&e, 7, XS, (uint32_t)OFF_MAP0);
    emit(&e, 0x53017CA5u);                                       /* lsr w5, w5, #1 */
    emit(&e, 0xF86578E7u);                                       /* ldr x7, [x7, x5, lsl #3]: the block */
    stop[ns] = e.p; emit(&e, 0xB4000007u); ns++;                 /* cbz x7, stop: not translated */
    ldr_x(&e, 8, 7, (uint32_t)offsetof(jblock_t, fnb));
    stop[ns] = e.p; emit(&e, 0xB4000008u); ns++;                 /* cbz x8, stop: no chained version */
    for (int k = 0; k <= fz->nstreams; k++) {                    /* every window: room for the block's records */
        if (k < fz->nstreams) {
            ldr_x(&e, W17, XS, (uint32_t)(OFF_FST + 8u * (uint32_t)k));
            emit(&e, 0x79400000u | ((uint32_t)((offsetof(jblock_t, cntf) + 2u * (uint32_t)k) / 2) << 10) | (7u << 5) | W6);   /* ldrh w6 */
        } else {
            ldr_x(&e, W17, XS, (uint32_t)OFF_IST);
            ldr_w(&e, W6, 7, (uint32_t)offsetof(jblock_t, n));
        }
        ldr_w(&e, W16, W17, 0);
        dp3(&e, ADDW, W16, W16, W6);
        ldr_w(&e, W6, W17, 12);
        dp3(&e, SUBSW, XZR, W16, W6);
        stop[ns] = e.p; emit(&e, 0x54000002u); ns++;             /* b.hs stop: it would fill inside */
    }
    emit(&e, 0xF9000000u | ((uint32_t)(OFF_CHL / 8) << 10) | (XS << 5) | 7u);    /* str x7, chain_last */
    ldr_x(&e, W16, XS, (uint32_t)OFF_NCH);
    emit(&e, 0x91000610u);                                       /* add x16, x16, #1 */
    emit(&e, 0xF9000000u | ((uint32_t)(OFF_NCH / 8) << 10) | (XS << 5) | W16);
    emit(&e, 0xD61F0100u);                                       /* br x8 */
    uint32_t *st = e.p;                                          /* stop: out of the chain */
    fz_crc_out(&e, fz);
    movw(&e, W0, 0);
    emit(&e, 0xD65F03C0u);                                       /* ret */
    if (!e.ok) return;
    for (int i = 0; i < ns; i++) {
        uint32_t w = *stop[i];
        if ((w & 0xFF000000u) == 0xB4000000u) cbz_at(stop[i], st, (int)(w & 31u)), *stop[i] |= 0x80000000u;   /* (cbz x) */
        else bcond_at(stop[i], st, (int)(w & 15u));
    }
    __builtin___clear_cache((char *)start, (char *)e.p);
    j->code_cur = (uint8_t *)e.p;
    j->dispatch = start;
}

static jblock_t *translate(jit_t *j, uint32_t pc)
{
    if (j->nblocks == JIT_BLOCKS || j->npool + JIT_MAX > JIT_POOL || j->code_end - j->code_cur < 128 * 1024)
        return NULL;                                              /* full: the caller flushes */
    jblock_t *b = &j->blocks[j->nblocks++];
    b->ins = &j->pool[j->npool];
    b->n = 0; b->fn = NULL; b->fnf = NULL; b->fnb = NULL; b->user = NULL;
    if (!gen(j, pc, b, NULL)) { b->n = 0; return b; }             /* the interpreter runs it */
    const uint32_t n = b->n;
    if (j->fz && !gen(j, pc, b, j->fz)) b->fnf = NULL;            /* (the plain one only) */
    b->n = n;
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
    gen_dispatch(j);
}

static inline void hand_out(jit_t *j, cpu_retire_t *r)
{
    const jins_t *I = &j->cur[j->cur_i];                    /* without branches: masks pick the values */
    const jout_t *o = &j->out[j->cur_i];
    r->order = j->cur_order + j->cur_i; r->pc = I->pc;
    r->pc_next = (o->next & I->m_next) | (I->next & ~I->m_next);
    r->rd_addr = I->rd; r->rd_wdata = o->wdata & I->m_rd;
    r->trap = 0; r->insn = I->insn; r->timing_csr = 0;
    r->raw = I->len == 2 ? I->raw : I->insn;
    r->src1 = j->x0[I->rs1]; r->src2 = j->x0[I->rs2];
    j->x0[I->rd] = r->rd_wdata;                             /* (rd 0: writes 0 to x0[0]) */
    r->mem_we = I->m_store & 1; r->mem_wmask = ((1u << I->store) - 1) & I->m_store;
    r->mem_addr = o->maddr & I->m_store; r->mem_wdata = o->mdata & I->m_store;
    r->csr_we = 0; r->csr_wcmd = 0; r->csr_waddr = 0; r->csr_wdata = 0;
    j->cur_i++;
}

/* the next unit: a translated block into the buffer (returns 1), or one instruction by the interpreter
 * into *r (returns 0) */
/* fusable: the caller takes the block whole (jit_block) and so knows what the fused code did - handed out
 * instruction by instruction (step, step_n) its records and coverage would be made twice */
static int run_next(jit_t *j, cpu_retire_t *r, int fusable)
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
            /* the fused version when no window fills inside it (a full one is closed by the caller) */
            int fused = fusable && b->fnf != NULL;
            for (int s = 0; fused && s < j->fz->nstreams; s++) {
                uint32_t *st = j->fz->s[s].state;
                if (st[0] + b->cntf[s] >= st[3]) fused = 0;
            }
            if (fused && b->fnb && (j->ist[0] + b->n >= j->ist[3] || j->budget < b->n)) fused = 0;   /* (chained: also the issue window, the budget) */
            if (fused) {
                for (int s = 0; s < j->fz->nstreams; s++) {
                    uint32_t *st = j->fz->s[s].state;
                    if (st[0] == 0) st[1] = st[2] = 0xFFFFFFFFu;  /* (a window starts) */
                }
                if (b->fnb && j->ist[0] == 0) j->ist[1] = j->ist[2] = 0xFFFFFFFFu;
            }
            j->chain_n = 0; j->chain_last = b;
            if (!fused) memcpy(j->x0, j->f.x, sizeof j->x0);   /* (the registers before it: for hand_out, cpu_block_t.x;
                                                                 * a fused block is taken whole, its operands not needed) */
            const uint32_t n = (uint32_t)(fused ? b->fnf : b->fn)(j, j->out);
            j->cur_fused = fused; j->n_fused += (uint64_t)fused;
            b->runs++; if (fused) b->runsf++;
            if (fused && b->fnb && j->chain_n) {               /* chained: whole blocks done, then maybe one left early */
                jblock_t *lb = j->chain_last;
                j->n_blocks++;
                j->cur = lb->ins; j->cur_n = n; j->cur_i = 0; j->cur_order = j->f.order + j->chain_n;
                j->cur_key = 0; j->cur_blk = NULL;
                j->f.order += j->chain_n + n;
                return 1;
            }
            if (n) {
                j->n_blocks++;
                j->cur = b->ins; j->cur_n = n; j->cur_i = 0; j->cur_order = j->f.order;
                j->cur_key = n == b->n ? (j->n_flush << 32) | (uint64_t)(b - j->blocks + 1) : 0;   /* (left early: no) */
                j->cur_blk = b;
                j->f.order += n;
                if (j->smc) {                                     /* code written: translate again */
                    memcpy(j->keep, b->ins, n * sizeof *j->keep);
                    j->cur = j->keep; j->cur_key = 0; j->cur_blk = NULL;
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
    if (j->cur_i < j->cur_n || run_next(j, r, 0)) hand_out(j, r);   /* (else the interpreter filled *r) */
}

/* the rest of the running block, or the next block, or one interpreted instruction */
static int jit_step_n(cpu_model_t *mm, cpu_retire_t *r, int n)
{
    jit_t *j = (jit_t *)mm;
    if (j->cur_i == j->cur_n && !run_next(j, r, 0)) return 1;
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
                " (%llu of them not hot yet), %llu blocks run fused, %llu of them chained\n",
                (unsigned long long)j->n_blocks, j->n_blocks ? (double)(j->f.order - j->n_interp) / (double)j->n_blocks : 0.0,
                (unsigned long long)j->n_trans, (unsigned long long)j->n_flush, (unsigned long long)j->n_interp,
                (unsigned long long)j->n_cold, (unsigned long long)(j->n_fused + j->n_chained), (unsigned long long)j->n_chained);
    if (j->phstats) {
        static const char *const nm[JP_N] = { "enter", "arg", "op+mem", "out", "cov.classA", "cov.classB", "cov.bin", "cov.s0s1", "cov.mis", "rec", "exit" };
        uint64_t w[JP_N] = { 0 }, wf[JP_N] = { 0 }, nin = 0;
        for (uint32_t b = 0; b < j->nblocks; b++) {
            const jblock_t *B = &j->blocks[b];
            if (!B->n || (!B->runs && !B->runsf)) continue;
            nin += (uint64_t)B->n * B->runs;
            for (int i = 0; i < JP_N; i++) {
                wf[i] += (uint64_t)B->phf[i] * B->runsf;                          /* the fused runs: fnf */
                w[i] += (uint64_t)B->ph[i] * (B->runs - B->runsf) + (uint64_t)B->phf[i] * B->runsf;
            }
        }
        double tot = 0, totf = 0;
        for (int i = 0; i < JP_N; i++) { tot += (double)w[i]; totf += (double)wf[i]; }
        fprintf(stderr, "jit: generated code: %.2f A72 words per RISC-V instruction (%llu instructions);"
                " fused runs take %.2f\n", nin ? tot / (double)nin : 0.0, (unsigned long long)nin,
                nin ? totf / (double)nin : 0.0);
        for (int i = 0; i < JP_N; i++)
            fprintf(stderr, "jit:   %-10s %6.2f  %4.1f%%  (of the fused runs %6.2f)\n", nm[i],
                    nin ? (double)w[i] / (double)nin : 0.0, tot ? 100.0 * (double)w[i] / tot : 0.0,
                    nin ? (double)wf[i] / (double)nin : 0.0);
    }
    for (int i = 0; i < j->f.nreg; i++) { dec_put(&j->f.reg[i]); free(j->map[i]); free(j->code_map[i]); free(j->hits[i]); }
    if (j->phfile) fclose(j->phfile);
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
    j->phstats = getenv("OCV_JIT_STATS") && !strcmp(getenv("OCV_JIT_STATS"), "phases");
    if (getenv("OCV_JIT_PHASES")) j->phfile = fopen(getenv("OCV_JIT_PHASES"), "w");
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
        return j->x0[i & 31];                                 /* (f.x already holds the whole block) */
    }
    return j->f.x[i & 31];
}
static uint32_t jit_pc(cpu_model_t *m)
{
    jit_t *j = (jit_t *)m;
    if (j->cur_i < j->cur_n) return j->cur[j->cur_i].pc;
    return j->f.pc;
}

/* the next block as a whole (cpu_block_t): its table and outputs as they are, nothing handed out */
static int jit_block(cpu_model_t *mm, cpu_block_t *b, cpu_retire_t *r)
{
    jit_t *j = (jit_t *)mm;
    if (j->cur_i < j->cur_n) { hand_out(j, r); return 0; }
    j->budget = b->budget;
    if (!run_next(j, r, 1)) return 0;                           /* (the interpreter filled *r) */
    b->ins = j->cur; b->out = j->out; b->x = j->x0; b->key = j->cur_key; b->fused = j->cur_fused;
    b->user = j->cur_blk ? &j->cur_blk->user : NULL;
    b->done = 0; b->last = NULL;
    if (j->cur_fused && j->chain_n && j->chain_last->fnb) {    /* chained */
        b->done = j->chain_n;
        if (!j->cur_n) b->last = &j->chain_last->ins[j->chain_last->n - 1];
        j->chain_n = 0;
    }
    j->cur_i = j->cur_n;
    return (int)(b->done + j->cur_n);
}

/* cpu_fuse_t: the translations made from now on have their fused version (the ones there: dropped) */
static int jit_fuse(cpu_model_t *mm, const cpu_fuse_t *f)
{
    jit_t *j = (jit_t *)mm;
    if (f && (f->nstreams > 2 || (f->cov && (!f->cov_plan || f->cls[6] != f->cls[5] + 1)))) return 0;
    for (int s = 0; f && s < f->nstreams; s++)
        if (f->s[s].words < 1 || f->s[s].words > 4 || f->s[s].filter < 0 || f->s[s].filter > 2) return 0;
    if (f && f->istate && (!f->piece || !f->last_off || f->last_off > 4000)) return 0;
    j->fz = f;
    j->cov = f ? f->cov : NULL;
    for (int s = 0; s < 2; s++) j->fst[s] = f && s < f->nstreams ? f->s[s].state : NULL;
    j->ist = f ? f->istate : NULL;
    j->map0 = j->f.nreg ? j->map[0] : NULL;
    jit_flush(j);                                              /* (then the dispatcher, at the buffer's start) */
    return 1;
}
_Static_assert(offsetof(jit_t, n_chained) < 4 * 4000, "jit_t: the fields the generated code reaches by an immediate offset");

static const cpu_impl_t cpu_jit_impl = {
    "jit", "\"fast\" translated block by block into AArch64 code (the board's A72)", 0,
    jit_create, jit_step, jit_xreg, jit_pc, jit_destroy, jit_step_n, jit_interrupt, jit_sync, 1, jit_block, jit_fuse
};
#endif
