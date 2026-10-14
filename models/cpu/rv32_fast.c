/* rv32_fast.c - "fast": the light ISS ("iss", models/cpu/iss/rv32_iss.c) as a predecoding
 * interpreter, for the board where the reference model is the limit. The same semantics instruction for
 * instruction (RV32IMC + Zicsr writes, no traps but ecall/ebreak/illegal, no M-mode CSR state; counters
 * through timing_csr), checked against "iss" record by record (models/cpu/t_fast.c).
 *
 * What is faster: an instruction is fetched, expanded (RVC) and decoded once per address and kept
 * (kind, registers, immediate, length); memory regions are reached through their host pointer without a
 * call; the retirement is written straight into cpu_retire_t. A store into a cached instruction drops
 * its decoding (self-modifying code); memory changed from outside the model after cpu_create is not
 * seen by the cache - load the program before (as the testbenches do).
 *
 * Core profile ":cv32e40p" at the end of the ISA string (e.g. "rv32imc_zicsr_zifencei:cv32e40p"): the
 * machine mode of CV32E40P in its default configuration (RV32IMC, no PULP extensions, no FPU, no PMP,
 * not in debug mode), taken from its RTL (cv32e40p_decoder.sv, cv32e40p_cs_registers.sv): strict
 * decoding (reserved encodings are illegal instructions), its CSR table, exceptions (illegal
 * instruction 2, breakpoint 3, ecall 11) to the mtvec base, mret; interrupts when the caller says the
 * core took one (cpu_interrupt: vectored base + 4 * id). Counters (mcycle, minstret, mhpmcounter*) and
 * mip read through timing_csr (their values are the core's); writes to counters are not modelled.
 *
 * Core profile ":cva6": CVA6 in the cv32a60x configuration as examples/cva6/cva6_ocv_core.sv builds it
 * (RV32IMC, machine mode only, no PMP entries, no debug, no performance counters), from its RTL
 * (csr_regfile.sv, decoder.sv): the same exceptions, and misaligned loads (4) and stores (6) - CVA6 does
 * not split them; mtvec direct only (all traps to its base, bits 1:0 read 0), reset to boot + 0x40; mie
 * holds MTIE and MEIE only (no software interrupt); mstatus.MPP reads M always (no U mode: csr_regfile.sv
 * forces it every cycle, so the reset value 0 lasts one clock); the known erratum openhwfoundation/cva6#3175
 * (an interrupt taken up to ERRATA_MIE_WINDOW instructions after mie disabled it) is told apart (cpu_interrupt 2); mtval reads 0. CSRs with no effect on what the model computes - mip, mcycle(h), minstret(h), the
 * performance counters and event selectors, mcountinhibit, pmpcfg/pmpaddr (no PMP entries), CVA6's cache
 * enables (0x7C0, 0x7C1) - read through timing_csr (the core's values). Every other CSR is illegal.
 */
/* (built as a part of cpu_model.c, which includes this file: one source for the build lists) */

enum {
    OP_ILLEGAL = 0, OP_LUI, OP_AUIPC, OP_JAL, OP_JALR,
    OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU,
    OP_LB, OP_LH, OP_LW, OP_LBU, OP_LHU, OP_LNONE,
    OP_SB, OP_SH, OP_SW, OP_SNONE,
    OP_ADDI, OP_SLTI, OP_SLTIU, OP_XORI, OP_ORI, OP_ANDI, OP_SLLI, OP_SRLI, OP_SRAI,
    OP_ADD, OP_SUB, OP_SLL, OP_SLT, OP_SLTU, OP_XOR, OP_SRL, OP_SRA, OP_OR, OP_AND,
    OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU, OP_DIV, OP_DIVU, OP_REM, OP_REMU,
    OP_FENCE, OP_SYSTEM_TRAP, OP_CSR
};

typedef struct {
    uint8_t  op, rd, rs1, rs2;
    uint8_t  f3, len, valid, pad;
    int32_t  imm;
    uint32_t insn;                       /* 32-bit form (RVC expanded), for cpu_retire_t.insn */
} dec_t;                                 /* 16 bytes: a cache line holds 4 (with the raw bits it held 3.2) */

typedef struct {
    uint32_t base, size;
    uint8_t *host;
    dec_t   *dec;                        /* size/2 entries: one per 2-byte aligned address */
    uint32_t dlo, dhi;                   /* the entries decoded so far lie in [dlo, dhi] (dec_put/dec_get) */
} fregion_t;

