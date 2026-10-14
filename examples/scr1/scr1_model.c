/* scr1_model.c - OCV reference model for SCR1 (scr1_ocv_dut): the RV32IMC instruction-set model
 * (models/cpu/iss/rv32_iss.c) behind the adapter's memory map.
 *
 *   --model-opt program=<image.hex|image.bin>   program for the 64 KiB RAM
 *   --model-opt max=<N>                         stop after N instructions (default 100000000)
 *   --model-opt gen=random|directed             instead of a program file: a new random program per
 *                                               batch, generated here on the PS (scr1_gen.c); with
 *                                               "directed" each one is aimed at the coverage bins the
 *                                               earlier ones missed (run with --reset-each-batch)
 *   --model-opt cpu=iss|spike                   reference processor model (default iss: the light
 *                                               built-in one; spike: the RISC-V reference simulator)
 *   --model-opt ops=N loops=K aim=M seed=S      program size, repetitions, bins aimed per program
 *                                               (default 4000, 10, 400), generator seed
 *
 * Coverage (scr1_cov.c: operation x operand-value classes) is collected from every instruction
 * that executed and matched; it is printed per program ("SCR1COV ...") and at the end.
 *
 * Stimulus: the whole RAM image, one word per record, the last one flagged - loading it
 * starts the core. Once the last word is in, the model executes from the reset vector and
 * expects one retire record per instruction, up to and including the one that jumps to
 * SIM_EXIT (0xF8), where the adapter stops the core.
 *
 * Values the ISA leaves to the implementation - the timing CSRs (cycle/time/instret and their
 * m-/h- forms) and loads from the SCR1 timer - are taken from what the DUT observed for the same
 * retirement, so self-timing programs stay in step with the core.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_model.h"
#include "cpu_model.h"
#include "rv32_iss.h"
#include "scr1_cov.h"
#include "scr1_gen.h"
#include "scr1_ocv_meta.h"

enum { CH_PROGRAM = 0, CH_RETIRE = 1 };

#define RAM_BYTES   0x10000u
#define RAM_WORDS   (RAM_BYTES / 4)
#define TCM_BASE    0x00480000u
#define TCM_BYTES   0x10000u
#define TIMER_BASE  0x00490000u
#define TIMER_MASK  0xFFFFFFE0u
#define RESET_PC    0x00000200u
#define SIM_EXIT    0x000000F8u

const ocv_dut_t *const ocv_model_dut = &scr1_dut;

static uint8_t image[RAM_BYTES];
static int     have_image;
static uint64_t max_steps = 100000000;
static uint8_t ram[RAM_BYTES], tcm[TCM_BYTES];

static ocv_model_io_t *cur_io;
static uint64_t        cur_order;

/* generated programs and coverage */
static char     cpu_name[16] = "iss";
static int      gen_mode;                 /* 0 = program file, 1 = random, 2 = directed */
static unsigned gen_ops = 4000, gen_loops = 10, gen_aim = 400;
static uint64_t gen_seed = 1, executed;   /* instructions executed (and compared) so far */
static unsigned programs;

static void cov_report(void)
{
    if (!gen_mode && !executed) return;
    printf("SCR1COV total: %u of %u bins (%.1f%%) after %u program(s), %llu instructions -",
           cov_hit(), cov_total(), 100.0 * cov_hit() / cov_total(), programs, (unsigned long long)executed);
    for (int g = 0; g < COV_NG; g++) printf(" %s %u/%u%s", cov_group_name(g), cov_group_hit(g), cov_group_total(g),
                                            g + 1 < COV_NG ? "," : "\n");
}

/* ---------------- program image ---------------- */
static int load_program(const char *fn)
{
    FILE *f = fopen(fn, "rb");
    if (!f) { perror(fn); return -1; }
    memset(image, 0, sizeof image);
    size_t L = strlen(fn);
    if (L > 4 && !strcmp(fn + L - 4, ".bin")) {
        if (fread(image, 1, RAM_BYTES, f) == 0 && ferror(f)) { perror(fn); fclose(f); return -1; }
    } else {                                   /* $readmemh byte image: "@addr" then bytes */
        char tok[64];
        uint32_t addr = 0;
        while (fscanf(f, "%63s", tok) == 1) {
            if (tok[0] == '@') { addr = (uint32_t)strtoul(tok + 1, 0, 16); continue; }
            if (addr >= RAM_BYTES) {
                fprintf(stderr, "scr1 model: %s puts data at 0x%x, outside the 64 KiB RAM\n", fn, addr);
                fclose(f);
                return -1;
            }
            image[addr++] = (uint8_t)strtoul(tok, 0, 16);
        }
    }
    fclose(f);
    have_image = 1;
    return 0;
}

