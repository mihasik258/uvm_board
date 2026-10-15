/* ocv_model.h - reference model plug-in API.
 *
 * A model is a set of callbacks the generic runner (ocv_runner.c) calls around each batch:
 *
 *   1. stimulus()  builds the stimulus records the runner loads into the source channels.
 *                  It may end the stimulus early (returns 0) - e.g. once a program is loaded.
 *   2. the DUT runs until it goes quiet.
 *   3. input()     receives every stimulus record, in the order the DUT received it, and emits
 *                  the records it expects on the DUT's output channels (sinks and monitors).
 *                  Because this happens after the run, input() may look at what the DUT
 *                  actually produced (observed()) - to take over values the specification leaves
 *                  open, such as timer reads, instead of just masking them.
 *   4. the runner compares expected and captured records, in order, field by field under the
 *      descriptor's rules.
 *
 * Reactive DUTs (feedback): a DUT that asks for data - a bus master reading memory, a protocol
 * engine waiting for an answer - gets it through a "stream" source channel. While the DUT runs,
 * the runner hands every new record of its output channels to react() as soon as it arrives, and
 * react() answers with send() on a stream source: the record reaches the DUT at once, and with
 * "freeze_when_starved" the DUT's clock is held until it does, so the DUT never sees how long the
 * model took. react() runs during the run, before input() of the same batch: it may use state set
 * by reset() and by earlier batches, not by this batch's input().
 *
 * Channels are identified by their index in the DUT metadata (ocv_dut_t.channels). Records are
 * arrays of 32-bit words; use ocv_get / ocv_set (ocv.h) with field names instead of bit offsets
 * (or look a field up once with ocv_field and use ocv_get_raw / ocv_set_raw on hot paths).
 */
#ifndef OCV_MODEL_H
#define OCV_MODEL_H

#include <stdint.h>
#include "ocv_meta.h"

typedef struct ocv_model_io ocv_model_io_t;
struct ocv_fold;                                /* (ocv.h) */
struct ocv_squash;                              /* (ocv.h: a squashed channel's open window) */
struct ocv_model_io {
    /* Expect this record next on output channel ch. */
    void (*emit)(ocv_model_io_t *io, int ch, const uint32_t *rec);
    /* Copy record `index` (0-based, this batch) that the DUT produced on output channel ch into
     * rec; returns 0 if the DUT produced no such record. */
    int  (*observed)(ocv_model_io_t *io, int ch, uint32_t index, uint32_t *rec);
    void *priv;
    /* From react(): append this record to stream source channel ch; the DUT gets it next. */
    void (*send)(ocv_model_io_t *io, int ch, const uint32_t *rec);
    /* Current batch (0-based); observed() indices count from the start of it. */
    uint64_t batch;
    /* Optional (NULL: emit() one by one): n expected records of output channel ch at once, record k at
     * recs + k * stride words - in order, as n emit() calls; a model with many records per step saves the call
     * and the reload of the channel's state per record. */
    void (*emit_n)(ocv_model_io_t *io, int ch, const uint32_t *recs, uint32_t n, uint32_t stride);
    /* Optional (NULL: not offered): records that recur together (a processor model's translated block) emitted
     * as one piece. fold_make: fold n records of output channel ch (as emit_n would take them) into *f once,
     * 0 if the channel cannot take pieces. emit_fold: = emit_n of those records, 0 if not taken now (a window
     * ends inside the piece...): then emit them as records. */
    int  (*fold_make)(ocv_model_io_t *io, int ch, const uint32_t *recs, uint32_t n, uint32_t stride, struct ocv_fold *f);
    int  (*emit_fold)(ocv_model_io_t *io, int ch, const struct ocv_fold *f);
    /* Optional (NULL: not offered): output channel ch's window state, NULL if records of this channel must go
     * through emit (not squashed, --overlap); squash_close: the window is full (n == window, last set): the
     * runner takes it as one fused record and starts the next. Records emitted with emit / emit_n go into the
     * same state, in order. */
    struct ocv_squash *(*squash)(ocv_model_io_t *io, int ch);
    void (*squash_close)(ocv_model_io_t *io, int ch);
};

typedef struct {
    const char *name;
    /* Optional: a "--model-opt key=value" option. Return 0 if accepted. */
    int  (*configure)(const char *key, const char *value);
    /* The DUT was reset: return to the initial state. */
    void (*reset)(void);
    /* Optional: build stimulus record `index` (counted per channel over the whole run) for source
     * channel ch; rec is zeroed, *rng is a seeded state for ocv_rand(). Return 1 if a record was
     * produced, 0 when this channel has no more stimulus. If NULL, every field gets uniform random
     * bits and the stimulus never ends (the run is bounded by --batches). */
    int  (*stimulus)(int ch, uint64_t index, uint32_t *rec, uint64_t *rng);
    /* Consume one stimulus record that was sent on source channel ch; emit the expected outputs. */
    void (*input)(int ch, const uint32_t *rec, ocv_model_io_t *io);
    /* Optional (reactive DUTs): the DUT just produced this record on output channel ch (records
     * of a channel come in order); answer with io->send() on stream sources. */
    void (*react)(int ch, const uint32_t *rec, ocv_model_io_t *io);
} ocv_model_t;

/* Provided by the model's translation unit: the DUT metadata it models and the model itself. */
extern const ocv_dut_t   *const ocv_model_dut;
extern const ocv_model_t        ocv_model;

#endif /* OCV_MODEL_H */
