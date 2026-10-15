/* cv32_cov.c - see cv32_cov.h (the RV32IM part as examples/scr1/scr1_cov.c). */
#include "cv32_cov.h"

#include <string.h>

static int n_ops[COV_NG] = { 10, 8, 6, 3, 6, 8, 6, COV_NX, COV_NC, COV_NM, COV_NIRQ };
static const int n_c2[COV_NG]  = { COV_NV, COV_NV, COV_NI, COV_NS, COV_NV, 1, 2, 1, 1, 1, 1 };
static const int n_c1[COV_NG]  = { COV_NV, COV_NV, COV_NV, COV_NV, COV_NV, 1, COV_NCSR, 1, 1, 1, 1 };
static const char *const names[COV_NG] = { "ALU reg-reg", "mul/div", "ALU immediate", "shift immediate",
                                           "branch", "load/store", "CSR", "exception", "compressed",
                                           "misaligned", "interrupt" };
static const uint8_t irqs_cv32[COV_NIRQ] = { 3, 7, 11, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31 };
static const uint8_t irqs_cva6[2] = { 7, 11 };
const uint8_t *cov_irqs = irqs_cv32;
int cov_nirq = COV_NIRQ;
static int cva6;

void cov_profile(int core)
{
    cva6 = core == 1;
    cov_irqs = cva6 ? irqs_cva6 : irqs_cv32;
    cov_nirq = cva6 ? 2 : COV_NIRQ;
    n_ops[COV_G_IRQ] = cov_nirq;
}


const uint32_t cov_csrs[COV_NCSR] = { 0x300, 0x301, 0x304, 0x305, 0x340, 0x341, 0x342, 0x343, 0x344,
                                      0xF11, 0xF12, 0xF13, 0xF14 };

#define MAXB (10 * COV_NV * COV_NV)           /* the largest group (CSR: 6 x 13 x 2 is smaller) */
static uint32_t hits[COV_NG][MAXB];

static unsigned idx(int g, int op, int c1, int c2) { return ((unsigned)op * n_c1[g] + c1) * n_c2[g] + c2; }
static unsigned group_bins(int g) { return (unsigned)(n_ops[g] * n_c1[g] * n_c2[g]); }

int cov_class(uint32_t v)
{
    if (v == 0) return COV_V_ZERO;
    if (v == 1) return COV_V_ONE;
    if (v == 0xFFFFFFFFu) return COV_V_M1;
    if (v == 0x80000000u) return COV_V_MIN;
    if (v == 0x7FFFFFFFu) return COV_V_MAX;
    return (v >> 31) ? COV_V_NEG : COV_V_POS;
}

static int imm_class(int32_t imm)
{
    if (imm == 0) return COV_I_ZERO;
    if (imm == 1) return COV_I_ONE;
    if (imm == -1) return COV_I_M1;
    return imm > 0 ? COV_I_POS : COV_I_NEG;
}

static int sh_class(unsigned sh) { return sh == 0 ? COV_S_ZERO : sh == 1 ? COV_S_ONE : sh == 31 ? COV_S_31 : COV_S_OTHER; }

void cov_reset(void) { memset(hits, 0, sizeof hits); }

uint32_t cov_irq_unhit(void)
{
    uint32_t m = 0;
    for (int i = 0; i < cov_nirq; i++) if (!hits[COV_G_IRQ][i]) m |= 1u << cov_irqs[i];
    return m;
}

void cov_irq(uint32_t id)
{
    for (int i = 0; i < cov_nirq; i++) if (cov_irqs[i] == id) hits[COV_G_IRQ][i]++;
}

