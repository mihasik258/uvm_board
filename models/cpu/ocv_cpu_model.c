/* ocv_cpu_model.c - the OCV reference model of any processor core wrapped by gen/cpu_wrap.py: the
 * instruction-set model (cpu_model.h) behind the wrapper's memory map, its retirements split into the
 * core's streams (cpu_streams.h). What is particular to a core comes from the generated ocv_cpu_wrap.h
 * (ISA and core profile, memory, regions, streams, generator) - no code per core.
 *
 *   --model-opt program=<image.elf|.hex|.bin>   the program for the RAM (ELF: its loadable segments; .hex:
 *                                               objcopy -O verilog; .bin: from the RAM's first byte)
 *   --model-opt gen=random|directed             instead: a new program per batch, generated here (the
 *                                               binding's generator); "directed" aims each one at the
 *                                               coverage bins not hit so far (--batches N --reset-each-batch)
 *   --model-opt cpu=fast|iss|jit|spike          reference processor model (default: jit on aarch64, fast
 *                                               elsewhere)
 *   --model-opt ops=N loops=K aim=M seed=S      program size, repetitions, bins aimed per program, seed
 *                                               (default 4000, 10, 400, 1)
 *   --model-opt max=N                           stop after N instructions (default 100000000)
 *   --model-opt strict=1                        known errata of the core profile (CVA6 #3175) count as
 *                                               mismatches (default: counted apart and reported, ERRATUM:)
 *   --model-opt irq=V                           with a program (no generation): the interrupt lines held at V
 *                                               from the start (e.g. 0x80: the timer line high) - directed tests
 *   --model-opt lat=G,R                         memory latency (binding `latency`): grant 0..G, response
 *                                               0..R clocks, a new seed per program (default 0,0)
 *
 * Stimulus: the program's non-zero words (the wrapper clears the RAM after reset), one per record, the last
 * flagged (it starts the core); the program ends by
 * jumping to CPU_EXIT. Values the ISA leaves to the implementation - timing CSRs, loads from the binding's
 * `observed` ranges - are taken from what the core produced for the same retirement (a retire stream's
 * rd_wdata). Coverage is collected from every instruction the model executes.
 *
 * Device windows (binding `device`): the core's accesses there come during the run on channel dev_req;
 * react() answers reads (dev_resp) from a plain store per device (writes go into it) and keeps every
 * answer, so the model, running the same program after, reads exactly what the core read. Every device
 * access of the model is expected on dev_req (device, word address, write, byte enables, data).
 *
 * Inputs on a schedule (binding `input`): the stimulus of channel in_<port> - the interrupt lines follow the
 * generator's schedule (cv32_irq_schedule), other inputs keep their value. Interrupts the core took
 * (stream kind interrupt: cause, seq) are taken by the model before the same instruction (it executes the
 * instructions before one by one, cpu_sync); one the model's state did not allow is reported (cause + 0x100),
 * and, when the records carry the core's clock count (`stream ... interrupt cycle`), one whose line the
 * schedule did not raise in the CPU_IRQ_WINDOW clocks before (binding `input ... irq latency N`, default 4;
 * cause + 0x200: the core's input and its own register).
 * Without a retire stream, timing CSRs and mip read what the core wrote into the register (the stream of
 * non-load register writes, in program order).
 *
 * OCV_CPU_TRACE=<file>: every instruction the model executes and every interrupt it takes, one per line.
 * OCV_CPU_SAVE=<prefix>: each generated program also into <prefix>_<n>.bin (run it again: program=<file>).
 */
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_model.h"
#include "cpu_model.h"
#include "cpu_streams.h"
#include "rv32_iss.h"
#include "ocv_cpu_wrap.h"
#if defined(CPU_GEN_CV32)
#include "cv32_gen.h"
#define GEN(img, n, seed, ops, loops, aim, naim) cv32_gen(img, n, seed, ops, loops, aim, naim)
#define COV(raw, c, insn, a, b, trap) cov_exec(raw, c, insn, a, b, trap)
#else
#include "scr1_gen.h"
#define GEN(img, n, seed, ops, loops, aim, naim) scr1_gen(img, n, seed, ops, loops, aim, naim)
#define COV(raw, c, insn, a, b, trap) do { (void)(raw); (void)(c); if (!(trap)) cov_insn(insn, a, b); } while (0)
#endif

#define JUMP_SELF 0x0000006Fu                 /* j . - the instruction at CPU_EXIT */

const ocv_dut_t *const ocv_model_dut = &CPU_DUT;

/* the RAM regions (cpu_rams): the program's image of each, and the model's memory of each; the first is
 * where generated programs go */
static uint8_t *img[CPU_N_RAMS], *mem[CPU_N_RAMS];
#define image (img[0])

static void rams_alloc(void)
{
    for (int r = 0; r < CPU_N_RAMS; r++)
        if (!img[r] && (!(img[r] = calloc(1, cpu_rams[r][1])) || !(mem[r] = calloc(1, cpu_rams[r][1])))) {
            perror("model");
            exit(1);
        }
}

/* the region holding bytes [a, a + n), or -1 */
static int ram_of(uint32_t a, uint32_t n)
{
    for (int r = 0; r < CPU_N_RAMS; r++)
        if (a - cpu_rams[r][0] < cpu_rams[r][1] && cpu_rams[r][1] - (a - cpu_rams[r][0]) >= n) return r;
    return -1;
}

static void images_clear(void) { rams_alloc(); for (int r = 0; r < CPU_N_RAMS; r++) memset(img[r], 0, cpu_rams[r][1]); }
static uint8_t *extra_mem[CPU_N_REGIONS_EXTRA + 1];
static int      have_image;
static uint64_t max_steps = 100000000;
/* jit on the board by default: OCV is for the long tests (hundreds of millions of instructions, tens of minutes
 * on the PC) - there it beats fast (board 14.10.2026, CVA6 Embench x100: nettle-aes 196 -> 164 s, picojpeg
 * 131 -> 112 s, huffbench 90 -> 82 s). On short generated programs (code run once) fast is quicker, but those
 * take seconds either way. fast on the PC (jit emits AArch64). --model-opt cpu=fast keeps it selectable. */