static int configure(const char *key, const char *value)
{
    if (!strcmp(key, "program")) return load_program(value);
    if (!strcmp(key, "gen")) {
        gen_mode = !strcmp(value, "random") ? 1 : !strcmp(value, "directed") ? 2 : 0;
        if (!gen_mode) return -1;
        have_image = 1;
        atexit(cov_report);
        return 0;
    }
    if (!strcmp(key, "cpu")) { snprintf(cpu_name, sizeof cpu_name, "%s", value); return 0; }
    if (!strcmp(key, "ops"))   { gen_ops = (unsigned)strtoul(value, 0, 0); return gen_ops == 0; }
    if (!strcmp(key, "loops")) { gen_loops = (unsigned)strtoul(value, 0, 0); return gen_loops == 0; }
    if (!strcmp(key, "aim"))   { gen_aim = (unsigned)strtoul(value, 0, 0); return 0; }
    if (!strcmp(key, "seed"))  { gen_seed = strtoull(value, 0, 0); return 0; }
    if (!strcmp(key, "max")) { max_steps = strtoull(value, 0, 0); return max_steps == 0; }
    return -1;
}

/* ---------------- memory map ---------------- */
static uint32_t observed_rd_wdata(uint64_t order, int *ok)
{
    uint32_t rec[4];
    *ok = cur_io && cur_io->observed(cur_io, CH_RETIRE, (uint32_t)order, rec);
    return *ok ? (uint32_t)ocv_get(&scr1_dut.channels[CH_RETIRE], rec, "rd_wdata") : 0;
}

/* RAM and TCM are host memory the processor model reads and writes directly; the rest (the SCR1
 * timer, unmapped space) goes through these: timer reads return what the core read, writes and
 * unmapped reads have no effect on the retire stream. */
static uint32_t mmio_load(void *ctx, uint32_t a, int n)
{
    (void)ctx;
    if ((a & TIMER_MASK) == TIMER_BASE) {
        int ok;
        uint32_t v = observed_rd_wdata(cur_order, &ok);
        return n == 4 ? v : v & ((1u << (8 * n)) - 1);
    }
    return 0;
}

static void mmio_store(void *ctx, uint32_t a, int n, uint32_t v) { (void)ctx; (void)a; (void)n; (void)v; }

static int timing_csr(void *ctx, uint32_t csr, uint64_t order, uint32_t *value)
{
    (void)ctx; (void)csr;
    int ok;
    *value = observed_rd_wdata(order, &ok);
    return ok;
}

/* ---------------- model callbacks ---------------- */
static void reset(void)
{
    memset(ram, 0, sizeof ram);
    memset(tcm, 0, sizeof tcm);
}

static int stimulus(int ch, uint64_t index, uint32_t *rec, uint64_t *rng)
{
    (void)rng;
    const ocv_channel_t *c = &scr1_dut.channels[ch];
    if (!have_image) {
        fprintf(stderr, "scr1 model: no program; pass --model-opt program=<image.hex|.bin>\n");
        exit(1);
    }
    if (gen_mode) {                            /* a new program for every batch */
        if (index % RAM_WORDS == 0) {
            static cov_bin_t aim[4096];
            uint64_t arng = gen_seed * 0x100000001B3ull + programs;
            unsigned n_aim = gen_mode == 2 ? cov_unhit(aim, gen_aim < 4096 ? gen_aim : 4096, &arng) : 0;
            if (programs)
                printf("SCR1COV program %u: %u of %u bins, %llu instructions\n", programs, cov_hit(), cov_total(),
                       (unsigned long long)executed);
            if (!scr1_gen(image, RAM_BYTES, gen_seed + programs, gen_ops, gen_loops, aim, n_aim)) {
                fprintf(stderr, "scr1 model: program does not fit (ops=%u)\n", gen_ops);
                exit(1);
            }
            programs++;
        }
        index %= RAM_WORDS;
    }
    if (index >= RAM_WORDS) return 0;
    uint32_t w = (uint32_t)index * 4;
    uint32_t data = image[w] | image[w + 1] << 8 | image[w + 2] << 16 | (uint32_t)image[w + 3] << 24;
    ocv_set(c, rec, "addr", index);
    ocv_set(c, rec, "data", data);
    ocv_set(c, rec, "last", index == RAM_WORDS - 1);
    return 1;
}

