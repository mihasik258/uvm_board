/* otbn_model.c - reference model of the OTBN+KMAC DUT (examples/otbn/otbn_kmac_ocv.sv) running OpenTitan's ML-DSA-87
 * app (run_mldsa87): what every response on the bus must be, the results of the app from mldsa-native
 * (ext/mldsa-native, the reference implementation of FIPS 204 it is derived from) - not an OTBN simulator.
 *
 * The model keeps what the test wrote into DMEM; a write of EXECUTE to OTBN's CMD runs the operation its mode word
 * names, on those inputs, and puts its outputs into the model's DMEM at the app's buffers:
 *   keygen (deterministic): (pk, sk) = ML-DSA.KeyGen_internal(xi), xi = xi_share0 ^ xi_share1;
 *                           pk -> pk_rho, pk_t1; sk is kept here (OTBN keeps its masked form in DMEM, which sign
 *                           reads - the model does not need to know that form)
 *   sign (deterministic):   sig = ML-DSA.Sign_internal(sk, mu, rnd = rnd_share0 ^ rnd_share1) with the external mu;
 *                           sig -> sig_c_tilde, sig_z, sig_h
 * Responses: a write's is 0; a read of DMEM is the model's word; of ERR_BITS 0 (no error); a wait request has none.
 * The buffers' places come from the program's symbols (--model-opt syms=<run_mldsa87.sym>, otbn_prog.py).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_model.h"
#include "otbn_kmac_ocv_ocv_meta.h"

#include "mldsa_native.h"

const ocv_dut_t *const ocv_model_dut = &otbn_kmac_ocv_dut;

enum { DMEM_BUS = 0x8000, DMEM_BYTES = 0x4000, OTBN_CMD = 0x10, OTBN_ERR_BITS = 0x1c, CMD_EXECUTE = 0xd8 };
enum { MODE_KEYGEN_DET = 0xfaacd725, MODE_SIGN_DET = 0x8accea7f };
enum { PK_BYTES = 2592, SK_BYTES = 4896, SIG_BYTES = 4627 };

static int ch_bus = -1, ch_rsp = -1;
static const ocv_field_t *f_we, *f_wait, *f_addr, *f_wdata, *f_rdata, *f_err;
static uint8_t dmem[DMEM_BYTES];
static uint8_t sk[SK_BYTES];
static int have_sk;
static uint64_t cur_batch = ~0ull;
static uint32_t n_rsp;                       /* responses so far in this batch */
static struct { const char *name; uint32_t off; } sym[] = {
    { "mldsa87_mode", ~0u }, { "mldsa87_keygen_xi_share0", ~0u }, { "mldsa87_keygen_xi_share1", ~0u },
    { "mldsa87_pk_rho", ~0u }, { "mldsa87_pk_t1", ~0u }, { "mldsa87_mu", ~0u },
    { "mldsa87_sign_rnd_share0", ~0u }, { "mldsa87_sign_rnd_share1", ~0u },
    { "mldsa87_sig_c_tilde", ~0u }, { "mldsa87_sig_z", ~0u }, { "mldsa87_sig_h", ~0u },
};
enum { S_MODE, S_XI0, S_XI1, S_PK_RHO, S_PK_T1, S_MU, S_RND0, S_RND1, S_SIG_C, S_SIG_Z, S_SIG_H, N_SYM };

/* mldsa-native's randomness: never asked for (the deterministic operations take theirs as inputs) */
int randombytes(uint8_t *out, size_t outlen);
int randombytes(uint8_t *out, size_t outlen) { memset(out, 0, outlen); return -1; }

static void find(void)
{
    if (f_we) return;
    for (int i = 0; i < ocv_model_dut->n_channels; i++) {
        if (!strcmp(ocv_model_dut->channels[i].name, "bus")) ch_bus = i;
        if (!strcmp(ocv_model_dut->channels[i].name, "rsp")) ch_rsp = i;
    }
    if (ch_bus < 0 || ch_rsp < 0) { fprintf(stderr, "otbn_model: the DUT has no 'bus' or 'rsp' channel\n"); exit(1); }
    const ocv_channel_t *b = &ocv_model_dut->channels[ch_bus], *r = &ocv_model_dut->channels[ch_rsp];
    f_we = ocv_field(b, "we"); f_wait = ocv_field(b, "wait_idle"); f_addr = ocv_field(b, "addr");
    f_wdata = ocv_field(b, "wdata"); f_rdata = ocv_field(r, "rdata"); f_err = ocv_field(r, "err");
}