#if defined(__aarch64__)
static char     cpu_name[16] = "jit";
#else
static char     cpu_name[16] = "fast";
#endif
static int      gen_mode;                     /* 0 = program file, 1 = random, 2 = directed */
static unsigned gen_ops = 4000, gen_loops = 10, gen_aim = 400;
static uint64_t gen_seed = 1, executed;
static uint64_t irq_hold;                    /* --model-opt irq=V: interrupt lines held at V (program mode) */
static int irq_hold_set;
static unsigned programs;
static unsigned lat_g, lat_r;                 /* --model-opt lat=G,R */

/* the retire stream with rd_wdata, if any: where implementation-defined values are observed */
static int obs_ch = -1;
static const ocv_field_t *obs_f;
static ocv_model_io_t *cur_io;
static uint64_t        cur_order;

static uint64_t irq_lat_max, irq_taken;     /* clocks from an interrupt's line raised to its taking */
static uint64_t irq_errata;                 /* interrupts only a known erratum of the core explains */
static int      errata_strict;              /* --model-opt strict=1: report them as mismatches */

static void cov_report(void)
{
    if (irq_taken)
        printf("IRQ: %llu taken, at most %llu clocks after the line was raised (window %u)\n",
               (unsigned long long)irq_taken, (unsigned long long)irq_lat_max, CPU_IRQ_WINDOW);
    if (irq_errata)
        printf("ERRATUM: %llu interrupt(s) taken a few instructions after mie disabled them - the core's known"
               " erratum (CVA6: openhwfoundation/cva6#3175)%s\n", (unsigned long long)irq_errata,
               errata_strict ? ", reported as mismatches (strict=1)" : "; not counted as mismatches (strict=1: count)");
    if (!gen_mode && !executed) return;
    printf("COV total: %u of %u bins (%.1f%%) after %u program(s), %llu instructions -",
           cov_hit(), cov_total(), 100.0 * cov_hit() / cov_total(), programs, (unsigned long long)executed);
    for (int g = 0; g < COV_NG; g++) printf(" %s %u/%u%s", cov_group_name(g), cov_group_hit(g), cov_group_total(g),
                                            g + 1 < COV_NG ? "," : "\n");
}

static int load_program(const char *fn)
{
    FILE *f = fopen(fn, "rb");
    if (!f) { perror(fn); return -1; }
    images_clear();
    size_t L = strlen(fn);
    unsigned char hdr[52];
    if (fread(hdr, 1, sizeof hdr, f) == sizeof hdr && !memcmp(hdr, "\177ELF", 4)) {   /* ELF32: its PT_LOAD segments */
        if (hdr[4] != 1) { fprintf(stderr, "%s model: %s: not a 32-bit ELF\n", CPU_NAME, fn); fclose(f); return -1; }
        const uint32_t phoff = hdr[28] | hdr[29] << 8 | hdr[30] << 16 | (uint32_t)hdr[31] << 24;
        const unsigned phentsize = hdr[42] | hdr[43] << 8, phnum = hdr[44] | hdr[45] << 8;
        for (unsigned k = 0; k < phnum; k++) {
            unsigned char ph[32];
            if (fseek(f, (long)(phoff + k * phentsize), SEEK_SET) || fread(ph, 1, 32, f) != 32) break;
#define U32(o) (ph[o] | ph[o + 1] << 8 | ph[o + 2] << 16 | (uint32_t)ph[o + 3] << 24)
            const uint32_t type = U32(0), off = U32(4), paddr = U32(12), filesz = U32(16), memsz = U32(20);
#undef U32
            if (type != 1 || !memsz) continue;  /* PT_LOAD */
            const int r = ram_of(paddr, filesz ? filesz : 1);
            if (!filesz) continue;                 /* (bss: the RAM is cleared) */
            if (r < 0) {
                fprintf(stderr, "%s model: %s: a segment at 0x%x+0x%x outside the RAM regions\n", CPU_NAME, fn, paddr, filesz);
                fclose(f);
                return -1;
            }
            if (fseek(f, (long)off, SEEK_SET) || fread(img[r] + (paddr - cpu_rams[r][0]), 1, filesz, f) != filesz) {
                fprintf(stderr, "%s model: %s: cannot read a segment\n", CPU_NAME, fn);
                fclose(f);
                return -1;
            }
        }
        fclose(f);
        have_image = 1;
        return 0;
    }
    rewind(f);
    if (L > 4 && !strcmp(fn + L - 4, ".bin")) {
        if (fread(img[0], 1, cpu_rams[0][1], f) == 0 && ferror(f)) { perror(fn); fclose(f); return -1; }
    } else {                                   /* $readmemh byte image: "@addr" then bytes */
        char tok[64];
        uint32_t addr = 0;
        while (fscanf(f, "%63s", tok) == 1) {
            if (tok[0] == '@') { addr = (uint32_t)strtoul(tok + 1, 0, 16); continue; }
            const int r = ram_of(addr, 1);
            if (r < 0) {
                fprintf(stderr, "%s model: %s puts data at 0x%x, outside the RAM\n", CPU_NAME, fn, addr);
                fclose(f);
                return -1;
            }
            img[r][addr - cpu_rams[r][0]] = (uint8_t)strtoul(tok, 0, 16);
            addr++;
        }
    }
    fclose(f);
    have_image = 1;
    return 0;
}