static void run_program(ocv_model_io_t *io)
{
    const ocv_channel_t *rc = &scr1_dut.channels[CH_RETIRE];
    /* fields looked up once per program, not once per instruction (a lookup is a name search) */
    const ocv_field_t *f_pc = ocv_field(rc, "pc"), *f_pn = ocv_field(rc, "pc_next"),
                      *f_rd = ocv_field(rc, "rd_addr"), *f_wd = ocv_field(rc, "rd_wdata"),
                      *f_tr = ocv_field(rc, "trap");
    static const cpu_region_t regions[2] = { { 0, RAM_BYTES, ram }, { TCM_BASE, TCM_BYTES, tcm } };
    /* SCR1's implementation-defined CSRs (scr1_csr.svh, scr1_arch_description.svh); misa is read-only */
    static const cpu_csr_t fixed[] = {
        { 0x301, 0x40001104 },          /* misa: MXL=32, I M C */
        { 0xF11, 0x00000000 },          /* mvendorid */
        { 0xF12, 0x00000008 },          /* marchid */
        { 0xF13, 0x22011200 },          /* mimpid */
    };
    cpu_env_t env = { regions, 2, mmio_load, mmio_store, timing_csr, NULL, fixed, 4 };
    char err[256];
    /* SCR1 (RV32IMC_MAX): base + M + C, with CSRs, fences and the counters cycle/time/instret */
    cpu_model_t *cpu = cpu_create(cpu_name, "rv32imc_zicsr_zifencei_zicntr", &env, RESET_PC, err, sizeof err);
    if (!cpu) { fprintf(stderr, "scr1 model: %s\n", err); exit(1); }
    static int told;
    if (!told++) fprintf(stderr, "scr1 model: reference processor '%s' - %s\n", cpu->impl->name, cpu->impl->description);
    cpu_retire_t r;
    uint64_t order = 0;
    cur_io = io;
    /* A lossless channel takes any length; otherwise one record more than the buffer holds,
     * so an overrun is reported rather than hidden. */
    uint64_t limit = rc->lossless ? max_steps : (uint64_t)rc->depth + 1;
    for (uint64_t n = 0; n < limit; n++) {
        cur_order = order++;
        uint32_t insn = cpu_env_load(&env, cpu_pc(cpu), 4);       /* coverage: operands before it runs */
        if ((insn & 3) != 3) insn = rv32_rvc_expand((uint16_t)insn);
        uint32_t op_a = cpu_xreg(cpu, (insn >> 15) & 31), op_b = cpu_xreg(cpu, (insn >> 20) & 31);
        cpu_step(cpu, &r);
        if (!r.trap) cov_insn(insn, op_a, op_b);
        executed++;
        uint32_t rec[4] = { 0, 0, 0, 0 };
        ocv_set_raw(rec, f_pc, r.pc);
        ocv_set_raw(rec, f_pn, r.pc_next);
        ocv_set_raw(rec, f_rd, r.rd_addr);
        ocv_set_raw(rec, f_wd, r.rd_wdata);
        ocv_set_raw(rec, f_tr, r.trap);
        io->emit(io, CH_RETIRE, rec);
        /* the program ends at SIM_EXIT; a model without traps cannot follow a trap any further */
        if (r.pc_next == SIM_EXIT || (r.trap && !cpu->impl->traps)) break;
    }
    cpu_destroy(cpu);
    cur_io = NULL;
}

static void input(int ch, const uint32_t *rec, ocv_model_io_t *io)
{
    const ocv_channel_t *c = &scr1_dut.channels[ch];
    uint32_t w = (uint32_t)ocv_get(c, rec, "addr") * 4, d = (uint32_t)ocv_get(c, rec, "data");
    for (int i = 0; i < 4; i++) ram[w + i] = (uint8_t)(d >> (8 * i));
    if (ocv_get(c, rec, "last")) run_program(io);
}

const ocv_model_t ocv_model = { "SCR1 RV32IMC ISS", configure, reset, stimulus, input, NULL };
