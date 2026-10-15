/* cv32_cov.h - functional coverage of the CV32E40P generated test, collected from the executed
 * instruction stream, and the choice of what to aim at next (coverage-directed program generation).
 *
 * The RV32IM computation groups of examples/scr1/scr1_cov.h (operation x operand-value classes), and
 * what CV32E40P adds in machine mode:
 *   CSR        - csrrw/s/c and their immediate forms x the 13 machine-mode CSRs x (source zero or not);
 *   exception  - ecall, ebreak, c.ebreak, mret, and each kind of illegal instruction (reserved encodings
 *                of every major opcode, unknown CSR, write to a read-only CSR, uret, dret, compressed
 *                ones - an all-zero word is two of those);
 *   compressed - each RVC instruction form;
 *   misaligned - lh lhu lw sh sw at every offset that is not aligned (the LSU splits those crossing a word);
 *   interrupt  - each of the 19 interrupt lines (3 7 11 16..31) taken (CVA6: 7 11).
 */
#ifndef CV32_COV_H
#define CV32_COV_H

#include <stdint.h>

enum { COV_V_ZERO, COV_V_ONE, COV_V_M1, COV_V_MIN, COV_V_MAX, COV_V_POS, COV_V_NEG, COV_NV };
enum { COV_I_ZERO, COV_I_ONE, COV_I_M1, COV_I_POS, COV_I_NEG, COV_NI };
enum { COV_S_ZERO, COV_S_ONE, COV_S_31, COV_S_OTHER, COV_NS };

/* operation groups, in bin order */
enum { COV_G_ALU,      /* add sub sll slt sltu xor srl sra or and       x v x v */
       COV_G_MUL,      /* mul mulh mulhsu mulhu div divu rem remu       x v x v */
       COV_G_ALUI,     /* addi slti sltiu xori ori andi                 x v x i */
       COV_G_SHI,      /* slli srli srai                                x v x s */
       COV_G_BR,       /* beq bne blt bge bltu bgeu                     x v x v */
       COV_G_MEM,      /* lb lh lw lbu lhu sb sh sw                     (one bin each) */
       COV_G_CSR,      /* rw rs rc rwi rsi rci                          x csr x (source 0 / not) */
       COV_G_EXC,      /* COV_X_*                                       (one bin each) */
       COV_G_RVC,      /* COV_C_*                                       (one bin each) */
       COV_G_MIS,      /* COV_M_*                                       (one bin each) */
       COV_G_IRQ,      /* interrupt 3 7 11 16..31 taken                 (one bin each) */
       COV_NG };

#define COV_NIRQ 19                         /* at most (CV32E40P's lines) */
extern const uint8_t *cov_irqs;             /* the lines of the core (cov_profile) */
extern int cov_nirq;

#define COV_NCSR 13
extern const uint32_t cov_csrs[COV_NCSR];   /* mstatus misa mie mtvec mscratch mepc mcause mtval mip
                                               mvendorid marchid mimpid mhartid */

enum { COV_X_ECALL, COV_X_EBREAK, COV_X_CEBREAK, COV_X_MRET, COV_X_ONES, COV_X_LOAD, COV_X_STORE,
       COV_X_SHIFT, COV_X_OP, COV_X_JALR, COV_X_BRANCH, COV_X_FENCE, COV_X_SYS4, COV_X_URET, COV_X_DRET,
       COV_X_CSR, COV_X_CSR_RO, COV_X_CUSTOM, COV_X_AMO, COV_X_C0, COV_NX };

enum { COV_C_ADDI4SPN, COV_C_LW, COV_C_SW, COV_C_NOP, COV_C_ADDI, COV_C_JAL, COV_C_LI, COV_C_ADDI16SP, COV_C_LUI,
       COV_C_SRLI, COV_C_SRAI, COV_C_ANDI, COV_C_SUB, COV_C_XOR, COV_C_OR, COV_C_AND, COV_C_J, COV_C_BEQZ, COV_C_BNEZ,
       COV_C_SLLI, COV_C_LWSP, COV_C_JR, COV_C_MV, COV_C_JALR, COV_C_ADD, COV_C_SWSP, COV_C_EBREAK, COV_NC };

enum { COV_M_LH1, COV_M_LH3, COV_M_LHU1, COV_M_LHU3, COV_M_LW1, COV_M_LW2, COV_M_LW3, COV_M_SH1, COV_M_SH3,
       COV_M_SW1, COV_M_SW2, COV_M_SW3, COV_NM };

typedef struct { int group, op, c1, c2; } cov_bin_t;

/* the core: 0 CV32E40P (19 interrupt lines; misaligned accesses split), 1 CVA6 as cva6_ocv_core.sv (the
 * timer and external lines 7, 11; a misaligned access is an exception - its bin counts when it traps) */