static int configure(const char *key, const char *value)
{
    static int reported;
    if (!reported++) atexit(cov_report);         /* interrupts and errata at the end; coverage with gen= */
    if (!strcmp(key, "program")) return load_program(value);
    if (!strcmp(key, "gen")) {
        gen_mode = !strcmp(value, "random") ? 1 : !strcmp(value, "directed") ? 2 : 0;
        if (!gen_mode) return -1;
#if defined(CPU_GEN_CV32)
        cv32_gen_profile(strstr(CPU_ISA, ":cva6") ? 1 : 0);    /* programs and coverage for the core of the ISA string */
#endif
        have_image = 1;
        return 0;
    }
    if (!strcmp(key, "cpu"))   { snprintf(cpu_name, sizeof cpu_name, "%s", value); return 0; }
    if (!strcmp(key, "ops"))   { gen_ops = (unsigned)strtoul(value, 0, 0); return gen_ops == 0; }
    if (!strcmp(key, "loops")) { gen_loops = (unsigned)strtoul(value, 0, 0); return gen_loops == 0; }
    if (!strcmp(key, "aim"))   { gen_aim = (unsigned)strtoul(value, 0, 0); return 0; }
    if (!strcmp(key, "seed"))  { gen_seed = strtoull(value, 0, 0); return 0; }
    if (!strcmp(key, "irq"))   { irq_hold = strtoull(value, 0, 0); irq_hold_set = 1; return 0; }
    if (!strcmp(key, "strict")) { errata_strict = atoi(value); return 0; }
    if (!strcmp(key, "max"))   { max_steps = strtoull(value, 0, 0); return max_steps == 0; }
    if (!strcmp(key, "lat"))   return sscanf(value, "%u,%u", &lat_g, &lat_r) != 2 || lat_g > 255 || lat_r > 255;
    return -1;
}

/* ---------------- memory map ---------------- */
static uint32_t observed_value(uint64_t order, int *ok)
{
    uint32_t rec[CPU_REC_WORDS];
    *ok = obs_ch >= 0 && cur_io && cur_io->observed(cur_io, obs_ch, (uint32_t)order, rec);
    return *ok ? (uint32_t)ocv_get_raw(rec, obs_f) : 0;
}

/* ---------------- device windows ---------------- */
#define DEV_STORE_MAX (1u << 20)               /* bytes kept per device (larger windows wrap) */
static uint8_t        *dev_store[CPU_N_DEVICES + 1];
static uint32_t       *dev_log;                /* answers to device reads, in order (react -> model) */
static size_t          dev_log_n, dev_log_cap, dev_log_head;
static pthread_mutex_t dev_mu = PTHREAD_MUTEX_INITIALIZER;
static const ocv_field_t *dq_f[6], *dr_f;
static uint64_t        dq_count;               /* the model's device accesses this program (dev_req index) */
static int             stopped;                /* the program wrote CPU_STOP: it ends after this instruction */
static void dev_fields(void);

static int dev_of(uint32_t a)
{
    for (int i = 0; i < CPU_N_DEVICES; i++)
        if (a - cpu_devices[i][0] < cpu_devices[i][1]) return i;
    return -1;
}

static uint8_t *dev_bytes(int d)
{
    if (!dev_store[d]) {
        uint32_t n = cpu_devices[d][1] < DEV_STORE_MAX ? cpu_devices[d][1] : DEV_STORE_MAX;
        if (!(dev_store[d] = calloc(1, n < 4 ? 4 : n))) { perror("model"); exit(1); }
    }
    return dev_store[d];
}

static uint32_t dev_off(int d, uint32_t a)
{
    uint32_t n = cpu_devices[d][1] < DEV_STORE_MAX ? cpu_devices[d][1] : DEV_STORE_MAX;
    return ((a - cpu_devices[d][0]) & ~3u) % (n < 4 ? 4 : n);
}

/* the model's access to a device word: expected on dev_req; a read returns the answer the core got */
static uint32_t dev_word(int d, uint32_t w, int we, uint32_t be, uint32_t data)
{
    if (cur_io && dq_f[0]) {
        uint32_t rec[CPU_REC_WORDS] = { 0 };
        ocv_set_raw(rec, dq_f[0], (uint64_t)d); ocv_set_raw(rec, dq_f[1], w); ocv_set_raw(rec, dq_f[2], (uint64_t)we);
        ocv_set_raw(rec, dq_f[3], be); ocv_set_raw(rec, dq_f[4], data & cpu_bytes(be));
        cur_io->emit(cur_io, CPU_CH_DEV_REQ, rec);
    }
    const uint64_t k = dq_count++;
    if (we && CPU_HAS_STOP && w == CPU_STOP) stopped = 1;
    if (we) return 0;
    if (cur_io && cur_io->observed) {          /* the core has made this request (and been answered) */
        uint32_t tmp[CPU_REC_WORDS];
        cur_io->observed(cur_io, CPU_CH_DEV_REQ, (uint32_t)k, tmp);
    }
    uint32_t v = 0;
    pthread_mutex_lock(&dev_mu);
    if (dev_log_head < dev_log_n) v = dev_log[dev_log_head++];
    pthread_mutex_unlock(&dev_mu);
    return v;
}

/* an access of n bytes at a in device d, as the bus carries it: one word, or two across a word */
static uint32_t dev_access(int d, uint32_t a, int n, int we, uint32_t v)
{
    const uint32_t sh = a & 3, w = a & ~3u, mask = n == 4 ? 0xFu : (1u << n) - 1;
    const uint32_t be = (mask << sh) & 0xF, be2 = sh ? mask >> (4 - sh) : 0;
    uint32_t lo = dev_word(d, w, we, be, v << (8 * sh)), r = lo >> (8 * sh);
    if (be2) {
        uint32_t hi = dev_word(d, w + 4, we, be2, v >> (8 * (4 - sh)));
        r |= hi << (8 * (4 - sh));
    }
    return n == 4 ? r : r & ((1u << (8 * n)) - 1);
}

/* Set by an environment that has its own devices (a UVM testbench: uvm/cpu/ocv_uvm_cpu.c): every device
 * access of the core goes there (in order; a read's answer is what it returns), instead of the plain store. */
uint32_t (*ocv_cpu_dev_hook)(int dev, uint32_t addr, int we, uint32_t be, uint32_t wdata, uint64_t cycle);