/* decode tables kept from one model to the next (a model per program: calloc of megabytes each time was ~6% of a
 * generated-test run); a table comes back cleared only where it was used */
static struct { dec_t *dec; uint32_t size, lo, hi; } dec_spare[8];
static dec_t *dec_get(uint32_t entries)
{
    for (int i = 0; i < 8; i++)
        if (dec_spare[i].dec && dec_spare[i].size == entries) {
            dec_t *d = dec_spare[i].dec;
            if (dec_spare[i].lo <= dec_spare[i].hi)
                memset(d + dec_spare[i].lo, 0, (size_t)(dec_spare[i].hi - dec_spare[i].lo + 1) * sizeof *d);
            dec_spare[i].dec = NULL;
            return d;
        }
    return calloc(entries, sizeof(dec_t));
}
static void dec_put(fregion_t *r)
{
    if (!r->dec) return;
    for (int i = 0; i < 8; i++)
        if (!dec_spare[i].dec) {
            dec_spare[i].dec = r->dec; dec_spare[i].size = r->size / 2; dec_spare[i].lo = r->dlo; dec_spare[i].hi = r->dhi;
            r->dec = NULL;
            return;
        }
    free(r->dec);
    r->dec = NULL;
}

typedef struct {
    cpu_model_t base;
    cpu_env_t   env;
    uint32_t    x[32];
    uint32_t    pc;
    uint64_t    order;
    int         nreg;
    fregion_t   reg[8];
    int         hint[2];                 /* the region of the last fetch [0] and data access [1] (indexes: jit
                                          * copies this struct); one hint flipped between code and stack */
    /* core profile ":cv32e40p" / ":cva6": machine-mode state (cva6: the profile is CVA6's) */
    int         cv32, cva6;
    uint32_t    mie_b, mpie_b, mie, mtvec, mtvec_mode, mscratch, mepc, mcause;
    uint32_t    mpp;                     /* cva6: mstatus.MPP (M: no U mode) */
    /* cva6: known erratum openhwfoundation/cva6#3175 - a write to mie does not flush the pipeline, so
     * an interrupt may still be taken a few instructions after it was disabled: the mie before the last
     * write and where that write was */
    int         errata_mie;
    uint32_t    mie_prev;
    uint64_t    mie_wr;
} fast_t;

#define ERRATA_MIE_WINDOW 4   /* instructions after a write of mie that #3175 may still use the old value */

static inline int32_t sext(uint32_t v, int b) { int32_t m = 1 << (b - 1); return (int32_t)((v ^ (uint32_t)m) - (uint32_t)m); }

static inline fregion_t *region_in(fast_t *m, uint32_t a, uint32_t n, int h)
{
    fregion_t *r = &m->reg[m->hint[h]];       /* the last such access's region first: one compare usually */
    if (m->nreg && a - r->base < r->size && r->size - (a - r->base) >= n) return r;
    for (int i = 0; i < m->nreg; i++) {
        r = &m->reg[i];
        if (a - r->base < r->size && r->size - (a - r->base) >= n) { m->hint[h] = i; return r; }
    }
    return NULL;
}
static inline fregion_t *region_of(fast_t *m, uint32_t a, uint32_t n) { return region_in(m, a, n, 1); }   /* data */

static inline uint32_t load(fast_t *m, uint32_t a, int n)
{
    fregion_t *r = region_of(m, a, (uint32_t)n);
    if (r) {
        uint32_t v = 0;
        memcpy(&v, r->host + (a - r->base), (size_t)n);   /* little-endian host, as cpu_env_load */
        return v;
    }
    return cpu_env_load(&m->env, a, n);
}

static inline void store(fast_t *m, uint32_t a, int n, uint32_t v)
{
    fregion_t *r = region_of(m, a, (uint32_t)n);
    if (r) {
        uint32_t o = a - r->base;
        for (int i = 0; i < n; i++) r->host[o + i] = (uint8_t)(v >> (8 * i));
        /* an instruction starting up to 2 bytes before, or inside, is decoded again */
        uint32_t lo = o >= 2 ? (o - 2) >> 1 : 0, hi = (o + (uint32_t)n - 1) >> 1;
        for (uint32_t k = lo; k <= hi && k < r->size / 2; k++) r->dec[k].valid = 0;
        return;
    }
    cpu_env_store(&m->env, a, n, v);
}