void     cov_profile(int core);
void     cov_reset(void);
/* one executed instruction: raw = its encoding (16 bits for a compressed one), insn = the 32-bit form,
 * a, b = values of rs1, rs2 before it ran, trap = it raised an exception */
void     cov_exec(uint32_t raw, int compressed, uint32_t insn, uint32_t a, uint32_t b, int trap);
/* cov_exec of an instruction that does not trap, in two halves: what depends on the instruction alone, once
 * (cov_plan: a translated block's instructions, the same each time it runs), and per execution the part that
 * depends on its operands (cov_run) - the same bins counted as cov_exec(raw, compressed, insn, a, b, 0) */
typedef struct {
    uint16_t v, s0, s1;          /* bins (flat): v with the operand classes added; s0, s1 fixed (0xFFFF none) */
    uint8_t  kind, nc2;          /* 0: no v; 1: v + class(a) * nc2 + class(b); 2: v + class(a) * nc2 */
    int16_t  mimm;               /* a load / store: the offset (misaligned bins from a + mimm) */
    uint8_t  mop, mf3;           /* its opcode (0: none) and funct3 */
} cov_plan_t;
void     cov_plan(uint32_t raw, int compressed, uint32_t insn, cov_plan_t *p);

/* the bins, flat (group g, bin i at g * COV_MAXB + i): hit or not (a flag - only that is ever asked) */
#define COV_MAXB (10 * COV_NV * COV_NV)              /* the largest group (CSR: 6 x 13 x 2 is smaller) */
extern uint8_t cov_hits[];
static inline __attribute__((always_inline)) int cov_class_of(uint32_t v)
{   /* (two branches, taken rarely: -1 0 1 are v + 1 <= 2; MIN MAX are (v ^ MIN) + 1 <= 1) */
    const uint32_t u = v + 1u, t = (v ^ 0x80000000u) + 1u;
    if (u <= 2u) return u == 0 ? COV_V_M1 : u == 1 ? COV_V_ZERO : COV_V_ONE;
    if (t <= 1u) return t ? COV_V_MIN : COV_V_MAX;
    return (v >> 31) ? COV_V_NEG : COV_V_POS;
}
/* the misaligned bin of a load / store at this offset in its word, -1 if none */
static inline __attribute__((always_inline)) int cov_mis_bin(uint32_t op, uint32_t f3, uint32_t off)
{
    if (op == 0x03 && f3 == 1) return off == 1 ? COV_M_LH1 : off == 3 ? COV_M_LH3 : -1;
    if (op == 0x03 && f3 == 5) return off == 1 ? COV_M_LHU1 : off == 3 ? COV_M_LHU3 : -1;
    if (op == 0x03 && f3 == 2 && off) return COV_M_LW1 + (int)off - 1;
    if (op == 0x23 && f3 == 1) return off == 1 ? COV_M_SH1 : off == 3 ? COV_M_SH3 : -1;
    if (op == 0x23 && f3 == 2 && off) return COV_M_SW1 + (int)off - 1;
    return -1;
}
/* inline in the caller's loop: a store per bin, no call */
static inline __attribute__((always_inline)) void cov_run(const cov_plan_t *p, uint32_t a, uint32_t b)
{
    uint8_t *const h = cov_hits;
    if (p->kind == 1) h[p->v + (unsigned)cov_class_of(a) * p->nc2 + (unsigned)cov_class_of(b)] = 1;
    else if (p->kind == 2) h[p->v + (unsigned)cov_class_of(a) * p->nc2] = 1;
    if (p->s0 != 0xFFFF) h[p->s0] = 1;
    if (p->s1 != 0xFFFF) h[p->s1] = 1;
    if (p->mop) {
        const int m = cov_mis_bin(p->mop, p->mf3, (a + (uint32_t)(int32_t)p->mimm) & 3);
        if (m >= 0) h[COV_G_MIS * COV_MAXB + m] = 1;
    }
}
void     cov_irq(uint32_t id);                    /* an interrupt the core took */
uint32_t cov_irq_unhit(void);                     /* the interrupt lines not taken yet (a mask) */
unsigned cov_total(void);                         /* bins that exist */
uint64_t cov_hash(void);                          /* of every bin's count (tests: two ways count the same) */
unsigned cov_hit(void);                           /* bins hit at least once */
unsigned cov_group_total(int g), cov_group_hit(int g);
const char *cov_group_name(int g);
/* up to max bins not hit yet, in a random order (xorshift state *rng); returns how many */
unsigned cov_unhit(cov_bin_t *out, unsigned max, uint64_t *rng);
int      cov_class(uint32_t v);                   /* COV_V_* of a register value */

#endif /* CV32_COV_H */
