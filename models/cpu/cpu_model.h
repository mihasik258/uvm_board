/* cpu_model.h - reference model of a processor, behind one interface, so the golden model of a
 * processor DUT can be swapped (a light built-in ISS, Spike - the RISC-V reference simulator, ...)
 * without touching the DUT's OCV model.
 *
 * One cpu_step() executes one instruction and reports it the way an RVFI-style retire port does.
 * The DUT's model provides the memory map: regions backed by host memory (fast, the model may also
 * read them) and everything else through MMIO callbacks; values the ISA leaves open (timing CSRs)
 * come from a callback, typically what the DUT itself read at that retirement.
 *
 * Portable C99 interface; implementations may be C or C++.
 */
#ifndef CPU_MODEL_H
#define CPU_MODEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t base, size;
    uint8_t *host;                   /* the region's bytes (little-endian memory) */
} cpu_region_t;

/* a CSR whose value the ISA leaves to the implementation and the DUT hardwires (mvendorid,
 * marchid, mimpid, a read-only misa, ...): the model reads it as `value` and ignores writes */
typedef struct {
    uint32_t csr, value;
} cpu_csr_t;

typedef struct {
    const cpu_region_t *regions;
    int                 n_regions;
    /* everything outside the regions (device registers, unmapped space) */
    uint32_t (*mmio_load)(void *ctx, uint32_t addr, int size);
    void     (*mmio_store)(void *ctx, uint32_t addr, int size, uint32_t value);
    /* optional: value read by a timing CSR (cycle/time/instret and m-/h- forms) at retirement
     * `order`; return 1 and set *value to supply it, 0 to keep the model's own */
    int      (*timing_csr)(void *ctx, uint32_t csr, uint64_t order, uint32_t *value);
    void     *ctx;
    /* optional: the DUT's hardwired implementation-defined CSRs (models without them ignore it) */
    const cpu_csr_t *fixed_csrs;
    int              n_fixed_csrs;
} cpu_env_t;

typedef struct {
    uint64_t order;                  /* instructions retired before this one */
    uint32_t pc, pc_next;
    uint32_t rd_addr, rd_wdata;      /* 0/0 when no register (or x0) is written */
    uint32_t trap;                   /* the instruction trapped (did not retire normally) */
    uint32_t insn;                   /* 32-bit form (compressed ones expanded) */
    uint32_t timing_csr;             /* it read a timing CSR (rd_wdata supplied by timing_csr) */
    /* what else it wrote (as RVFI's rvfi_mem_* / rvfi_csr_*); all 0 when nothing or on a trap */
    uint32_t mem_we, mem_wmask;      /* a store; bytes from mem_addr: 0x1 / 0x3 / 0xF */
    uint32_t mem_addr, mem_wdata;    /* byte address; data, bytes outside the mask 0 */
    uint32_t csr_we, csr_wcmd;       /* a CSR write (csrrw; csrrs/csrrc with rs1/uimm != 0): 0 write, 1 set, 2 clear */
    uint32_t csr_waddr, csr_wdata;   /* the CSR; the operand (rs1's value or uimm) */
    /* set by a model with cpu_impl_t.gives_src only (else undefined): the instruction as fetched (a compressed
     * one's 16 bits) and the values of the registers its rs1 / rs2 fields name, before it ran - what a caller
     * would otherwise read again (memory, cpu_xreg) for every instruction */
    uint32_t raw, src1, src2;
} cpu_retire_t;

typedef struct cpu_model cpu_model_t;

typedef struct {
    const char  *name;
    const char  *description;
    int          traps;         /* models traps (exceptions go to the handler); 0: a trap ends the run */
    cpu_model_t *(*create)(const char *isa, const cpu_env_t *env, uint32_t reset_pc, char *err, size_t errlen);
    void         (*step)(cpu_model_t *m, cpu_retire_t *r);
    uint32_t     (*xreg)(cpu_model_t *m, int i);       /* general register, current state */
    uint32_t     (*pc)(cpu_model_t *m);                /* next instruction */
    void         (*destroy)(cpu_model_t *m);
    /* optional: the next 1..n retirements at once (cpu_step_n); NULL: one cpu_step per call */
    int          (*step_n)(cpu_model_t *m, cpu_retire_t *r, int n);
    /* optional: take interrupt `id` now, before the next instruction (cpu_interrupt) */
    int          (*interrupt)(cpu_model_t *m, uint32_t id);
    /* optional: the next n instructions one by one, nothing executed ahead (cpu_sync) */
    void         (*sync)(cpu_model_t *m, uint64_t n);
    int          gives_src;     /* cpu_retire_t.raw / src1 / src2 are set */
    /* optional: nonzero if the last step_n handed out one whole translated block from its start - a key that
     * is the same each time that block runs and never another block's (its instructions, pc and insn: the
     * same each time; the values they compute: not) */
    uint64_t     (*block_key)(cpu_model_t *m);
} cpu_impl_t;

struct cpu_model { const cpu_impl_t *impl; };          /* first member of every implementation */

/* Create the implementation `name` ("iss", "spike", ...) for ISA string isa (e.g. "rv32imc").
 * Returns NULL with a message in err if unknown or not built in. */
cpu_model_t *cpu_create(const char *name, const char *isa, const cpu_env_t *env, uint32_t reset_pc,
                        char *err, size_t errlen);
static inline void     cpu_step(cpu_model_t *m, cpu_retire_t *r) { m->impl->step(m, r); }
/* The next 1..n retirements (n >= 1) into r[0..]; returns how many. A retirement that takes a value
 * from outside (a timing CSR, a device register) is always the first of its call: what the caller
 * supplies for it (timing_csr) before the call is what it reads. xreg/pc then describe the state
 * after the last retirement returned. */
static inline int cpu_step_n(cpu_model_t *m, cpu_retire_t *r, int n)
{
    if (m->impl->step_n) return m->impl->step_n(m, r, n);
    m->impl->step(m, r);
    return 1;
}
/* Take interrupt `id` before the next instruction (the core took it there): returns 1, or 0 if the
 * model's state did not allow it (interrupts or this one disabled) - it is taken anyway, the caller
 * reports it; 2 if only a known erratum of the core profile explains it (e.g. CVA6 #3175: mie disabled a
 * few instructions earlier); -1 if the model has no interrupts. Call cpu_sync first so nothing ran ahead. */
static inline int cpu_interrupt(cpu_model_t *m, uint32_t id)
{
    return m->impl->interrupt ? m->impl->interrupt(m, id) : -1;
}
/* The next n instructions are executed one by one (a model that runs blocks ahead stops doing so). */
static inline void cpu_sync(cpu_model_t *m, uint64_t n) { if (m->impl->sync) m->impl->sync(m, n); }
static inline uint32_t cpu_xreg(cpu_model_t *m, int i)           { return m->impl->xreg(m, i); }
static inline uint32_t cpu_pc(cpu_model_t *m)                    { return m->impl->pc(m); }
static inline void     cpu_destroy(cpu_model_t *m)               { if (m) m->impl->destroy(m); }
/* the names of the implementations built in, space separated */
const char *cpu_impls(void);

/* helpers for implementations: memory access through the regions and MMIO callbacks */
uint32_t cpu_env_load(const cpu_env_t *env, uint32_t addr, int size);
void     cpu_env_store(const cpu_env_t *env, uint32_t addr, int size, uint32_t value);
uint8_t *cpu_env_host(const cpu_env_t *env, uint32_t addr, uint32_t *avail);  /* NULL if not in a region */
int      cpu_is_timing_csr(uint32_t csr);

#ifdef __cplusplus
}
#endif
#endif /* CPU_MODEL_H */