/* CV32E40P's decoder: encodings the light model executes as something are illegal there */
static int cv32_reserved(uint32_t insn)
{
    const uint32_t op = insn & 0x7f, f3 = (insn >> 12) & 7, f7 = insn >> 25;
    switch (op) {
    case 0x37: case 0x17: case 0x6f: return 0;
    case 0x67: return f3 != 0;
    case 0x63: return f3 == 2 || f3 == 3;
    case 0x03: return f3 == 3 || f3 >= 6;
    case 0x23: return f3 >= 3;
    case 0x13: return (f3 == 1 && f7 != 0) || (f3 == 5 && f7 != 0 && f7 != 0x20);
    case 0x33: return !(f7 == 0 || f7 == 1 || (f7 == 0x20 && (f3 == 0 || f3 == 5)));
    case 0x0f: return f3 > 1;
    case 0x73: return f3 == 4;
    default:   return 1;
    }
}

static void decode(uint32_t insn, uint32_t ilen, dec_t *d)
{
    uint32_t opcode = insn & 0x7f, rd = (insn >> 7) & 0x1f, f3 = (insn >> 12) & 7, rs1 = (insn >> 15) & 0x1f,
             rs2 = (insn >> 20) & 0x1f, f7 = (insn >> 25) & 0x7f;
    memset(d, 0, sizeof *d);
    d->rd = (uint8_t)rd; d->rs1 = (uint8_t)rs1; d->rs2 = (uint8_t)rs2; d->f3 = (uint8_t)f3;
    d->len = (uint8_t)ilen; d->insn = insn; d->valid = 1;
    switch (opcode) {
    case 0x37: d->op = OP_LUI; d->imm = (int32_t)(insn & 0xfffff000); break;
    case 0x17: d->op = OP_AUIPC; d->imm = (int32_t)(insn & 0xfffff000); break;
    case 0x6f:
        d->op = OP_JAL;
        d->imm = (sext(((insn >> 31) & 1), 1) << 20) | (int32_t)(insn & 0xff000) | (int32_t)(((insn >> 20) & 1) << 11) |
                 (int32_t)(((insn >> 21) & 0x3ff) << 1);
        break;
    case 0x67: d->op = OP_JALR; d->imm = sext(insn >> 20, 12); break;
    case 0x63: {
        static const uint8_t b[8] = { OP_BEQ, OP_BNE, OP_FENCE, OP_FENCE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU };
        d->op = b[f3];                   /* f3 2/3: no branch, falls through (as the ISS: t = 0) */
        d->imm = (sext((insn >> 31) & 1, 1) << 12) | (int32_t)(((insn >> 7) & 1) << 11) |
                 (int32_t)(((insn >> 25) & 0x3f) << 5) | (int32_t)(((insn >> 8) & 0xf) << 1);
        break;
    }
    case 0x03: {
        static const uint8_t l[8] = { OP_LB, OP_LH, OP_LW, OP_LNONE, OP_LBU, OP_LHU, OP_LNONE, OP_LNONE };
        d->op = l[f3]; d->imm = sext(insn >> 20, 12);
        break;
    }
    case 0x23: {
        static const uint8_t st[8] = { OP_SB, OP_SH, OP_SW, OP_SNONE, OP_SNONE, OP_SNONE, OP_SNONE, OP_SNONE };
        d->op = st[f3]; d->imm = (sext(insn >> 25, 7) << 5) | (int32_t)((insn >> 7) & 0x1f);
        break;
    }
    case 0x13: {
        static const uint8_t im[8] = { OP_ADDI, OP_SLLI, OP_SLTI, OP_SLTIU, OP_XORI, OP_SRLI, OP_ORI, OP_ANDI };
        d->op = im[f3];
        if (f3 == 5 && (f7 & 0x20)) d->op = OP_SRAI;
        d->imm = (f3 == 1 || f3 == 5) ? (int32_t)((insn >> 20) & 0x1f) : sext(insn >> 20, 12);
        break;
    }
    case 0x33:
        if (f7 == 1) {
            static const uint8_t mo[8] = { OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU, OP_DIV, OP_DIVU, OP_REM, OP_REMU };
            d->op = mo[f3];
        } else {
            static const uint8_t ro[8] = { OP_ADD, OP_SLL, OP_SLT, OP_SLTU, OP_XOR, OP_SRL, OP_OR, OP_AND };
            d->op = ro[f3];
            if (f3 == 0 && (f7 & 0x20)) d->op = OP_SUB;
            if (f3 == 5 && (f7 & 0x20)) d->op = OP_SRA;
        }
        break;
    case 0x0f: d->op = OP_FENCE; break;
    case 0x73: d->op = f3 == 0 ? OP_SYSTEM_TRAP : OP_CSR; d->imm = (int32_t)(insn >> 20); break;
    default: d->op = OP_ILLEGAL; break;
    }
}

