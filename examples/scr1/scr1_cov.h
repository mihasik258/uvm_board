/* scr1_cov.h - functional coverage of RV32IM computation, collected from the executed instruction
 * stream, and the choice of what to aim at next (coverage-directed program generation).
 *
 * A bin is (operation, class of operand 1, class of operand 2). Value classes: 0, 1, -1, INT_MIN,
 * INT_MAX, other positive, other negative - the corners where ALU, shifter, multiplier, divider
 * and comparators have special cases. Immediates use their own five classes (0, 1, -1, other
 * positive, other negative; INT_MIN/INT_MAX cannot be 12-bit immediates), shift amounts four
 * (0, 1, 31, other).
 */
#ifndef SCR1_COV_H
#define SCR1_COV_H

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
       COV_NG };

typedef struct { int group, op, c1, c2; } cov_bin_t;

void     cov_reset(void);
/* one executed 32-bit instruction; a, b = values of rs1, rs2 before it ran */
void     cov_insn(uint32_t insn, uint32_t a, uint32_t b);
unsigned cov_total(void);                         /* bins that exist */
unsigned cov_hit(void);                           /* bins hit at least once */
unsigned cov_group_total(int g), cov_group_hit(int g);
const char *cov_group_name(int g);
/* up to max bins not hit yet, in a random order (xorshift state *rng); returns how many */
unsigned cov_unhit(cov_bin_t *out, unsigned max, uint64_t *rng);
int      cov_class(uint32_t v);                   /* COV_V_* of a register value */

#endif /* SCR1_COV_H */
