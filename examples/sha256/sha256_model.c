/* sha256_model.c - reference model of the SHA-256 compression core (examples/sha256/sha256.sv) for the OCV runner and
 * for ocv_model_checker (uvm/ocv_uvm_pkg.sv): FIPS 180-4 compression of each 512-bit block onto the chaining value
 * (the IV when the block starts a message, 'init'); the expected record of the digest channel is the new chaining
 * value. The record layout comes from the generated metadata, fields by name (found once): the contract splits the
 * 512-bit block and the 256-bit digest into 64-bit parts (block__0 = bits 63:0, ...).
 * At reset the model checks itself on the FIPS 180-4 test vector "abc".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_model.h"
#include "sha256_ocv_meta.h"

const ocv_dut_t *const ocv_model_dut = &sha256_dut;

static int ch_blk = -1, ch_dig = -1;
static const ocv_field_t *f_blk[8], *f_init, *f_dig[4];
static uint32_t H[8];

static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 };
static const uint32_t IV[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };

static uint32_t rotr(uint32_t x, int n) { return (x >> n) | (x << (32 - n)); }

/* FIPS 180-4 6.2.2: block w[0..15] (W0 first) onto h */
static void compress(uint32_t h[8], const uint32_t blk[16])
{
    uint32_t w[64], a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    memcpy(w, blk, 64);
    for (int i = 16; i < 64; i++)
        w[i] = (rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)) + w[i - 7] +
               (rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 16];
    for (int i = 0; i < 64; i++) {
        const uint32_t t1 = hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
        const uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
        hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void find(void)
{
    if (f_init) return;
    for (int i = 0; i < ocv_model_dut->n_channels; i++) {
        if (!strcmp(ocv_model_dut->channels[i].name, "blk")) ch_blk = i;
        if (!strcmp(ocv_model_dut->channels[i].name, "dig")) ch_dig = i;
    }
    if (ch_blk < 0 || ch_dig < 0) { fprintf(stderr, "sha256_model: the DUT has no 'blk' or 'dig' channel\n"); exit(1); }
    char n[32];
    for (int p = 0; p < 8; p++) {
        snprintf(n, sizeof n, "block__%d", p);
        f_blk[p] = ocv_field(&ocv_model_dut->channels[ch_blk], n);
    }
    for (int p = 0; p < 4; p++) {
        snprintf(n, sizeof n, "digest__%d", p);
        f_dig[p] = ocv_field(&ocv_model_dut->channels[ch_dig], n);
    }
    f_init = ocv_field(&ocv_model_dut->channels[ch_blk], "init");
}

static void reset(void)
{
    find();
    memcpy(H, IV, sizeof H);
    /* the model against FIPS 180-4's "abc" (one padded block) */
    static const uint32_t abc[16] = { 0x61626380, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x18 };
    static const uint32_t want[8] = { 0xba7816bf, 0x8f01cfea, 0x414140de, 0x5dae2223,
                                      0xb00361a3, 0x96177a9c, 0xb410ff61, 0xf20015ad };
    uint32_t h[8];
    memcpy(h, IV, sizeof h);
    compress(h, abc);
    if (memcmp(h, want, sizeof h)) { fprintf(stderr, "sha256_model: the 'abc' test vector fails\n"); exit(1); }
}

static void input(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    if (ch != ch_blk) return;
    uint32_t w32[16], blk[16];                     /* w32[j]: bits 32j+31:32j of the block; W_i = bits 511-32i -: 32 */
    for (int p = 0; p < 8; p++) {
        const uint64_t v = ocv_get_raw(rec, f_blk[p]);
        w32[2 * p] = (uint32_t)v;
        w32[2 * p + 1] = (uint32_t)(v >> 32);
    }
    for (int i = 0; i < 16; i++) blk[i] = w32[15 - i];
    if (ocv_get_raw(rec, f_init)) memcpy(H, IV, sizeof H);
    compress(H, blk);
    uint32_t out[8] = { 0 };                       /* H0 = digest[255:224]: part p holds H[7-2p] (low), H[6-2p] */
    for (int p = 0; p < 4; p++) ocv_set_raw(out, f_dig[p], ((uint64_t)H[6 - 2 * p] << 32) | H[7 - 2 * p]);
    io->emit(io, ch_dig, out);
}

const ocv_model_t ocv_model = { "SHA-256 compression (FIPS 180-4)", NULL, reset, NULL, input, NULL };