static void decode_m(fast_t *m, uint32_t insn, uint32_t ilen, dec_t *d)
{
    decode(insn, ilen, d);
    if (m->cv32 && (insn == 0 || cv32_reserved(insn))) d->op = OP_ILLEGAL;
}

/* the decoding of the instruction at pc: cached for a host region, else made now into *tmp */
static inline const dec_t *fetch(fast_t *m, uint32_t pc, dec_t *tmp)
{
    fregion_t *r = region_in(m, pc, 2, 0);
    if (r) {
        dec_t *d = &r->dec[(pc - r->base) >> 1];
        if (d->valid) return d;
        uint32_t raw = load(m, pc, 2), insn, ilen;
        if ((raw & 3) != 3) { insn = rv32_rvc_expand((uint16_t)raw); ilen = 2; }
        else { insn = load(m, pc, 4); ilen = 4; }
        decode_m(m, insn, ilen, d);
        const uint32_t k = (pc - r->base) >> 1;
        if (k < r->dlo) r->dlo = k;
        if (k > r->dhi) r->dhi = k;
        if (ilen == 2 || region_of(m, pc, 4) == r) return d;   /* cached only if wholly inside */
        d->valid = 0;
        *tmp = *d;
        return tmp;
    }
    uint32_t raw = load(m, pc, 2), insn, ilen;
    if ((raw & 3) != 3) { insn = rv32_rvc_expand((uint16_t)raw); ilen = 2; }
    else { insn = load(m, pc, 4); ilen = 4; }
    decode_m(m, insn, ilen, tmp);
    return tmp;
}

/* ---- CV32E40P machine mode (cv32e40p_cs_registers.sv, PULP_SECURE = 0) ---- */
enum { CV32_ILLEGAL = 2, CV32_BREAKPOINT = 3, CV32_ECALL = 11 };

static int cv32_counter(uint32_t c)
{
    return (c >= 0xB00 && c <= 0xB1F && c != 0xB01) || (c >= 0xB80 && c <= 0xB9F && c != 0xB81) ||
           c == 0x320 || (c >= 0x323 && c <= 0x33F);
}
static int cv32_user_counter(uint32_t c)
{
    return (c >= 0xC00 && c <= 0xC1F && c != 0xC01) || (c >= 0xC80 && c <= 0xC9F && c != 0xC81);
}

/* is the access legal (the decoder's csr_illegal), and the value it reads (*value; 1 = from
 * timing_csr) */
static int cv32_csr_read(fast_t *m, uint32_t c, int write, uint32_t *value, int *timing)
{
    *timing = 0;
    switch (c) {
    case 0x300: *value = 0x1800u | m->mpie_b << 7 | m->mie_b << 3; return 1;
    case 0x301: *value = 0x40001104u; return 1;                   /* misa: RV32 I M C */
    case 0x304: *value = m->mie; return 1;
    case 0x305: *value = m->mtvec << 8 | m->mtvec_mode; return 1;
    case 0x340: *value = m->mscratch; return 1;
    case 0x341: *value = m->mepc; return 1;
    case 0x342: *value = (m->mcause >> 5) << 31 | (m->mcause & 0x1f); return 1;
    case 0x343: *value = 0; return 1;                             /* mtval */
    case 0x344: *value = 0; *timing = 1; return 1;                /* mip: the lines as the core saw them */
    case 0xF11: *value = 0x602; return !write;                    /* mvendorid */
    case 0xF12: *value = 4; return !write;                        /* marchid */
    case 0xF13: case 0xF14: *value = 0; return !write;            /* mimpid, mhartid */
    case 0x7A0: case 0x7A1: case 0x7A2: case 0x7A3: case 0x7A4: case 0x7A8: case 0x5A8:
        *value = 0; return 1;                                     /* trigger registers (read 0 here) */
    default: break;
    }
    if (cv32_counter(c) || cv32_user_counter(c)) {
        *value = 0; *timing = c < 0xB80 || (c >= 0xC00 && c < 0xC80) ? 1 : 2;
        return !(cv32_user_counter(c) && write);
    }
    return 0;
}

