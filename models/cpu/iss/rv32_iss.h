/* rv32_iss.h - compact RV32IMC + Zicsr instruction-set model, as a library.
 *
 * Golden semantics, no timing: one rv32_step() executes one instruction and reports it the way
 * the SCR1 RVFI-lite tap does (pc, pc_next, rd_addr, rd_wdata, trap). Memory and the values of
 * non-deterministic CSRs (cycle/time/instret and their m-/h- variants) come from the caller, so
 * the same model serves the stand-alone refmodel tool and OCV reference models.
 *
 * Portable C99, no dependencies.
 */
#ifndef RV32_ISS_H
#define RV32_ISS_H

#include <stdint.h>

typedef struct {
    /* Little-endian load/store of 1, 2 or 4 bytes; addr need not be aligned. */
    uint32_t (*load)(void *ctx, uint32_t addr, int size);
    void     (*store)(void *ctx, uint32_t addr, int size, uint32_t value);
    /* Optional: value read by a timing CSR (rv32_is_timing_csr) at retire `order`. Return 1 and
     * set *value to supply it; return 0 to use the model's own value. */
    int      (*timing_csr)(void *ctx, uint32_t csr, uint64_t order, uint32_t *value);
    void     *ctx;
} rv32_env_t;

typedef struct {
    uint32_t   x[32];
    uint32_t   pc;
    uint64_t   order;   /* instructions retired so far */
    rv32_env_t env;
} rv32_iss_t;

typedef struct {
    uint64_t order;
    uint32_t pc, pc_next;
    uint32_t rd_addr, rd_wdata;   /* 0/0 when nothing (or x0) is written */
    uint32_t trap;                /* ecall/ebreak or illegal instruction */
    uint32_t insn;                /* executed instruction, 32-bit form (compressed ones expanded) */
    uint32_t timing_csr;          /* 1 if it read a timing CSR (rd_wdata is non-deterministic) */
    /* what else it wrote (as RVFI's rvfi_mem_* / rvfi_csr_*), all 0 when nothing: */
    uint32_t mem_we, mem_wmask;   /* a store; bytes from mem_addr: 0x1 / 0x3 / 0xF */
    uint32_t mem_addr, mem_wdata; /* byte address; data, bytes outside the mask 0 */
    uint32_t csr_we, csr_wcmd;    /* a CSR write (csrrw; csrrs/csrrc with rs1/uimm != 0); 0 write, 1 set, 2 clear */
    uint32_t csr_waddr, csr_wdata;/* the CSR; the operand (rs1's value or uimm) */
} rv32_retire_t;

void rv32_reset(rv32_iss_t *s, const rv32_env_t *env, uint32_t reset_pc);
void rv32_step(rv32_iss_t *s, rv32_retire_t *r);
int  rv32_is_timing_csr(uint32_t csr);
/* 32-bit equivalent of a 16-bit compressed instruction, 0 if illegal/unsupported. */
uint32_t rv32_rvc_expand(uint16_t c);

#endif /* RV32_ISS_H */