static int configure(const char *key, const char *value)
{
    if (strcmp(key, "syms")) return -1;
    FILE *f = fopen(value, "r");
    if (!f) { fprintf(stderr, "otbn_model: %s: cannot open\n", value); return -1; }
    char name[256];
    unsigned off;
    while (fscanf(f, "%255s %x", name, &off) == 2)
        for (int i = 0; i < N_SYM; i++) if (!strcmp(name, sym[i].name)) sym[i].off = off;
    fclose(f);
    for (int i = 0; i < N_SYM; i++)
        if (sym[i].off == ~0u) { fprintf(stderr, "otbn_model: %s: no symbol %s\n", value, sym[i].name); return -1; }
    return 0;
}

static void reset(void)
{
    find();
    memset(dmem, 0, sizeof dmem);
    have_sk = 0;
}

static uint8_t *at(int s) { return &dmem[sym[s].off]; }

static void execute(void)
{
    uint32_t mode;
    memcpy(&mode, at(S_MODE), 4);
    if (sym[S_MODE].off == ~0u) { fprintf(stderr, "otbn_model: no symbols (--model-opt syms=<prog>.sym)\n"); exit(1); }
    if (mode == MODE_KEYGEN_DET) {
        uint8_t xi[32], pk[PK_BYTES];
        for (int i = 0; i < 32; i++) xi[i] = at(S_XI0)[i] ^ at(S_XI1)[i];
        if (mldsa_keypair_internal(pk, sk, xi)) { fprintf(stderr, "otbn_model: keygen failed\n"); exit(1); }
        memcpy(at(S_PK_RHO), pk, 32);
        memcpy(at(S_PK_T1), pk + 32, PK_BYTES - 32);
        have_sk = 1;
    } else if (mode == MODE_SIGN_DET) {
        uint8_t rnd[32], sig[SIG_BYTES];
        if (!have_sk) { fprintf(stderr, "otbn_model: sign before any keygen\n"); exit(1); }
        for (int i = 0; i < 32; i++) rnd[i] = at(S_RND0)[i] ^ at(S_RND1)[i];
        if (mldsa_signature_internal(sig, at(S_MU), 64, NULL, 0, rnd, sk, 1)) {
            fprintf(stderr, "otbn_model: sign failed\n");
            exit(1);
        }
        memcpy(at(S_SIG_C), sig, 64);
        memcpy(at(S_SIG_Z), sig + 64, 4480);
        memcpy(at(S_SIG_H), sig + 64 + 4480, SIG_BYTES - 64 - 4480);
    } else {
        fprintf(stderr, "otbn_model: mode 0x%08x is not one the model runs (deterministic keygen, sign)\n", mode);
        exit(1);
    }
}

static void input(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    if (ch != ch_bus || ocv_get_raw(rec, f_wait)) return;
    if (io->batch != cur_batch) { cur_batch = io->batch; n_rsp = 0; }
    const uint32_t addr = (uint32_t)ocv_get_raw(rec, f_addr), wdata = (uint32_t)ocv_get_raw(rec, f_wdata);
    const int dm = addr >= DMEM_BUS && addr < DMEM_BUS + DMEM_BYTES;
    uint32_t rsp[2] = { 0, 0 }, v = 0;
    if (ocv_get_raw(rec, f_we)) {
        if (dm) memcpy(&dmem[addr - DMEM_BUS], &wdata, 4);
        if (addr == OTBN_CMD && wdata == CMD_EXECUTE) execute();
    } else if (dm) {
        memcpy(&v, &dmem[addr - DMEM_BUS], 4);
    } else if (addr != OTBN_ERR_BITS) {
        fprintf(stderr, "otbn_model: a read of 0x%08x - not one the model knows\n", addr);
        exit(1);
    }
    ocv_set_raw(rsp, f_rdata, v);
    ocv_set_raw(rsp, f_err, 0);
    io->emit(io, ch_rsp, rsp);
    n_rsp++;
}

const ocv_model_t ocv_model = { "OTBN ML-DSA-87 (mldsa-native)", configure, reset, NULL, input, NULL };