/* react: a device request of the core (during the run) - store a write, answer a read */
static void react(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    if (ch != CPU_CH_DEV_REQ || !CPU_N_DEVICES) return;
    if (!dr_f) dev_fields();
    const ocv_channel_t *c = &CPU_DUT.channels[ch];
    const int d = (int)ocv_get(c, rec, "dev");
    const uint32_t w = (uint32_t)ocv_get(c, rec, "addr"), be = (uint32_t)ocv_get(c, rec, "be");
    const uint32_t data = (uint32_t)ocv_get(c, rec, "wdata");
    if (d < 0 || d >= CPU_N_DEVICES) return;
    const int we = (int)ocv_get(c, rec, "we");
    uint32_t v;
    if (ocv_cpu_dev_hook) {                    /* the environment's devices */
        v = ocv_cpu_dev_hook(d, w, we, be, data, (uint64_t)ocv_get(c, rec, "cycle"));
        if (we) return;
    } else {
        uint8_t *m = dev_bytes(d) + dev_off(d, w);
        if (we) {
            for (int i = 0; i < 4; i++) if (be >> i & 1) m[i] = (uint8_t)(data >> (8 * i));
            return;
        }
        v = m[0] | m[1] << 8 | m[2] << 16 | (uint32_t)m[3] << 24;
    }
    pthread_mutex_lock(&dev_mu);
    if (dev_log_n == dev_log_cap) {
        dev_log_cap = dev_log_cap ? 2 * dev_log_cap : 1024;
        if (!(dev_log = realloc(dev_log, dev_log_cap * sizeof *dev_log))) { perror("model"); exit(1); }
    }
    dev_log[dev_log_n++] = v;
    pthread_mutex_unlock(&dev_mu);
    uint32_t r[CPU_REC_WORDS] = { 0 };
    ocv_set_raw(r, dr_f, v);
    io->send(io, CPU_CH_DEV_RESP, r);
}

static uint32_t mmio_load(void *ctx, uint32_t a, int n)
{
    (void)ctx;
    const int d = dev_of(a);
    if (d >= 0) return dev_access(d, a, n, 0, 0);
    for (int i = 0; i < CPU_N_OBSERVED; i++)
        if ((a & cpu_observed[i][1]) == cpu_observed[i][0]) {
            int ok;
            uint32_t v = observed_value(cur_order, &ok);
            return n == 4 ? v : v & ((1u << (8 * n)) - 1);
        }
    return 0;                                  /* the wrapper's empty space reads 0 */
}

static void mmio_store(void *ctx, uint32_t a, int n, uint32_t v)
{
    (void)ctx;
    const int d = dev_of(a);
    if (d >= 0) dev_access(d, a, n, 1, v);
}

static uint64_t emitted[64];                    /* records the model emitted per channel, this program */
static int      w_ch = -1;                      /* without a retire stream: the CSR reads (else the non-load
                                                   register writes) - what the core read */
static const ocv_field_t *w_f;

static int timing_csr(void *ctx, uint32_t csr, uint64_t order, uint32_t *value)
{
    (void)ctx; (void)csr;
    int ok;
    if (obs_ch < 0 && w_ch >= 0) {             /* the value the core wrote: its next non-load write */
        uint32_t rec[CPU_REC_WORDS];
        ok = cur_io && cur_io->observed(cur_io, w_ch, (uint32_t)emitted[w_ch], rec);
        *value = ok ? (uint32_t)ocv_get_raw(rec, w_f) : 0;
        return ok;
    }
    *value = observed_value(order, &ok);
    return ok;
}

/* ---------------- model callbacks ---------------- */
static void reset(void)
{
    rams_alloc();
    for (int r = 0; r < CPU_N_RAMS; r++) memset(mem[r], 0, cpu_rams[r][1]);
    for (int i = 0; i < CPU_N_DEVICES; i++)
        if (dev_store[i]) memset(dev_store[i], 0, cpu_devices[i][1] < DEV_STORE_MAX ? cpu_devices[i][1] : DEV_STORE_MAX);
    /* (the answer log is not cleared: the runner may reset between the run and the model; the model
     * takes the answers in order, batch after batch) */
    for (int i = 0; i < CPU_N_REGIONS_EXTRA; i++)
        if (extra_mem[i]) memset(extra_mem[i], 0, cpu_regions_extra[i].size);
}

static unsigned in_k[CPU_N_INPUTS + 1];       /* schedule records given this program, per input */
static uint64_t irq_until[4096];               /* the interrupt lines' schedule of this program */
static uint32_t irq_value[4096];
static unsigned irq_n;

/* the lines the schedule raised at some clock in [t - back, t] */
static uint32_t irq_raised(uint64_t t, uint64_t back)
{
    uint32_t m = 0;
    uint64_t from = 0;
    for (unsigned k = 0; k < irq_n; k++) {      /* record k holds from `from` to irq_until[k] */
        if (irq_until[k] > (t > back ? t - back : 0) && from <= t) m |= irq_value[k];
        from = irq_until[k];
    }
    return m;
}

