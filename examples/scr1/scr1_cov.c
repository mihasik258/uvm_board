/* scr1_cov.c - see scr1_cov.h. */
#include "scr1_cov.h"

#include <string.h>

static const int n_ops[COV_NG] = { 10, 8, 6, 3, 6, 8 };
static const int n_c2[COV_NG]  = { COV_NV, COV_NV, COV_NI, COV_NS, COV_NV, 1 };
static const int n_c1[COV_NG]  = { COV_NV, COV_NV, COV_NV, COV_NV, COV_NV, 1 };
static const char *const names[COV_NG] = { "ALU reg-reg", "mul/div", "ALU immediate", "shift immediate",
                                           "branch", "load/store" };

#define MAXB (10 * COV_NV * COV_NV)
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

void cov_insn(uint32_t insn, uint32_t a, uint32_t b)
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
