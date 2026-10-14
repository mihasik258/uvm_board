/* ocv.h - OCV software core: access to one DUT environment (hub + endpoints) through a bus
 * backend, record/field helpers and field-level comparison.
 *
 * The same code runs on the PS (bus = mmap of /dev/mem, ocv_bus_mmap.c) and in co-simulation
 * (bus = AXI4-Lite transactions on the Verilator model, sim/ocv_cosim_main.cpp).
 */
#ifndef OCV_H
#define OCV_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "ocv_meta.h"
#include "ocv_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------- bus backend ---------------- */
typedef struct ocv_bus ocv_bus_t;
struct ocv_bus {
    uint32_t (*rd)(ocv_bus_t *bus, uint32_t off);            /* 32-bit read at hub offset */
    void     (*wr)(ocv_bus_t *bus, uint32_t off, uint32_t v); /* 32-bit write at hub offset */
    void     *priv;
    /* optional: n consecutive 32-bit words from off into dst, as fast as the backend can (wide
     * reads); NULL = word by word through rd */
    void     (*rd_block)(ocv_bus_t *bus, uint32_t off, uint32_t *dst, uint32_t n);
    /* optional: memory the FPGA may write (DMA rings of the outputs, OCV_KIND_DMA): the CPU's view,
     * the address the AXI master uses for it, its size. dma_va NULL = none: the outputs are read
     * over the bus. dma_sync makes what the FPGA wrote into [p, p + n) visible to the CPU
     * (invalidate the cache on a non-coherent path); NULL = nothing to do. */
    void     *dma_va;
    uint64_t  dma_pa;
    size_t    dma_size;
    void     (*dma_sync)(ocv_bus_t *bus, const void *p, size_t n);
};

/* ---------------- environment ---------------- */
typedef struct {
    uint32_t base;         /* slot byte offset from the hub base */
    uint32_t buf_off;      /* buffer window offset inside the slot */
    uint32_t stride_log2;  /* log2 words per record slot */
    uint32_t kind;         /* EP KIND register */
    /* DMA ring (ocv_ring_setup): records come from PS memory instead of the buffer window */
    const uint8_t *ring;   /* NULL: no ring, the buffer is read over the bus */
    uint32_t ring_log2;    /* 2^ring_log2 slots */
    uint32_t slot_log2;    /* 2^slot_log2 bytes per slot */
    uint32_t tail;         /* records taken (free-running, as RING_TAIL) */
} ocv_ep_t;

typedef struct {
    ocv_bus_t       *bus;
    const ocv_dut_t *dut;
    uint32_t         slot_log2;
    ocv_ep_t        *ep;   /* one per channel, same index as dut->channels */
} ocv_env_t;

/* Check the hub and every endpoint against the metadata. Returns 0, or -1 with a message. */
int      ocv_env_open(ocv_env_t *env, ocv_bus_t *bus, const ocv_dut_t *dut, char *err, size_t errlen);
void     ocv_env_close(ocv_env_t *env);

void     ocv_dut_reset(ocv_env_t *env, int hold);   /* 1 = hold in reset, 0 = release */
uint64_t ocv_cycles(ocv_env_t *env);               /* clocks since the last reset release */

/* Bring-up diagnostic: read the hub and every slot directly and report each against the metadata
 * (does not stop at the first difference), check that the clock runs and that register and source
 * buffer writes read back; restores what it writes. Returns the number of problems, 0 = all well. */
int      ocv_hub_info(ocv_bus_t *bus, const ocv_dut_t *dut, FILE *out);

uint32_t ocv_ep_rd(ocv_env_t *env, int ch, uint32_t reg);
void     ocv_ep_wr(ocv_env_t *env, int ch, uint32_t reg, uint32_t v);
void     ocv_rec_write(ocv_env_t *env, int ch, uint32_t i, const uint32_t *rec);
void     ocv_rec_read(ocv_env_t *env, int ch, uint32_t i, uint32_t *rec);
/* records first .. first+n-1 into rec (n * rec_words words), with one block read of the buffer
 * when the bus has rd_block */
void     ocv_rec_read_block(ocv_env_t *env, int ch, uint32_t first, uint32_t n, uint32_t *rec);

/* ---------------- DMA rings (outputs built with OCV_KIND_DMA) ---------------- */
/* Give every output endpoint with OCV_KIND_DMA a ring in the bus's DMA memory (split evenly, each a
 * power of two aligned to its size, at most max_bytes per ring; 0 = no limit). Endpoints without
 * DMA, or with no DMA memory, keep the bus path. Returns the number of rings set up. */