static void cov_insn(uint32_t insn, uint32_t a, uint32_t b)
{
    unsigned opc = insn & 0x7F, f3 = (insn >> 12) & 7, f7 = insn >> 25;
    int32_t imm = (int32_t)insn >> 20;
    static const int alu_op[8] = { 0, 2, 3, 4, 5, 6, 8, 9 };     /* f3 -> add sll slt sltu xor srl or and */
    static const int alui_op[8] = { 0, -1, 1, 2, 3, -1, 4, 5 };  /* f3 -> addi - slti sltiu xori - ori andi */
    static const int br_op[8] = { 0, 1, -1, -1, 2, 3, 4, 5 };
    switch (opc) {
    case 0x33:
        if (f7 == 0x01) { hits[COV_G_MUL][idx(COV_G_MUL, (int)f3, cov_class(a), cov_class(b))]++; break; }
        {
            int op = alu_op[f3];
            if (f7 == 0x20 && f3 == 0) op = 1;                      /* sub */
            if (f7 == 0x20 && f3 == 5) op = 7;                      /* sra */
            hits[COV_G_ALU][idx(COV_G_ALU, op, cov_class(a), cov_class(b))]++;
        }
        break;
    case 0x13:
        if (f3 == 1 || f3 == 5) {                                   /* slli / srli / srai */
            int op = f3 == 1 ? 0 : (f7 == 0x20 ? 2 : 1);
            hits[COV_G_SHI][idx(COV_G_SHI, op, cov_class(a), sh_class((insn >> 20) & 31))]++;
        } else {
            hits[COV_G_ALUI][idx(COV_G_ALUI, alui_op[f3], cov_class(a), imm_class(imm))]++;
        }
        break;
    case 0x63:
        if (br_op[f3] >= 0) hits[COV_G_BR][idx(COV_G_BR, br_op[f3], cov_class(a), cov_class(b))]++;
        break;
    case 0x03: {
        static const int ld[8] = { 0, 1, 2, -1, 3, 4, -1, -1 };
        if (ld[f3] >= 0) hits[COV_G_MEM][idx(COV_G_MEM, ld[f3], 0, 0)]++;
        break;
    }
    case 0x23:
        if (f3 <= 2) hits[COV_G_MEM][idx(COV_G_MEM, 5 + (int)f3, 0, 0)]++;
        break;
    default:
        break;
    }
}

static int rvc_kind(uint32_t c)
{
    const uint32_t q = c & 3, f3 = (c >> 13) & 7, rd = (c >> 7) & 31, rs2 = (c >> 2) & 31, b12 = (c >> 12) & 1;
    if (q == 0) return f3 == 0 ? COV_C_ADDI4SPN : f3 == 2 ? COV_C_LW : f3 == 6 ? COV_C_SW : -1;
    if (q == 1) {
        switch (f3) {
        case 0: return rd ? COV_C_ADDI : COV_C_NOP;
        case 1: return COV_C_JAL;
        case 2: return COV_C_LI;
        case 3: return rd == 2 ? COV_C_ADDI16SP : COV_C_LUI;
        case 4: {
            const uint32_t k = (c >> 10) & 3;
            if (k < 3) return k == 0 ? COV_C_SRLI : k == 1 ? COV_C_SRAI : COV_C_ANDI;
            static const int ar[4] = { COV_C_SUB, COV_C_XOR, COV_C_OR, COV_C_AND };
            return b12 ? -1 : ar[(c >> 5) & 3];
        }
        case 5: return COV_C_J;
        case 6: return COV_C_BEQZ;
        default: return COV_C_BNEZ;
        }
    }
    if (q == 2) {
        if (f3 == 0) return COV_C_SLLI;
        if (f3 == 2) return COV_C_LWSP;
        if (f3 == 6) return COV_C_SWSP;
        if (f3 == 4) {
            if (!b12) return rs2 ? COV_C_MV : COV_C_JR;
            if (!rd && !rs2) return COV_C_EBREAK;
            return rs2 ? COV_C_ADD : COV_C_JALR;
        }
    }
    return -1;
}

static int csr_index(uint32_t csr)
{
    for (int i = 0; i < COV_NCSR; i++) if (cov_csrs[i] == csr) return i;
    return -1;
}

/* the misaligned bin of a load / store at this offset in its word, -1 if none */
static int mis_bin(uint32_t op, uint32_t f3, uint32_t off)
{
    if (op == 0x03 && f3 == 1) return off == 1 ? COV_M_LH1 : off == 3 ? COV_M_LH3 : -1;
    if (op == 0x03 && f3 == 5) return off == 1 ? COV_M_LHU1 : off == 3 ? COV_M_LHU3 : -1;
    if (op == 0x03 && f3 == 2 && off) return COV_M_LW1 + (int)off - 1;
    if (op == 0x23 && f3 == 1) return off == 1 ? COV_M_SH1 : off == 3 ? COV_M_SH3 : -1;
    if (op == 0x23 && f3 == 2 && off) return COV_M_SW1 + (int)off - 1;
    return -1;
}

/* the kind of exception (or mret) an instruction is, -1 if none */
static int exc_kind(uint32_t raw, int compressed, uint32_t insn, int trap)
{
    if (!trap) return insn == 0x30200073u ? COV_X_MRET : -1;
    if (compressed) return (raw & 0xFFFF) == 0x9002 ? COV_X_CEBREAK : COV_X_C0;
    if (insn == 0x00000073u) return COV_X_ECALL;
    if (insn == 0x00100073u) return COV_X_EBREAK;
    if (insn == 0xFFFFFFFFu) return COV_X_ONES;
    const uint32_t op = insn & 0x7f, f3 = (insn >> 12) & 7, f = insn >> 20;
    switch (op) {
    case 0x03: return COV_X_LOAD;
    case 0x23: return COV_X_STORE;
    case 0x13: return COV_X_SHIFT;
    case 0x33: return COV_X_OP;
    case 0x67: return COV_X_JALR;
    case 0x63: return COV_X_BRANCH;
    case 0x0f: return COV_X_FENCE;
    case 0x2f: return COV_X_AMO;
    case 0x73:
        if (f3 == 4) return COV_X_SYS4;
        if (f3 == 0) return f == 0x002 ? COV_X_URET : f == 0x7b2 ? COV_X_DRET : COV_X_SYS4;
        return (f >= 0xF11 && f <= 0xF14) ? COV_X_CSR_RO : COV_X_CSR;
    default: return COV_X_CUSTOM;
    }
}

