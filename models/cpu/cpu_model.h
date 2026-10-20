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

/* A translated block as it ran (cpu_impl_t.block): per instruction what is the same each time the block runs
 * (cpu_bins_t) and what this run computed (cpu_bout_t), so a caller takes the block in one go instead of a
 * cpu_retire_t per instruction. As cpu_retire_t: rd_addr = rd, rd_wdata = wdata & m_rd,
 * pc_next = (next & m_next) | (ins.next & ~m_next), raw = len 2 ? raw : insn, src1/src2 = the registers rs1/rs2
 * (from x, the registers before the block, and the block's writes so far); a store: mem_we = m_store & 1,
 * mem_wmask = ((1 << store) - 1) & m_store, mem_addr = maddr & m_store, mem_wdata = mdata & m_store. A block
 * has no traps, CSR accesses or device accesses (those come one by one). */
typedef struct {
    uint32_t pc, insn, next;               /* next: pc of the next instruction unless dyn_next */
    uint32_t m_next, m_rd, m_store;        /* all ones: take that value from cpu_bout_t */
    uint8_t  rd, len, store, dyn_next;     /* rd 0: no register written; store: bytes (0: none) */
    uint8_t  rs1, rs2; uint16_t raw;       /* raw: a compressed one's 16 bits */
} cpu_bins_t;                              /* 32 bytes */
typedef struct { uint32_t wdata, next, maddr, mdata; } cpu_bout_t;
typedef struct {
    const cpu_bins_t *ins; const cpu_bout_t *out;
    const uint32_t *x;                     /* the registers before the block */
    uint64_t key;                          /* nonzero: the block ran whole - the same key each time it runs, never
                                            * another block's (its cpu_bins_t: the same each time) */
    int      fused;                        /* its code also did what cpu_impl_t.fuse asked (coverage, records) */
    void   **user;                         /* a slot the caller may keep a pointer in, per translated block (NULL
                                            * again when the block is translated anew; NULL: none) */
    /* chained (cpu_impl_t.fuse with an issue window): fused blocks run one after another in the translated code,
     * each doing all of its work itself (records, coverage, its issue records, the windows' counts) */
    uint32_t budget;                       /* in: instructions the call may run at most (whole blocks) */
    uint64_t done;                         /* out: instructions run so, all their work done; the view (ins, out) is
                                            * then the block that left early, if any: block() returned done + its
                                            * instructions */
    const cpu_bins_t *last;                /* out: done, no such block: the last instruction run (the end check) */
} cpu_block_t;

/* What a translating model's code can do for its caller as it runs (cpu_impl_t.fuse), instead of the caller
 * doing it per instruction afterwards: count coverage bins and fold records of up to two streams into their
 * windows, straight from the values it has in registers. */
typedef struct {                           /* an instruction's coverage, decided once (as cv32_cov's cov_plan) */
    uint16_t v, s0, s1;                    /* bins (flat): v plus the operand classes; s0, s1 fixed (0xFFFF none) */
    uint8_t  kind, nc2;                    /* 0: no v; 1: v + class(a) * nc2 + class(b); 2: v + class(a) * nc2 */
    uint16_t mis[4];                       /* a load / store: the bin at each offset (a + imm) & 3, 0xFFFF none */
} cpu_covp_t;
typedef struct { uint8_t lsb, width; } cpu_ffield_t;   /* a field of a record (width 0: not reported) */
/* a block's issue records folded once, as a piece (ocv.h's ocv_fold_t): a window's CRCs move past it as
 * crc(0, clmul(state, kc)) ^ c (and kz, z), n records more, last its last record */
typedef struct { uint32_t c, z, kc, kz, n, words, last[4]; } cpu_piece_t;
typedef struct {
    uint32_t    *state;                    /* the window: [0] records in it, [1] CRC32C, [2] CRC32, [3] records
                                            * per window - the code folds into [1], [2]; the caller counts [0] */
    int          store;                    /* 0: register writes (rd != 0), filter 0 all / 1 loads / 2 all but
                                            * loads (cpu_streams.h CPU_W_*); 1: stores */
    int          filter;
    uint32_t     words;                    /* 1..4 */
    uint32_t     mask[4];                  /* the bits that are compared (and signed) */
    cpu_ffield_t f[3];                     /* REGW: rd, data; STORE: addr, be, data */
} cpu_fstream_t;
typedef struct {
    uint8_t     *cov;                      /* the bins (a flag each), NULL: no coverage here */
    void       (*cov_plan)(uint32_t raw, int compressed, uint32_t insn, cpu_covp_t *p);
    uint8_t      cls[7];                   /* the class numbers of 0, 1, -1, INT_MIN, INT_MAX, other >0, other <0
                                            * (the last two: cls[6] == cls[5] + 1) */
    int          nstreams;
    cpu_fstream_t s[2];
    uint32_t     exit_pc;                  /* the program's end: no block with an instruction there does it */
    /* chaining (optional, istate NULL: none): the issue records' window, and the piece of a block's issue
     * records (0: none - the block is then not fused); last_off: bytes from a window's state ([0]) to its last
     * record, which the code keeps (every window here) */
    uint32_t    *istate;
    int        (*piece)(const cpu_bins_t *ins, int n, cpu_piece_t *p);
    uint32_t     last_off;
} cpu_fuse_t;

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
    /* optional: the next instructions - a translated block, run, into *b (returns how many instructions, all of
     * them taken), or one instruction into *r (returns 0). Not with instructions of a block still to hand out
     * (step_n took part of it): then one of them into *r. */
    int          (*block)(cpu_model_t *m, cpu_block_t *b, cpu_retire_t *r);
    /* optional: from now on the translated code also does *f where it can (cpu_block_t.fused tells, per block
     * run: a window that would fill inside a block is left to the caller). Returns 0 if it will not. f stays the
     * caller's (read at translation and per block). */
    int          (*fuse)(cpu_model_t *m, const cpu_fuse_t *f);
    /* optional: the machine-mode CSRs that are architectural state (what a checkpoint restores), current
     * values: up to max into csr[]/val[], returns how many (counters the core supplies - mcycle, mip - are
     * not among them) */
    int          (*arch_csrs)(cpu_model_t *m, uint32_t *csr, uint32_t *val, int max);
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
static inline int      cpu_arch_csrs(cpu_model_t *m, uint32_t *csr, uint32_t *val, int max)
{
    return m->impl->arch_csrs ? m->impl->arch_csrs(m, csr, val, max) : 0;
}
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