int      ocv_ring_setup(ocv_env_t *env, size_t max_bytes);
static inline int ocv_ring_on(const ocv_env_t *env, int ch) { return env->ep[ch].ring != NULL; }
/* Up to max records that reached the ring since the last call into rec (store words each, as
 * ocv_rec_read_block), released to the hardware. Returns how many. */
uint32_t ocv_ring_take(ocv_env_t *env, int ch, uint32_t *rec, uint32_t max);
/* Records captured but not yet taken (COUNT - tail): 0 once everything is in rec. */
uint32_t ocv_ring_pending(ocv_env_t *env, int ch);

/* ---------------- fields ---------------- */
const ocv_field_t *ocv_field(const ocv_channel_t *c, const char *name);  /* NULL if absent */
uint64_t ocv_get_raw(const uint32_t *rec, const ocv_field_t *f);          /* zero-extended */
int64_t  ocv_get_int(const uint32_t *rec, const ocv_field_t *f);          /* sign-extended if signed */
void     ocv_set_raw_any(uint32_t *rec, const ocv_field_t *f, uint64_t v);  /* truncated to width */
/* ocv_set_raw_any with the common case inline (models call it for every field of every record):
 * a field inside one 32-bit word */
static inline void ocv_set_raw(uint32_t *rec, const ocv_field_t *f, uint64_t v)
{
    unsigned o = f->lsb & 31u;
    if (o + f->width <= 32u) {
        uint32_t m = (f->width >= 32u ? 0xFFFFFFFFu : ((1u << f->width) - 1u)) << o;
        uint32_t *w = rec + (f->lsb >> 5);
        *w = (*w & ~m) | (((uint32_t)v << o) & m);
    } else
        ocv_set_raw_any(rec, f, v);
}

/* Convenience by name, for models. Aborts with a message on an unknown field. */
int64_t  ocv_get(const ocv_channel_t *c, const uint32_t *rec, const char *field);
void     ocv_set(const ocv_channel_t *c, uint32_t *rec, const char *field, uint64_t v);

/* ---------------- squash (fused output windows) ---------------- */
/* words of a stored record: a fused record carries 3 more words after the last raw record */
static inline uint32_t ocv_store_words(const ocv_channel_t *c) { return c->rec_words + (c->squash ? 3u : 0u); }
/* the window signatures, as ocv_sink computes them: start both at 0xFFFFFFFF for a window, feed
 * every record (masked by the compared bits, ocv_channel_word_masks) */
void     ocv_squash_add(uint32_t *crc32c, uint32_t *crc32, const uint32_t *rec, const uint32_t *mask, uint32_t words);
/* set the window (records per fused record; 1 = every record) / emit the open window */
void     ocv_squash_window(ocv_env_t *env, int ch, uint32_t n);
/* the compared-bits mask the squash signatures cover (rec_words words): 1 if the endpoint has
 * KIND_SQMASK and reads it back, 0 otherwise. Set it before the DUT runs. */
int      ocv_squash_mask(ocv_env_t *env, int ch, const uint32_t *mask, uint32_t words);
/* break patterns (n <= 4, each mask/value of `words` words): a matching record closes its window.
 * 1 if the endpoint has KIND_SQBRK and reads them back, 0 otherwise. */
int      ocv_squash_breaks(ocv_env_t *env, int ch, int n, uint32_t mask[][32], uint32_t value[][32], uint32_t words);
void     ocv_squash_flush(ocv_env_t *env, int ch);

/* ---------------- comparison ---------------- */
int      ocv_field_match(const ocv_field_t *f, uint64_t dut, uint64_t model);
/* Index of the first field that does not match, or -1 if the records match. */
int      ocv_rec_mismatch(const ocv_channel_t *c, const uint32_t *dut, const uint32_t *model);
/* When every field of the channel is compared bit for bit (exact, ignore, mask), fills mask[] with
 * the bits that must match, one word per record word, and returns 1: then records match exactly
 * when ((dut ^ model) & mask) is zero in every word. Returns 0 if some field needs its rule (abs,
 * ulp). */
int      ocv_channel_word_masks(const ocv_channel_t *c, uint32_t *mask);
/* "name=value ..." for every field of a record. */
void     ocv_rec_format(const ocv_channel_t *c, const uint32_t *rec, char *buf, size_t n);

/* ---------------- misc ---------------- */
uint64_t ocv_rand(uint64_t *state);   /* xorshift64*, state must be non-zero */

#ifdef __cplusplus
}
#endif
#endif /* OCV_H */