void cov_exec(uint32_t raw, int compressed, uint32_t insn, uint32_t a, uint32_t b, int trap)
{
    if (!trap) cov_insn(insn, a, b);
    const uint32_t op = insn & 0x7f, f3 = (insn >> 12) & 7;
    /* CVA6: a load or store of a valid width that traps is misaligned (there are no access faults) */
    const int ls = (op == 0x03 && f3 != 3 && f3 < 6) || (op == 0x23 && f3 <= 2);
    const int mis_trap = cva6 && trap && ls && !compressed;
    int k = mis_trap ? -1 : exc_kind(raw, compressed, insn, trap);
    if (k >= 0) hits[COV_G_EXC][k]++;
    if (compressed && (k = rvc_kind(raw & 0xFFFF)) >= 0 && (!trap || k == COV_C_EBREAK)) hits[COV_G_RVC][k]++;
    if (op == 0x73 && f3 != 0 && f3 != 4 && (k = csr_index(insn >> 20)) >= 0) {
        static const int cop[8] = { -1, 0, 1, 2, -1, 3, 4, 5 };
        hits[COV_G_CSR][idx(COV_G_CSR, cop[f3], k, ((insn >> 15) & 31) != 0)]++;
    }
    if ((!trap || mis_trap) && (op == 0x03 || op == 0x23)) {
        const int32_t imm = op == 0x03 ? (int32_t)insn >> 20 : (((int32_t)insn >> 25) << 5) | (int32_t)((insn >> 7) & 31);
        const int m = mis_bin(op, f3, (a + (uint32_t)imm) & 3);
        if (m >= 0) hits[COV_G_MIS][m]++;
    }
}

#define FLAT(g, i) ((uint16_t)((g) * MAXB + (i)))
void cov_plan(uint32_t raw, int compressed, uint32_t insn, cov_plan_t *p)
{
    const uint32_t opc = insn & 0x7F, f3 = (insn >> 12) & 7, f7 = insn >> 25;
    const int32_t imm = (int32_t)insn >> 20;
    static const int alu_op[8] = { 0, 2, 3, 4, 5, 6, 8, 9 };    /* (as cov_insn) */
    static const int alui_op[8] = { 0, -1, 1, 2, 3, -1, 4, 5 };
    static const int br_op[8] = { 0, 1, -1, -1, 2, 3, 4, 5 };
    static const int ld[8] = { 0, 1, 2, -1, 3, 4, -1, -1 };
    uint16_t s[2] = { 0xFFFF, 0xFFFF };
    int ns = 0, k;
    p->kind = 0; p->v = 0; p->nc2 = 0; p->mop = 0; p->mf3 = 0; p->mimm = 0;
    switch (opc) {                                              /* cov_insn */
    case 0x33:
        if (f7 == 0x01) { p->kind = 1; p->v = FLAT(COV_G_MUL, idx(COV_G_MUL, (int)f3, 0, 0)); p->nc2 = (uint8_t)n_c2[COV_G_MUL]; break; }
        {
            int op = alu_op[f3];
            if (f7 == 0x20 && f3 == 0) op = 1;
            if (f7 == 0x20 && f3 == 5) op = 7;
            p->kind = 1; p->v = FLAT(COV_G_ALU, idx(COV_G_ALU, op, 0, 0)); p->nc2 = (uint8_t)n_c2[COV_G_ALU];
        }
        break;
    case 0x13:
        if (f3 == 1 || f3 == 5) {
            const int op = f3 == 1 ? 0 : (f7 == 0x20 ? 2 : 1);
            p->kind = 2; p->v = FLAT(COV_G_SHI, idx(COV_G_SHI, op, 0, sh_class((insn >> 20) & 31))); p->nc2 = (uint8_t)n_c2[COV_G_SHI];
        } else {
            p->kind = 2; p->v = FLAT(COV_G_ALUI, idx(COV_G_ALUI, alui_op[f3], 0, imm_class(imm))); p->nc2 = (uint8_t)n_c2[COV_G_ALUI];
        }
        break;
    case 0x63:
        if (br_op[f3] >= 0) { p->kind = 1; p->v = FLAT(COV_G_BR, idx(COV_G_BR, br_op[f3], 0, 0)); p->nc2 = (uint8_t)n_c2[COV_G_BR]; }
        break;
    case 0x03:
        if (ld[f3] >= 0) s[ns++] = FLAT(COV_G_MEM, idx(COV_G_MEM, ld[f3], 0, 0));
        break;
    case 0x23:
        if (f3 <= 2) s[ns++] = FLAT(COV_G_MEM, idx(COV_G_MEM, 5 + (int)f3, 0, 0));
        break;
    default:
        break;
    }
    /* the rest of cov_exec (no trap) */
    if ((k = exc_kind(raw, compressed, insn, 0)) >= 0 && ns < 2) s[ns++] = FLAT(COV_G_EXC, k);
    if (compressed && (k = rvc_kind(raw & 0xFFFF)) >= 0 && ns < 2) s[ns++] = FLAT(COV_G_RVC, k);
    if (opc == 0x73 && f3 != 0 && f3 != 4 && (k = csr_index(insn >> 20)) >= 0 && ns < 2) {
        static const int cop[8] = { -1, 0, 1, 2, -1, 3, 4, 5 };
        s[ns++] = FLAT(COV_G_CSR, idx(COV_G_CSR, cop[f3], k, ((insn >> 15) & 31) != 0));
    }
    p->s0 = s[0]; p->s1 = s[1];
    if (opc == 0x03 || opc == 0x23) {
        p->mop = (uint8_t)opc; p->mf3 = (uint8_t)f3;
        p->mimm = (int16_t)(opc == 0x03 ? (int32_t)insn >> 20 : (((int32_t)insn >> 25) << 5) | (int32_t)((insn >> 7) & 31));
    }
}