static int stimulus(int ch, uint64_t index, uint32_t *rec, uint64_t *rng)
{
    (void)rng;
    const ocv_channel_t *c = &CPU_DUT.channels[ch];
    if (ch == CPU_CH_LAT) {                    /* the memory's delays: once per program */
        static unsigned given = ~0u;
        if (given == programs) return 0;
        given = programs;
        ocv_set(c, rec, "seed", (uint32_t)(gen_seed * 0x9E3779B1u + programs));
        ocv_set(c, rec, "gnt", lat_g);
        ocv_set(c, rec, "rsp", lat_r);
        return 1;
    }
    for (int i = 0; i < CPU_N_INPUTS; i++)
        if (cpu_inputs[i].channel == ch) {      /* an input's schedule for this program */
            uint64_t until = ~0ull, value = cpu_inputs[i].irq && irq_hold_set ? irq_hold : cpu_inputs[i].init;
            const unsigned k = in_k[i]++;
#if defined(CPU_GEN_CV32)
            if (cpu_inputs[i].irq && gen_mode) {
                uint32_t v;
                static uint32_t aim;
                if (k == 0) aim = gen_mode == 2 ? cov_irq_unhit() : 0;   /* directed: lines not taken yet */
                if (!cv32_irq_schedule(gen_seed + programs - 1, k, aim, &until, &v)) return 0;
                value = v;
                if (k == 0) irq_n = 0;
                if (irq_n < 4096) { irq_until[irq_n] = until; irq_value[irq_n] = v; irq_n++; }
            } else
#endif
            if (k) return 0;
            ocv_set(c, rec, "until", until);
            ocv_set(c, rec, "value", value);
            return 1;
        }
    if (!have_image) {
        fprintf(stderr, "%s model: no program; pass --model-opt program=<image> or gen=directed\n", CPU_NAME);
        exit(1);
    }
    /* the program's non-zero words, in order (the wrapper clears the RAM after reset); then one 0: the
     * batch ends, and with generation the next one brings the next program */
    static uint32_t *words;                    /* word indices of the current program */
    static uint32_t  n_words, pos, done = 1;
    (void)index;
    if (done) {
        if (!gen_mode && programs) return 0;   /* a program file: once */
        if (gen_mode) {
            static cov_bin_t aim[4096];
            uint64_t arng = gen_seed * 0x100000001B3ull + programs;
            unsigned n_aim = gen_mode == 2 ? cov_unhit(aim, gen_aim < 4096 ? gen_aim : 4096, &arng) : 0;
            if (programs)
                printf("COV program %u: %u of %u bins, %llu instructions\n", programs, cov_hit(), cov_total(),
                       (unsigned long long)executed);
            images_clear();
#if defined(CPU_GEN_CV32)
            if (CPU_HAS_STOP && CPU_EXIT == 0xFFFFFFFFu) cv32_gen_end(CPU_STOP);   /* `exit none`: end by the write */
#endif
            if (!GEN(img[0], CPU_RAM_BYTES, gen_seed + programs, gen_ops, gen_loops, aim, n_aim)) {
                fprintf(stderr, "%s model: program does not fit (ops=%u)\n", CPU_NAME, gen_ops);
                exit(1);
            }
            if (getenv("OCV_CPU_SAVE")) {        /* the generated program, to run again as program=<file> */
                char fn[512];
                snprintf(fn, sizeof fn, "%s_%u.bin", getenv("OCV_CPU_SAVE"), programs + 1);
                FILE *f = fopen(fn, "wb");
                uint32_t last = 0;               /* up to the last non-zero byte of the first RAM */
                for (uint32_t i = 0; i < CPU_RAM_BYTES; i++) if (img[0][i]) last = i + 1;
                if (f) { fwrite(img[0], 1, last, f); fclose(f); }
            }
        }
        const int er = ram_of(CPU_EXIT, 4);
        if (CPU_END_ISSUE && er >= 0) {        /* the core issues the instruction there, then stops - */
            uint8_t *e = img[er] + (CPU_EXIT - cpu_rams[er][0]);   /* where the program has nothing */
            if (!(e[0] | e[1] | e[2] | e[3])) { e[0] = (uint8_t)JUMP_SELF; e[1] = e[2] = e[3] = 0; }
        }
        uint32_t total = 0;
        for (int r = 0; r < CPU_N_RAMS; r++) total += cpu_rams[r][1] / 4;
        if (!words && !(words = malloc(total * sizeof *words))) { perror("model"); exit(1); }
        n_words = 0;
        for (int r = 0; r < CPU_N_RAMS; r++)   /* word addresses (byte address / 4) */
            for (uint32_t i = 0; i < cpu_rams[r][1] / 4; i++) {
                const uint8_t *b = img[r] + 4 * i;
                if (b[0] | b[1] | b[2] | b[3]) words[n_words++] = cpu_rams[r][0] / 4 + i;
            }
        if (!n_words) words[n_words++] = cpu_rams[0][0] / 4;   /* (an empty image: one word, so there is a 'last') */
        programs++;
        pos = 0;
        done = 0;
        for (int i = 0; i < CPU_N_INPUTS; i++) in_k[i] = 0;
    }
    if (pos == n_words) { done = 1; return 0; }
    const uint32_t i = words[pos++], a = 4 * i;
    const int r = ram_of(a, 4);
    const uint8_t *b = img[r] + (a - cpu_rams[r][0]);
    ocv_set(c, rec, "addr", i);
    ocv_set(c, rec, "data", b[0] | b[1] << 8 | b[2] << 16 | (uint32_t)b[3] << 24);
    ocv_set(c, rec, "last", pos == n_words);
    return 1;
}

/* per stream, the channel's field for each value cpu_stream_recs gives (in its order); NULL: not reported */
static const char *const NAMES[8][6] = {
    { "pc", "pc_next", "insn", "rd", "rd_wdata", "trap" }, { "pc", "insn", "c" }, { "rd", "data" },
    { "addr", "be", "data" }, { "cause", "seq" }, { "data" }, { "value" }, { "value" } };
static const ocv_field_t *fields[CPU_N_STREAMS][6];

static void dev_fields(void)
{
    static const char *const n[5] = { "dev", "addr", "we", "be", "wdata" };
    for (int i = 0; i < 5; i++) dq_f[i] = ocv_field(&CPU_DUT.channels[CPU_CH_DEV_REQ], n[i]);
    dr_f = ocv_field(&CPU_DUT.channels[CPU_CH_DEV_RESP], "rdata");
}

/* the instruction at pc straight from the model's memory (the region of the last fetch first): it is read for
 * every instruction (coverage, the issue stream's raw half) - the general cpu_env_load costs ~7% of a run */
static inline uint32_t fetch32(const cpu_env_t *env, const cpu_region_t **last, uint32_t a, int *whole)
{
    const cpu_region_t *r = *last;
    if (!r || a - r->base >= r->size) {
        r = NULL;
        for (int i = 0; i < env->n_regions; i++)
            if (env->regions[i].host && a - env->regions[i].base < env->regions[i].size) { r = &env->regions[i]; break; }
        *last = r;
    }
    if (r && a - r->base + 4u <= r->size) {
        uint32_t v;
        memcpy(&v, r->host + (a - r->base), 4);
        *whole = 1;
        return v;
    }
    *whole = 0;
    return cpu_env_load(env, a, 2);
}