static void cv32_csr_write(fast_t *m, uint32_t c, uint32_t v)
{
    switch (c) {
    case 0x300: m->mie_b = (v >> 3) & 1; m->mpie_b = (v >> 7) & 1; break;
    case 0x304: m->mie = v & 0xFFFF0888u; break;
    case 0x305: m->mtvec = v >> 8; m->mtvec_mode = v & 1; break;
    case 0x340: m->mscratch = v; break;
    case 0x341: m->mepc = v & ~1u; break;
    case 0x342: m->mcause = (v >> 31) << 5 | (v & 0x1f); break;
    default: break;                                               /* read-only bits, counters */
    }
}

/* the trap vector's base: CV32E40P keeps bits 31:8 (vectored), CVA6 bits 31:2 (direct only) */
static inline uint32_t tvec_base(const fast_t *m) { return m->cva6 ? m->mtvec << 2 : m->mtvec << 8; }

/* take an exception: the next pc */
static uint32_t cv32_trap(fast_t *m, uint32_t pc, uint32_t cause)
{
    m->mpie_b = m->mie_b; m->mie_b = 0;
    m->mepc = pc; m->mcause = cause;
    m->mpp = 3;
    return tvec_base(m);                                          /* exceptions: the base, also vectored */
}

/* ---- CVA6 machine mode (csr_regfile.sv, cv32a60x as cva6_ocv_core.sv) ---- */
enum { CVA6_LD_MISALIGNED = 4, CVA6_ST_MISALIGNED = 6 };

static int cva6_timing(uint32_t c)
{
    return c == 0x344 || c == 0xB00 || c == 0xB02 || c == 0xB80 || c == 0xB82 || c == 0x320 ||
           (c >= 0xB03 && c <= 0xB1F) || (c >= 0xB83 && c <= 0xB9F) || (c >= 0x323 && c <= 0x33F) ||
           (c >= 0x3A0 && c <= 0x3AF) || (c >= 0x3B0 && c <= 0x3EF) || c == 0x7C0 || c == 0x7C1;
}

static int cva6_csr_read(fast_t *m, uint32_t c, int write, uint32_t *value, int *timing)
{
    *timing = 0;
    if (write && (c >> 10) == 3) return 0;                       /* a read-only CSR written */
    switch (c) {
    case 0x300: *value = m->mpp << 11 | m->mpie_b << 7 | m->mie_b << 3; return 1;
    case 0x310: *value = 0; return 1;                             /* mstatush (MBE: not written by the tests) */
    case 0x301: *value = 0x40001104u; return 1;                   /* misa: RV32 I M C */
    case 0x304: *value = m->mie; return 1;
    case 0x305: *value = m->mtvec << 2; return 1;
    case 0x340: *value = m->mscratch; return 1;
    case 0x341: *value = m->mepc; return 1;
    case 0x342: *value = (m->mcause >> 5) << 31 | (m->mcause & 0x1f); return 1;
    case 0x343: *value = 0; return 1;                             /* mtval (TvalEn = 0) */
    case 0xF11: *value = 0x602; return 1;                         /* mvendorid */
    case 0xF12: *value = 3; return 1;                             /* marchid */
    case 0xF13: case 0xF14: case 0xF15: *value = 0; return 1;     /* mimpid, mhartid, mconfigptr */
    default: break;
    }
    if (cva6_timing(c)) { *value = 0; *timing = (c >= 0xB80 && c <= 0xB9F) ? 2 : 1; return 1; }
    return 0;
}

static void cva6_csr_write(fast_t *m, uint32_t c, uint32_t v)
{
    switch (c) {
    case 0x300: m->mie_b = (v >> 3) & 1; m->mpie_b = (v >> 7) & 1; if (((v >> 11) & 3) == 3) m->mpp = 3; break;
    case 0x304: m->mie_prev = m->mie; m->mie_wr = m->order; m->mie = v & 0x880u; break;
    case 0x305: m->mtvec = v >> 2; break;
    case 0x340: m->mscratch = v; break;
    case 0x341: m->mepc = v & ~1u; break;
    case 0x342: m->mcause = (v >> 31) << 5 | (v & 0x1f); break;
    default: break;                                               /* WARL, read-only bits, the core's values */
    }
}

