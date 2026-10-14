/* ocv_meta.h - types of the per-DUT metadata that gen/ocv_gen.py emits as <dut>_ocv_meta.h.
 *
 * The metadata tells the generic PS software what the records of each channel mean: which
 * hub slot a channel lives in, how records are packed into 32-bit words, and how each field of
 * a DUT output is to be compared with the reference model.
 */
#ifndef OCV_META_H
#define OCV_META_H

#include <stdint.h>

/* How a field of an output record is compared with the model's expected value. */
typedef enum {
    OCV_CMP_EXACT  = 0,  /* bit-exact */
    OCV_CMP_IGNORE = 1,  /* not compared (non-deterministic: timestamps, counters, ...) */
    OCV_CMP_MASK   = 2,  /* only bits set in arg are compared */
    OCV_CMP_ABS    = 3,  /* |dut - model| <= arg, as (un)signed integers of the field width */
    OCV_CMP_ULP    = 4   /* IEEE-754 values within arg units in the last place; NaN == NaN */
} ocv_cmp_t;

typedef enum { OCV_FP_NONE = 0, OCV_FP16 = 16, OCV_FP32 = 32, OCV_FP64 = 64 } ocv_fp_t;

typedef struct {
    const char *name;
    uint16_t    lsb;        /* bit offset inside the record (word 0 bit 0 = record bit 0) */
    uint16_t    width;      /* 1..64 */
    uint8_t     is_signed;
    uint8_t     cmp;        /* ocv_cmp_t */
    uint8_t     fp;         /* ocv_fp_t, for OCV_CMP_ULP */
    uint64_t    arg;        /* mask or tolerance */
} ocv_field_t;

typedef enum { OCV_CH_SOURCE = 1, OCV_CH_SINK = 2, OCV_CH_MONITOR = 3 } ocv_ch_kind_t;

typedef struct {
    const char        *name;
    uint8_t            kind;       /* ocv_ch_kind_t */
    uint8_t            slot;       /* hub slot (1-based) */
    uint16_t           rec_words;  /* 32-bit words per record */
    uint32_t           depth;      /* buffer records */
    uint16_t           n_fields;
    const ocv_field_t *fields;
    uint8_t            lossless;   /* monitor freezes the DUT while full (drained by the runner) */
    uint8_t            stream;     /* source: ring fed during the run (the model's react() sends) */
    uint8_t            freeze_starved; /* source: DUT frozen while it waits for a record */
    uint8_t            squash;     /* output fused in windows: stored record = this record + 3 words
                                      {count, CRC32C, CRC32} (ocv_sink SQUASH, ocv_squash_*()) */
} ocv_channel_t;

typedef struct {
    const char          *name;
    uint32_t             dut_id;   /* must equal the hub's DUT_ID register */
    uint16_t             n_channels;
    const ocv_channel_t *channels;
} ocv_dut_t;

#endif /* OCV_META_H */