/* each stream's records, built straight into a small buffer and handed over a buffer at a time (emit_n): one call
 * and one load of the channel's window state per buffer, not per record; flushed before the program ends */
#define EBUF 64
static uint32_t ebuf[CPU_N_STREAMS + 1][EBUF][CPU_REC_WORDS];
static int en[CPU_N_STREAMS + 1];
static void ebuf_flush(ocv_model_io_t *io, int s)
{
    if (!en[s]) return;
    const int ch = cpu_streams[s].channel;
    if (io->emit_n) io->emit_n(io, ch, &ebuf[s][0][0], (uint32_t)en[s], CPU_REC_WORDS);
    else for (int k = 0; k < en[s]; k++) io->emit(io, ch, ebuf[s][k]);
    en[s] = 0;
}
static void ebuf_flush_all(ocv_model_io_t *io) { for (int s = 0; s < CPU_N_STREAMS; s++) ebuf_flush(io, s); }

/* a translated block's issue records: the same each time it runs (pc, instruction) - folded once per block
 * (ocv_fold_t, cached by the model's block key) and handed to the window as one piece (io->emit_fold);
 * a long program runs the same few hundred blocks hundreds of millions of times */
#define FOLD_CACHE 4096
static struct { uint64_t key; uint32_t run; int ok; ocv_fold_t f; } fold_cache[FOLD_CACHE];
static uint32_t fold_run;                      /* programs run: a new model's block keys start again */
static int fold_s = -1;                        /* the issue stream (only one: else no pieces) */
static int fold_block(ocv_model_io_t *io, uint64_t key, const cpu_retire_t *rb, int n)
{
    for (int i = 0; i < n; i++) if (rb[i].pc_next == CPU_EXIT) return 0;   /* (the end: record by record) */
    const uint32_t h = (uint32_t)(key ^ key >> 29) * 0x9E3779B1u >> 20;
    __typeof__(fold_cache[0]) *e = &fold_cache[h & (FOLD_CACHE - 1)];
    if (e->key != key || e->run != fold_run) {
        uint32_t recs[64 + 1][CPU_REC_WORDS];
        e->key = key; e->run = fold_run; e->ok = 0;
        for (int i = 0; i < n; i++) {
            const uint32_t raw = rb[i].raw & 0xFFFFu;
            if (cpu_stream_out(&cpu_streams[fold_s], &rb[i], (raw & 3) != 3, raw, fields[fold_s], &recs[i]) != 1) return 0;
        }
        e->ok = io->fold_make(io, cpu_streams[fold_s].channel, &recs[0][0], (uint32_t)n, CPU_REC_WORDS, &e->f);
    }
    if (!e->ok || e->f.n != (uint32_t)n) return 0;
    ebuf_flush(io, fold_s);                    /* (the records before it come first) */
    return io->emit_fold(io, cpu_streams[fold_s].channel, &e->f);
}

static void run_program(ocv_model_io_t *io)
{
    static int init;
    if (!init++) {
        for (int s = 0; s < CPU_N_STREAMS; s++) {
            const ocv_channel_t *c = &CPU_DUT.channels[cpu_streams[s].channel];
            for (int j = 0; j < 6; j++)
                fields[s][j] = NAMES[cpu_streams[s].kind][j] ? ocv_field(c, NAMES[cpu_streams[s].kind][j]) : NULL;
            if (cpu_streams[s].kind == CPU_S_RETIRE && fields[s][4] && obs_ch < 0) {
                obs_ch = cpu_streams[s].channel;
                obs_f = fields[s][4];
            }
        }
        if (CPU_N_DEVICES) dev_fields();
        for (int s = 0, k = 0; s < CPU_N_STREAMS; s++)
            if (cpu_streams[s].kind == CPU_S_ISSUE) fold_s = k++ ? -1 : s;
        for (int s = 0; s < CPU_N_STREAMS; s++)
            if (cpu_streams[s].kind == CPU_S_CSRR) { w_ch = cpu_streams[s].channel; w_f = fields[s][0]; }
        for (int s = 0; s < CPU_N_STREAMS && w_ch < 0; s++)
            if (cpu_streams[s].kind == CPU_S_REGW && cpu_streams[s].filter == CPU_W_NONLOAD) {
                w_ch = cpu_streams[s].channel;
                w_f = fields[s][1];
            }
    }
    cpu_region_t regions[CPU_N_RAMS + CPU_N_REGIONS_EXTRA];
    rams_alloc();
    for (int r = 0; r < CPU_N_RAMS; r++) regions[r] = (cpu_region_t){ cpu_rams[r][0], cpu_rams[r][1], mem[r] };
    for (int i = 0; i < CPU_N_REGIONS_EXTRA; i++) {
        if (!extra_mem[i] && !(extra_mem[i] = calloc(1, cpu_regions_extra[i].size))) { perror("model"); exit(1); }
        regions[CPU_N_RAMS + i] = (cpu_region_t){ cpu_regions_extra[i].base, cpu_regions_extra[i].size, extra_mem[i] };
    }
    cpu_env_t env = { regions, CPU_N_RAMS + CPU_N_REGIONS_EXTRA, mmio_load, mmio_store, timing_csr, NULL,
                      CPU_N_FIXED_CSRS ? cpu_fixed_csrs : NULL, CPU_N_FIXED_CSRS };
    char err[256];
    cpu_model_t *cpu = cpu_create(cpu_name, CPU_ISA, &env, CPU_BOOT, err, sizeof err);
    if (!cpu) { fprintf(stderr, "%s model: %s\n", CPU_NAME, err); exit(1); }
    static int told;
    if (!told++) fprintf(stderr, "%s model: reference processor '%s' - %s\n", CPU_NAME, cpu->impl->name, cpu->impl->description);
    cur_io = io;
    dq_count = 0;
    stopped = 0;
    memset(emitted, 0, sizeof emitted);
    /* interrupts the core took: (cause, seq), read one ahead */
    const ocv_field_t *const *irq_f = NULL;     /* the interrupt stream's fields (cause, seq), if any */
    int irq_ch = -1;
    for (int s = 0; s < CPU_N_STREAMS; s++)
        if (cpu_streams[s].kind == CPU_S_INTR) { irq_f = fields[s]; irq_ch = cpu_streams[s].channel; }
    uint64_t issued = 0, irq_seq = ~0ull, irq_cycle = 0;
    uint32_t irq_cause = 0, irq_j = 0;
    const ocv_field_t *irq_cy = irq_ch >= 0 ? ocv_field(&CPU_DUT.channels[irq_ch], "cycle") : NULL;
#define NEXT_IRQ() do { \
        uint32_t ir_[CPU_REC_WORDS]; \
        irq_seq = ~0ull; \
        if (irq_f && io->observed(io, irq_ch, irq_j, ir_)) { \
            irq_cause = (uint32_t)ocv_get_raw(ir_, irq_f[0]); \
            irq_seq = ocv_get_raw(ir_, irq_f[1]); \
            irq_cycle = irq_cy ? ocv_get_raw(ir_, irq_cy) : 0; \
        } \
    } while (0)
    NEXT_IRQ();
    static FILE *trace;
    static int trace_init;
    if (!trace_init++ && getenv("OCV_CPU_TRACE")) trace = fopen(getenv("OCV_CPU_TRACE"), "w");
    cpu_retire_t rb[64];                       /* handed out together: a translated block (step_n), or one */
    int bi = 0, bn = 0, folded = 0;            /* folded: rb's issue records went as one piece */
    uint32_t s_raw = 0, s_insn = 0, s_a = 0, s_b = 0;   /* (a model without gives_src: read before its step) */
    uint64_t next_ask = 0xFFFF;
    uint64_t order = 0;
    const cpu_region_t *last_rg = NULL;
    const int gives_src = cpu->impl->gives_src;
    /* the streams an instruction can produce records on (interrupts, watched values, errors: not here) */
    int active[CPU_N_STREAMS + 1], n_active = 0;
    for (int s = 0; s < CPU_N_STREAMS; s++)
        if (cpu_streams[s].kind != CPU_S_INTR && cpu_streams[s].kind != CPU_S_WATCH && cpu_streams[s].kind != CPU_S_ERROR)
            active[n_active++] = s;
    /* by blocks: a model that says which whole block it handed out (jit); device accesses and anything the
     * interpreter runs come one by one there, so the end (stopped) and device reads stay per instruction */
    int by_blocks = 0;
