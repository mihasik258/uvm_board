/* memsum_model.c - reference model of the memsum demo IP, and the memory it reads.
 *
 * Reactive: react() sees every read request the IP makes, as soon as it makes it, and answers it
 * with the memory word (send() on the stream source 'rsp'); the IP's clock is held until the
 * answer is there. input() then gives, per command, the requests and the result the IP must
 * produce - including wait = len: with the answer always ready when asked for, the IP spends
 * exactly one of its cycles per word waiting, whatever time the model took.
 *
 * Memory: a fixed function of the address (and --model-opt seed=N), so any address can be read.
 *
 * --model-opt check_wait=0: with --throttle-stream the answers reach the IP late on purpose (memory
 * latency), so its wait count is not known in advance - the model then takes it from what the IP
 * reported (observed()), as for any value the specification leaves open.
 */
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_model.h"
#include "memsum_ocv_meta.h"

enum { CH_CMD = 0, CH_REQ = 1, CH_RSP = 2, CH_RES = 3 };

const ocv_dut_t *const ocv_model_dut = &memsum_dut;

static uint32_t seed = 0x5EED;
static int check_wait = 1;
static uint32_t n_cmd;                           /* commands so far in this batch (= result index) */
static uint64_t cur_batch = ~0ull;
static const ocv_field_t *f_cmd_addr, *f_cmd_len, *f_req_addr, *f_rsp_data,
                         *f_res_sum, *f_res_addr, *f_res_len, *f_res_wait;

static void find_fields(void)
{
    if (f_cmd_addr) return;
    const ocv_channel_t *ch = memsum_dut.channels;
    f_cmd_addr = ocv_field(&ch[CH_CMD], "addr");  f_cmd_len  = ocv_field(&ch[CH_CMD], "len");
    f_req_addr = ocv_field(&ch[CH_REQ], "addr");  f_rsp_data = ocv_field(&ch[CH_RSP], "data");
    f_res_sum  = ocv_field(&ch[CH_RES], "sum");   f_res_addr = ocv_field(&ch[CH_RES], "addr");
    f_res_len  = ocv_field(&ch[CH_RES], "len");   f_res_wait = ocv_field(&ch[CH_RES], "wait");
}

static uint32_t mem(uint32_t a)                  /* the memory: a hash of the address */
{
    uint32_t x = a ^ seed;
    x ^= x >> 16; x *= 0x7FEB352Du; x ^= x >> 15; x *= 0x846CA68Bu; x ^= x >> 16;
    return x;
}

static int configure(const char *key, const char *value)
{
    if (!strcmp(key, "seed")) { seed = (uint32_t)strtoul(value, 0, 0); return 0; }
    if (!strcmp(key, "check_wait")) { check_wait = atoi(value); return 0; }
    return -1;
}

static void reset(void) { find_fields(); }

/* Commands: word-aligned addresses anywhere, lengths 0..24 (0 and 1 on purpose now and then). */
static int stimulus(int ch, uint64_t index, uint32_t *rec, uint64_t *rng)
{
    (void)ch; (void)index;
    find_fields();
    uint64_t r = ocv_rand(rng);
    uint32_t len = (uint32_t)(r % 25);
    if (((r >> 8) & 15) == 0) len = (r >> 12) & 1;
    ocv_set_raw(rec, f_cmd_addr, (uint32_t)(r >> 32) & ~3u);
    ocv_set_raw(rec, f_cmd_len, len);
    return 1;
}

/* During the run: the IP asks for a word - answer it. */
static void react(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    if (ch != CH_REQ) return;
    uint32_t rsp[1] = { 0 };
    ocv_set_raw(rsp, f_rsp_data, mem((uint32_t)ocv_get_raw(rec, f_req_addr)));
    io->send(io, CH_RSP, rsp);
}

/* After the run: what the IP had to do for this command. */
static void input(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    if (ch != CH_CMD) return;
    uint32_t addr = (uint32_t)ocv_get_raw(rec, f_cmd_addr), len = (uint32_t)ocv_get_raw(rec, f_cmd_len);
    uint32_t sum = 0;
    for (uint32_t i = 0; i < len; i++) {
        uint32_t req[1] = { 0 };
        ocv_set_raw(req, f_req_addr, addr + 4 * i);
        io->emit(io, CH_REQ, req);
        sum = ((sum << 1) | (sum >> 31)) + mem(addr + 4 * i);
    }
    uint32_t res[4] = { 0, 0, 0, 0 };
    ocv_set_raw(res, f_res_sum, sum);
    ocv_set_raw(res, f_res_addr, addr);
    ocv_set_raw(res, f_res_len, len);
    if (io->batch != cur_batch) { cur_batch = io->batch; n_cmd = 0; }
    uint32_t wait = len;                            /* one cycle per word: the reaction is hidden */
    uint32_t seen[4];
    if (!check_wait && io->observed(io, CH_RES, n_cmd, seen)) wait = (uint32_t)ocv_get_raw(seen, f_res_wait);
    ocv_set_raw(res, f_res_wait, wait);
    io->emit(io, CH_RES, res);
    n_cmd++;
}

const ocv_model_t ocv_model = { "memsum reference + memory", configure, reset, stimulus, input, react };
