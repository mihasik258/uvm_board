/* cpu_streams.h - a retirement of a processor model (cpu_retire_t) as the streams a core's wrapper reports
 * (gen/cpu_wrap.py): the same kinds on both sides, so the model needs nothing of the core but the list
 * of its streams.
 *
 *   CPU_S_RETIRE  one record per retired instruction (pc pc_next insn rd rd_wdata trap)
 *   CPU_S_ISSUE   instructions in program order (pc insn c); a trap is issued only for ecall / ebreak
 *                 (CPU_I_ECALL: only for ecall); insn is the 32-bit form (CPU_I_RAW: a compressed
 *                 instruction's own encoding, as CVA6's RVFI)
 *   CPU_S_REGW    register writes, rd != 0 (rd data); all, only loads or all but loads
 *   CPU_S_STORE   stores as a 32-bit bus carries them: word address, byte enables, the enabled bytes; a store
 *                 across a word is two, the lower word first
 *   CPU_S_INTR    interrupts the core took (cause, seq): not from retirements - the model's driver emits them
 *   CPU_S_CSRR    CSR reads that write a register (data), in program order
 *   CPU_S_WATCH   a value of the core on change: not predicted - the model's driver echoes the core's
 *   CPU_S_ERROR   a check of the wrapper failed (e.g. a bus protocol): the model expects none
 */
#ifndef CPU_STREAMS_H
#define CPU_STREAMS_H

#include <stdint.h>
#include <string.h>
#include "cpu_model.h"
#include "ocv_meta.h"

enum { CPU_S_RETIRE, CPU_S_ISSUE, CPU_S_REGW, CPU_S_STORE, CPU_S_INTR, CPU_S_CSRR, CPU_S_WATCH, CPU_S_ERROR };
enum { CPU_W_ALL, CPU_W_LOAD, CPU_W_NONLOAD };   /* regw: which writes */
enum { CPU_I_ECALL = 4, CPU_I_RAW = 8 };         /* issue (flags): no ebreak; a compressed one's own 16 bits */

typedef struct { int channel, kind, filter; } cpu_stream_t;

/* the records of one retirement for one stream: up to 2 (a split store), as (field name, value) lists */
/* a field of a zeroed record (fields up to 32 bits): ORed into its word, and the next one if it crosses - 32-bit
 * accesses like the zeroing before (a 64-bit read over just-written words stalls the store forwarding) */
#define CPU_INLINE static inline __attribute__((always_inline))   /* (the per-core constants must reach inside) */
CPU_INLINE void cpu_set_or(uint32_t *rec, const ocv_field_t *f, uint32_t v)
{
    if (!f) return;                                  /* the channel does not report this value */
    const unsigned o = f->lsb & 31u, w = f->lsb >> 5;
    if (f->width < 32) v &= (1u << f->width) - 1u;
    rec[w] |= v << o;
    if (o && o + f->width > 32u) rec[w + 1] |= v >> (32u - o);
}

static inline uint32_t cpu_bytes(uint32_t be)
{
    return (be & 1 ? 0xFFu : 0) | (be & 2 ? 0xFF00u : 0) | (be & 4 ? 0xFF0000u : 0) | (be & 8 ? 0xFF000000u : 0);
}

#define CPU_REC_WORDS 8                      /* a stream record: up to 6 fields of up to 32 bits */

/* The records a retirement makes on stream s, written straight into rec[0..1] (zeroed here): 0, 1 or 2 (a store
 * across two words). F: the channel's field for each value, in the order of the kind's NAMES (a NULL: not reported). */
CPU_INLINE int cpu_stream_out(const cpu_stream_t *s, const cpu_retire_t *r, int c, uint32_t raw,
                                 const ocv_field_t *const *F, uint32_t rec[2][CPU_REC_WORDS])
{
    switch (s->kind) {
    case CPU_S_RETIRE:
        memset(rec[0], 0, sizeof rec[0]);
        cpu_set_or(rec[0], F[0], r->pc); cpu_set_or(rec[0], F[1], r->pc_next); cpu_set_or(rec[0], F[2], r->insn);
        cpu_set_or(rec[0], F[3], r->rd_addr); cpu_set_or(rec[0], F[4], r->rd_wdata); cpu_set_or(rec[0], F[5], r->trap);
        return 1;
    case CPU_S_ISSUE:
        if (!r->trap || r->insn == 0x00000073u || (r->insn == 0x00100073u && !(s->filter & CPU_I_ECALL))) {
            memset(rec[0], 0, sizeof rec[0]);
            cpu_set_or(rec[0], F[0], r->pc);
            cpu_set_or(rec[0], F[1], c && (s->filter & CPU_I_RAW) ? raw & 0xFFFFu : r->insn);
            cpu_set_or(rec[0], F[2], (uint32_t)c);
            return 1;
        }
        return 0;
    case CPU_S_REGW: {
        const int load = (r->insn & 0x7f) == 0x03;
        if (r->rd_addr && (s->filter == CPU_W_ALL || (s->filter == CPU_W_LOAD) == load)) {
            memset(rec[0], 0, sizeof rec[0]);
            cpu_set_or(rec[0], F[0], r->rd_addr); cpu_set_or(rec[0], F[1], r->rd_wdata);
            return 1;
        }
        return 0;
    }
    case CPU_S_INTR: case CPU_S_WATCH: case CPU_S_ERROR:
        return 0;
    case CPU_S_CSRR: {
        const uint32_t f3 = (r->insn >> 12) & 7;
        if (!r->trap && (r->insn & 0x7f) == 0x73 && f3 != 0 && f3 != 4 && r->rd_addr) {
            memset(rec[0], 0, sizeof rec[0]);
            cpu_set_or(rec[0], F[0], r->rd_wdata);
            return 1;
        }
        return 0;
    }
    default:
        if (r->mem_we) {
            const uint32_t sh = r->mem_addr & 3, w = r->mem_addr & ~3u, be = (r->mem_wmask << sh) & 0xF;
            memset(rec[0], 0, sizeof rec[0]);
            cpu_set_or(rec[0], F[0], w); cpu_set_or(rec[0], F[1], be); cpu_set_or(rec[0], F[2], (r->mem_wdata << (8 * sh)) & cpu_bytes(be));
            if (sh && r->mem_wmask >> (4 - sh)) {
                const uint32_t be2 = r->mem_wmask >> (4 - sh);
                memset(rec[1], 0, sizeof rec[1]);
                cpu_set_or(rec[1], F[0], w + 4); cpu_set_or(rec[1], F[1], be2);
                cpu_set_or(rec[1], F[2], (r->mem_wdata >> (8 * (4 - sh))) & cpu_bytes(be2));
                return 2;
            }
            return 1;
        }
        return 0;
    }
}

#endif /* CPU_STREAMS_H */