#if defined(CPU_FOR_STREAMS)
    by_blocks = gives_src && cpu->impl->step_n && cpu->impl->block_key && !trace;
#endif
    const int fold = by_blocks && fold_s >= 0 && io->fold_make && io->emit_fold;
    fold_run++;
    for (uint64_t n = 0; n < max_steps; n++) {
      if (bi == bn) {                          /* the next instruction(s) */
        /* no interrupt known yet: ask again now and then - a testbench running the core alongside the model
         * (tb_pc) answers only as far as the core has run (not yet = none) */
        if (n >= next_ask) { next_ask = n + 0x10000; if (irq_f && irq_seq == ~0ull) NEXT_IRQ(); }
        if (irq_seq != ~0ull && irq_seq - issued < 256) cpu_sync(cpu, irq_seq - issued + 64);   /* (traps: not issued) */
        while (irq_f && irq_seq == issued) {   /* the core took an interrupt here: so does the model */
            if (trace) fprintf(trace, "interrupt %u before issue %llu at pc %08x\n", irq_cause,
                               (unsigned long long)issued, cpu_pc(cpu));
            int ok = cpu_interrupt(cpu, irq_cause);
            if (trace && ok != 1)
                fprintf(trace, ok == 2 ? "  (known erratum: allowed only by mie before a recent write)\n"
                                       : "  (the model's state does not allow it: %d)\n", ok);
            if (ok == 2) { irq_errata++; ok = errata_strict ? 0 : 1; }
#if defined(CPU_GEN_CV32)
            cov_irq(irq_cause);
#endif
            uint32_t ir[CPU_REC_WORDS] = { 0 };
            const int raised = !irq_cy || !irq_n || (irq_raised(irq_cycle, CPU_IRQ_WINDOW) >> irq_cause & 1);
            if (raised && irq_cy && irq_n) {   /* how late: the least look-back that still finds the line */
                uint64_t k = 0;
                while (k < CPU_IRQ_WINDOW && !(irq_raised(irq_cycle, k) >> irq_cause & 1)) k++;
                if (k > irq_lat_max) irq_lat_max = k;
                irq_taken++;
            }
            ocv_set_raw(ir, irq_f[0], irq_cause | (ok == 1 ? 0 : 0x100u) | (raised ? 0 : 0x200u));
            ocv_set_raw(ir, irq_f[1], irq_seq);
            io->emit(io, irq_ch, ir);
            irq_j++;
            NEXT_IRQ();
        }
        bi = 0; folded = 0; cur_order = order;
        if (by_blocks && (irq_seq == ~0ull || irq_seq - issued >= 256 + 64)) {   /* (no interrupt inside) */
            bn = cpu_step_n(cpu, rb, max_steps - n < 64 ? (int)(max_steps - n) : 64);
            const uint64_t key = bn > 1 && fold ? cpu->impl->block_key(cpu) : 0;
            if (key && (folded = fold_block(io, key, rb, bn))) {
                emitted[cpu_streams[fold_s].channel] += (uint64_t)bn;
                issued += (uint64_t)bn;
            }
        } else if (gives_src) {
            bn = 1; cpu_step(cpu, &rb[0]);
        } else {
            int whole;
            const uint32_t pc = cpu_pc(cpu), w32 = fetch32(&env, &last_rg, pc, &whole);
            s_raw = w32 & 0xFFFFu;
            s_insn = (s_raw & 3) != 3 ? rv32_rvc_expand((uint16_t)s_raw) : whole ? w32 : cpu_env_load(&env, pc, 4);
            s_a = cpu_xreg(cpu, (s_insn >> 15) & 31); s_b = cpu_xreg(cpu, (s_insn >> 20) & 31);
            bn = 1; cpu_step(cpu, &rb[0]);
        }
      }
        const cpu_retire_t *const rp = &rb[bi++];
        order++;
        uint32_t raw, insn, op_a, op_b;
        if (gives_src) {                       /* the model says what it fetched and read: nothing again here */
            raw = rp->raw & 0xFFFFu; insn = rp->insn; op_a = rp->src1; op_b = rp->src2;
        } else {
            raw = s_raw; insn = s_insn; op_a = s_a; op_b = s_b;
        }
        const int c = (raw & 3) != 3;
        COV(raw, c, insn, op_a, op_b, (int)rp->trap);
        if (trace) fprintf(trace, "%llu %08x %08x x%u=%08x%s%s\n", (unsigned long long)issued, rp->pc, rp->insn, rp->rd_addr,
                           rp->rd_wdata, rp->trap ? " trap" : "", rp->mem_we ? " store" : "");
        executed++;
#if defined(CPU_FOR_STREAMS)
        /* stream by stream with s a constant: kind, filter and field positions known when compiling */
#define CPU_FLD(s, j) (cpu_stream_field[s][j] < 0 ? NULL : &CPU_DUT.channels[cpu_streams[s].channel].fields[cpu_stream_field[s][j]])
#define CPU_STREAM_DO(s) do { \
            if (cpu_streams[s].kind == CPU_S_ISSUE && folded) break;   /* (went with the block) */ \
            const ocv_field_t *const F_[6] = { CPU_FLD(s, 0), CPU_FLD(s, 1), CPU_FLD(s, 2), CPU_FLD(s, 3), CPU_FLD(s, 4), CPU_FLD(s, 5) }; \
            const int nr_ = cpu_stream_out(&cpu_streams[s], rp, c, raw, F_, &ebuf[s][en[s]]); \
            if (nr_) { \
                en[s] += nr_; \
                emitted[cpu_streams[s].channel] += (uint64_t)nr_; \
                if (cpu_streams[s].kind == CPU_S_ISSUE || cpu_streams[s].kind == CPU_S_RETIRE) issued += (uint64_t)nr_; \
                if (en[s] >= EBUF - 1) ebuf_flush(io, s); \
            } \
        } while (0);
        CPU_FOR_STREAMS(CPU_STREAM_DO)