/* an interrupt: as the core takes it (machine mode, vectored: base + 4 * id) */
static int fast_interrupt(cpu_model_t *mm, uint32_t id)
{
    fast_t *m = (fast_t *)mm;
    if (!m->cv32) return -1;
    int allowed = m->mie_b && (m->mie >> (id & 31) & 1);
    /* 2: allowed only by the mie before a write a few instructions ago - the core's known erratum */
    if (!allowed && m->errata_mie && m->mie_b && (m->mie_prev >> (id & 31) & 1) && m->order - m->mie_wr <= ERRATA_MIE_WINDOW)
        allowed = 2;
    m->mpie_b = m->mie_b; m->mie_b = 0;
    m->mepc = m->pc; m->mcause = 1u << 5 | (id & 31);
    m->mpp = 3;
    m->pc = tvec_base(m) + (m->mtvec_mode && !m->cva6 ? 4 * (id & 31) : 0);
    return allowed;
}

static void fast_step(cpu_model_t *mm, cpu_retire_t *r)
{
    fast_t *m = (fast_t *)mm;
    uint32_t *x = m->x, pc = m->pc;
    dec_t tmp;
    const dec_t *d = fetch(m, pc, &tmp);
    const uint32_t a = x[d->rs1], b = x[d->rs2];
    uint32_t raw = d->insn;                    /* (a compressed one's own 16 bits: read where it was fetched) */
    if (d->len == 2) {
        const fregion_t *cr = region_in(m, pc, 2, 0);
        raw = cr ? (uint32_t)cr->host[pc - cr->base] | (uint32_t)cr->host[pc - cr->base + 1] << 8 : load(m, pc, 2);
    }
    uint32_t next = pc + d->len, wv = 0;
    int wen = 0, trap = 0, mask_rdd = 0;
    uint32_t mwe = 0, mmask = 0, maddr = 0, mdata = 0, cwe = 0, ccmd = 0, caddr = 0, cdata = 0;
    switch (d->op) {
    case OP_LUI:   wv = (uint32_t)d->imm; wen = 1; break;
    case OP_AUIPC: wv = pc + (uint32_t)d->imm; wen = 1; break;
    case OP_JAL:   wv = pc + d->len; wen = 1; next = pc + (uint32_t)d->imm; break;
    case OP_JALR:  wv = pc + d->len; wen = 1; next = (a + (uint32_t)d->imm) & ~1u; break;
    case OP_BEQ:   if (a == b) next = pc + (uint32_t)d->imm; break;
    case OP_BNE:   if (a != b) next = pc + (uint32_t)d->imm; break;
    case OP_BLT:   if ((int32_t)a < (int32_t)b) next = pc + (uint32_t)d->imm; break;
    case OP_BGE:   if ((int32_t)a >= (int32_t)b) next = pc + (uint32_t)d->imm; break;
    case OP_BLTU:  if (a < b) next = pc + (uint32_t)d->imm; break;
    case OP_BGEU:  if (a >= b) next = pc + (uint32_t)d->imm; break;
    case OP_LH: case OP_LHU: case OP_LW:
        if (m->cva6 && ((a + (uint32_t)d->imm) & (d->op == OP_LW ? 3u : 1u))) {   /* CVA6: not split */
            next = cv32_trap(m, pc, CVA6_LD_MISALIGNED); trap = 1; break;
        }
        wen = 1;
        wv = d->op == OP_LW ? load(m, a + (uint32_t)d->imm, 4)
           : d->op == OP_LH ? (uint32_t)(int32_t)(int16_t)load(m, a + (uint32_t)d->imm, 2) : load(m, a + (uint32_t)d->imm, 2);
        break;
    case OP_LB:    wen = 1; wv = (uint32_t)(int32_t)(int8_t)load(m, a + (uint32_t)d->imm, 1); break;
    case OP_LBU:   wen = 1; wv = load(m, a + (uint32_t)d->imm, 1); break;
    case OP_LNONE: wen = 1; break;                                   /* as the ISS: rd gets 0 */
    case OP_SB: case OP_SH: case OP_SW: {
        const uint32_t ad = a + (uint32_t)d->imm, f3 = d->f3;
        if (m->cva6 && (ad & ((1u << f3) - 1))) { next = cv32_trap(m, pc, CVA6_ST_MISALIGNED); trap = 1; break; }
        store(m, ad, 1 << f3, b);
        mwe = 1; mmask = (1u << (1u << f3)) - 1; maddr = ad;
        mdata = b & (f3 == 2 ? 0xffffffffu : (1u << (8u << f3)) - 1);
        break;
    }
    case OP_SNONE: break;
    case OP_ADDI:  wen = 1; wv = a + (uint32_t)d->imm; break;
    case OP_SLTI:  wen = 1; wv = (int32_t)a < d->imm; break;
    case OP_SLTIU: wen = 1; wv = a < (uint32_t)d->imm; break;
    case OP_XORI:  wen = 1; wv = a ^ (uint32_t)d->imm; break;
    case OP_ORI:   wen = 1; wv = a | (uint32_t)d->imm; break;
    case OP_ANDI:  wen = 1; wv = a & (uint32_t)d->imm; break;
    case OP_SLLI:  wen = 1; wv = a << d->imm; break;
    case OP_SRLI:  wen = 1; wv = a >> d->imm; break;
    case OP_SRAI:  wen = 1; wv = (uint32_t)((int32_t)a >> d->imm); break;
    case OP_ADD:   wen = 1; wv = a + b; break;
    case OP_SUB:   wen = 1; wv = a - b; break;
    case OP_SLL:   wen = 1; wv = a << (b & 31); break;
    case OP_SLT:   wen = 1; wv = (int32_t)a < (int32_t)b; break;
    case OP_SLTU:  wen = 1; wv = a < b; break;
    case OP_XOR:   wen = 1; wv = a ^ b; break;
    case OP_SRL:   wen = 1; wv = a >> (b & 31); break;
    case OP_SRA:   wen = 1; wv = (uint32_t)((int32_t)a >> (b & 31)); break;
    case OP_OR:    wen = 1; wv = a | b; break;
    case OP_AND:   wen = 1; wv = a & b; break;
    case OP_MUL:   wen = 1; wv = a * b; break;
    case OP_MULH:  wen = 1; wv = (uint32_t)(((int64_t)(int32_t)a * (int64_t)(int32_t)b) >> 32); break;
    case OP_MULHSU: wen = 1; wv = (uint32_t)(((int64_t)(int32_t)a * (int64_t)(uint64_t)b) >> 32); break;
    case OP_MULHU: wen = 1; wv = (uint32_t)(((uint64_t)a * (uint64_t)b) >> 32); break;
    case OP_DIV:   wen = 1;
        wv = b == 0 ? 0xffffffffu : (a == 0x80000000u && b == 0xffffffffu) ? 0x80000000u : (uint32_t)((int32_t)a / (int32_t)b);
        break;
    case OP_DIVU:  wen = 1; wv = b == 0 ? 0xffffffffu : a / b; break;
    case OP_REM:   wen = 1;
        wv = b == 0 ? a : (a == 0x80000000u && b == 0xffffffffu) ? 0 : (uint32_t)((int32_t)a % (int32_t)b);
        break;
    case OP_REMU:  wen = 1; wv = b == 0 ? a : a % b; break;
    case OP_FENCE: break;
    case OP_SYSTEM_TRAP:
        if (m->cv32) {
            const uint32_t f = d->insn >> 20;
            if ((d->insn & 0x000FFF80u) != 0) next = cv32_trap(m, pc, CV32_ILLEGAL), trap = 1;
            else if (f == 0x000) next = cv32_trap(m, pc, CV32_ECALL), trap = 1;
            else if (f == 0x001) next = cv32_trap(m, pc, CV32_BREAKPOINT), trap = 1;
            else if (f == 0x302) { next = m->mepc; m->mie_b = m->mpie_b; m->mpie_b = 1; m->mpp = 3; }   /* mret */
            else if (f == 0x105) { }                                 /* wfi: no interrupts here - a nop */
            else next = cv32_trap(m, pc, CV32_ILLEGAL), trap = 1;
            break;
        }
        trap = 1;
        break;
    case OP_CSR:
        if (m->cv32) {
            const uint32_t csr = (uint32_t)d->imm, f3 = d->f3, src = (f3 & 4) ? d->rs1 : a;
            const int write = (f3 & 3) == 1 || d->rs1;
            uint32_t old;
            int timing;
            if (!(m->cva6 ? cva6_csr_read(m, csr, write, &old, &timing) : cv32_csr_read(m, csr, write, &old, &timing))) {
                next = cv32_trap(m, pc, CV32_ILLEGAL); trap = 1; break;
            }
            if (timing) {
                mask_rdd = 1;
                if (!(m->env.timing_csr && m->env.timing_csr(m->env.ctx, csr, m->order, &old)))
                    old = timing == 1 ? (uint32_t)m->order : (uint32_t)(m->order >> 32);
            }
            if (write) {
                cwe = 1; ccmd = (f3 & 3) - 1; caddr = csr; cdata = src;
                const uint32_t nv = (f3 & 3) == 1 ? src : (f3 & 3) == 2 ? old | src : old & ~src;
                if (m->cva6) cva6_csr_write(m, csr, nv); else cv32_csr_write(m, csr, nv);
            }
            if (d->rd) { wv = old; wen = 1; }
            break;
        }
        {
        const uint32_t csr = (uint32_t)d->imm, f3 = d->f3;
        uint32_t old = 0;
        mask_rdd = rv32_is_timing_csr(csr);
        if (mask_rdd && m->env.timing_csr && m->env.timing_csr(m->env.ctx, csr, m->order, &old)) {
        } else if (csr == 0xB02 || csr == 0xC02) old = (uint32_t)m->order;
        else if (csr == 0xB82 || csr == 0xC82) old = (uint32_t)(m->order >> 32);
        else old = 0;
        const uint32_t src = (f3 & 4) ? d->rs1 : a;
        if ((f3 & 3) == 1 || d->rs1) { cwe = 1; ccmd = (f3 & 3) - 1; caddr = csr; cdata = src; }
        if (d->rd) { wv = old; wen = 1; }
        }
        break;
    default:                                                         /* illegal */
        trap = 1;
        if (m->cv32) next = cv32_trap(m, pc, CV32_ILLEGAL);
        break;
    }
    if (d->rd == 0) wen = 0;
    r->order = m->order; r->pc = pc; r->pc_next = next;
    r->rd_addr = wen ? d->rd : 0; r->rd_wdata = wen ? wv : 0;
    r->trap = (uint32_t)trap; r->insn = d->insn; r->timing_csr = (uint32_t)mask_rdd;
    r->raw = raw; r->src1 = a; r->src2 = b;
    r->mem_we = mwe; r->mem_wmask = mmask; r->mem_addr = maddr; r->mem_wdata = mdata;
    r->csr_we = cwe; r->csr_wcmd = ccmd; r->csr_waddr = caddr; r->csr_wdata = cdata;
    if (wen) x[d->rd] = wv;
    x[0] = 0;
    m->order++;
    m->pc = next;
}

