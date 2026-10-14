/* cv32_gen.h - test programs for CV32E40P generated on the PS (see cv32_gen.c). */
#ifndef CV32_GEN_H
#define CV32_GEN_H

#include <stdint.h>
#include "cv32_cov.h"

/* Writes a program into image (the 64 KiB RAM image): a block of `ops` operations run `loops` times, of
 * which n_aim are aimed at the given coverage bins (0 = plain random). Returns the number of words of
 * the main code, 0 if the program does not fit. */
unsigned cv32_gen(uint8_t *image, unsigned image_bytes, uint64_t seed, unsigned ops, unsigned loops,
                  const cov_bin_t *aim, unsigned n_aim);

/* The core the programs are for (and its coverage, cov_profile): 0 CV32E40P (default), 1 CVA6. */
void cv32_gen_profile(int core);

/* How generated programs end: 0 (default) - a jump to 0xF8; else a store to this address (a core whose
 * environment ends a test by such a write, e.g. core-v-verif's exit register), then a jump to itself. */
void cv32_gen_end(uint32_t store_addr);

/* The schedule of the interrupt lines for program `seed`: record k (from 0) of the core's input - the value
 * holds until the core's clock count reaches *until; the last record holds for ever. Returns 0 after it.
 * aim: lines to raise more often (e.g. not taken yet; 0 = all alike). */
int cv32_irq_schedule(uint64_t seed, unsigned k, uint32_t aim, uint64_t *until, uint32_t *value);

#endif /* CV32_GEN_H */