#undef CPU_STREAM_DO
#undef CPU_FLD
        (void)active; (void)n_active;
#else
        for (int a = 0; a < n_active; a++) {
            const int s = active[a];
            uint32_t rec[2][CPU_REC_WORDS];
            const int nr = cpu_stream_out(&cpu_streams[s], rp, c, raw, fields[s], rec);
            for (int k = 0; k < nr; k++) {
                io->emit(io, cpu_streams[s].channel, rec[k]);
                emitted[cpu_streams[s].channel]++;
                if (cpu_streams[s].kind == CPU_S_ISSUE || cpu_streams[s].kind == CPU_S_RETIRE) issued++;
            }
        }
#endif
        if (stopped) break;                    /* the program wrote its end */
        const uint32_t op = rp->insn & 0x7f;
        if (rp->pc_next == CPU_EXIT &&           /* the end; seen in the issue stream: a jump there, not running */
            (!CPU_END_ISSUE || op == 0x6f || op == 0x67 || op == 0x63 || rp->pc_next != rp->pc + (c ? 2u : 4u))) {   /* into it */
            ebuf_flush_all(io);                /* (the buffered records come first) */
            if (CPU_END_ISSUE)                 /* the core issues the instruction there, then stops */
                for (int s = 0; s < CPU_N_STREAMS; s++)
                    if (cpu_streams[s].kind == CPU_S_ISSUE) {
                        uint32_t rec[CPU_REC_WORDS] = { 0 };
                        if (fields[s][0]) ocv_set_raw(rec, fields[s][0], CPU_EXIT);
                        if (fields[s][1]) ocv_set_raw(rec, fields[s][1], JUMP_SELF);
                        io->emit(io, cpu_streams[s].channel, rec);
                    }
            break;
        }
        if (rp->trap && !cpu->impl->traps && !strchr(CPU_ISA, ':')) break;   /* a model without traps stops */
    }
    ebuf_flush_all(io);
    /* watched values: not predicted - what the core gave goes into the comparison as it is */
    for (int s = 0; s < CPU_N_STREAMS; s++)
        if (cpu_streams[s].kind == CPU_S_WATCH) {
            uint32_t rec[CPU_REC_WORDS];
            for (uint32_t k = 0; io->observed(io, cpu_streams[s].channel, k, rec); k++) io->emit(io, cpu_streams[s].channel, rec);
        }
    cpu_destroy(cpu);
    cur_io = NULL;
}

static void input(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    if (ch != 0) return;                       /* (inputs' schedules: the core's business) */
    const ocv_channel_t *c = &CPU_DUT.channels[ch];
    static const ocv_field_t *fa, *fd, *fl;    /* (by name once: a lookup per program word was 3% of a run) */
    if (!fa) { fa = ocv_field(c, "addr"); fd = ocv_field(c, "data"); fl = ocv_field(c, "last"); }
    const uint32_t a = (uint32_t)ocv_get_raw(rec, fa) * 4, d = (uint32_t)ocv_get_raw(rec, fd);
    const int r = ram_of(a, 4);
    rams_alloc();
    if (r >= 0) for (int i = 0; i < 4; i++) mem[r][a - cpu_rams[r][0] + i] = (uint8_t)(d >> (8 * i));
    if (ocv_get_raw(rec, fl)) run_program(io);
}

const ocv_model_t ocv_model = { CPU_NAME, configure, reset, stimulus, input, CPU_N_DEVICES ? react : NULL };