const cpu_impl_t cpu_fast_impl;

static void fast_destroy(cpu_model_t *mm)
{
    fast_t *m = (fast_t *)mm;
    for (int i = 0; i < m->nreg; i++) dec_put(&m->reg[i]);
    free(m);
}

static cpu_model_t *fast_create(const char *isa, const cpu_env_t *env, uint32_t reset_pc, char *err, size_t n)
{
    fast_t *m = calloc(1, sizeof *m);
    if (!m) { snprintf(err, n, "out of memory"); return NULL; }
    m->base.impl = &cpu_fast_impl;
    m->env = *env;
    m->pc = reset_pc;
    const char *prof = isa ? strchr(isa, ':') : NULL;
    if (prof && !strcmp(prof + 1, "cv32e40p")) { m->cv32 = 1; m->mtvec_mode = 1; }
    else if (prof && !strcmp(prof + 1, "cva6")) { m->cv32 = m->cva6 = 1; m->mtvec = (reset_pc + 0x40) >> 2; m->mpp = 3; m->errata_mie = 1; }
    else if (prof) { snprintf(err, n, "fast: unknown core profile '%s'", prof + 1); free(m); return NULL; }
    for (int i = 0; i < env->n_regions && m->nreg < 8; i++) {
        const cpu_region_t *r = &env->regions[i];
        if (!r->host || r->size < 2) continue;
        fregion_t *f = &m->reg[m->nreg];
        f->base = r->base; f->size = r->size; f->host = r->host;
        f->dlo = ~0u; f->dhi = 0;
        if (!(f->dec = dec_get(r->size / 2))) { fast_destroy(&m->base); snprintf(err, n, "out of memory"); return NULL; }
        m->nreg++;
    }
    return &m->base;
}

static uint32_t fast_xreg(cpu_model_t *m, int i) { return ((fast_t *)m)->x[i & 31]; }
static uint32_t fast_pc(cpu_model_t *m) { return ((fast_t *)m)->pc; }

const cpu_impl_t cpu_fast_impl = {
    "fast", "\"iss\" as a predecoding interpreter (same semantics, faster on the board)", 0,
    fast_create, fast_step, fast_xreg, fast_pc, fast_destroy, NULL, fast_interrupt, NULL, 1
};