void cov_run(const cov_plan_t *p, uint32_t a, uint32_t b)
{
    uint32_t *const h = &hits[0][0];
    if (p->kind == 1) h[p->v + (unsigned)cov_class(a) * p->nc2 + (unsigned)cov_class(b)]++;
    else if (p->kind == 2) h[p->v + (unsigned)cov_class(a) * p->nc2]++;
    if (p->s0 != 0xFFFF) h[p->s0]++;
    if (p->s1 != 0xFFFF) h[p->s1]++;
    if (p->mop) {
        const int m = mis_bin(p->mop, p->mf3, (a + (uint32_t)(int32_t)p->mimm) & 3);
        if (m >= 0) hits[COV_G_MIS][m]++;
    }
}

uint64_t cov_hash(void)
{
    uint64_t x = 1469598103934665603ull;
    for (unsigned i = 0; i < sizeof hits / sizeof hits[0][0]; i++) x = (x ^ (&hits[0][0])[i]) * 1099511628211ull;
    return x;
}

unsigned cov_group_total(int g) { return group_bins(g); }
unsigned cov_group_hit(int g)
{
    unsigned n = 0;
    for (unsigned i = 0; i < group_bins(g); i++) n += hits[g][i] != 0;
    return n;
}
unsigned cov_total(void) { unsigned n = 0; for (int g = 0; g < COV_NG; g++) n += cov_group_total(g); return n; }
unsigned cov_hit(void)   { unsigned n = 0; for (int g = 0; g < COV_NG; g++) n += cov_group_hit(g); return n; }
const char *cov_group_name(int g) { return names[g]; }

static uint64_t xs(uint64_t *s)
{
    uint64_t x = *s ? *s : 1;
    x ^= x >> 12; x ^= x << 25; x ^= x >> 27;
    *s = x;
    return x * 0x2545F4914F6CDD1Dull;
}

unsigned cov_unhit(cov_bin_t *out, unsigned max, uint64_t *rng)
{
    unsigned n = 0, seen = 0;
    for (int g = 0; g < COV_NG; g++)
        for (int op = 0; op < n_ops[g]; op++)
            for (int c1 = 0; c1 < n_c1[g]; c1++)
                for (int c2 = 0; c2 < n_c2[g]; c2++) {
                    if (hits[g][idx(g, op, c1, c2)]) continue;
                    cov_bin_t bn = { g, op, c1, c2 };
                    if (n < max) out[n++] = bn;                     /* reservoir sampling */
                    else { uint64_t j = xs(rng) % (seen + 1); if (j < max) out[j] = bn; }
                    seen++;
                }
    for (unsigned i = n; i > 1; i--) {                              /* shuffle */
        unsigned j = (unsigned)(xs(rng) % i);
        cov_bin_t t = out[i - 1]; out[i - 1] = out[j]; out[j] = t;
    }
    return n;
}
