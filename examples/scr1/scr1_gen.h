/* scr1_gen.h - RV32IM test programs generated on the PS (see scr1_gen.c). */
#ifndef SCR1_GEN_H
#define SCR1_GEN_H

#include <stdint.h>
#include "scr1_cov.h"

/* Writes a program into image (the 64 KiB RAM image): a block of `ops` operations run `loops`
 * times, of which n_aim are aimed at the given coverage bins (0 = plain random). Returns the
 * number of instructions, 0 if the program does not fit. */
unsigned scr1_gen(uint8_t *image, unsigned image_bytes, uint64_t seed, unsigned ops, unsigned loops,
                  const cov_bin_t *aim, unsigned n_aim);

#endif /* SCR1_GEN_H */
