/* scr1_ref_dpi.c - the reference model of the SCR1 UVM testbench, as a verifier would attach one:
 * a C instruction-set model behind DPI (here OCV's processor-model interface, cpu=iss or spike).
 *
 *   scr1_ref_load(addr, data)   write one word of the program image (byte address)
 *   scr1_ref_start()            reset the model at the reset vector
 *   scr1_ref_step(...)          execute one instruction, report it as the core's retire port does
 *   scr1_ref_step_all(...)      the same, with what it wrote besides rd: a store, a CSR
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cpu_model.h"

#define RAM_BYTES 0x10000u
#define TCM_BASE  0x00480000u
#define TCM_BYTES 0x10000u
#define RESET_PC  0x00000200u

static uint8_t ram[RAM_BYTES], tcm[TCM_BYTES];
static cpu_model_t *cpu;
static int      timer_set;              /* scr1_ref_timer(): the value the next timer read returns */
static uint32_t timer_val;

/* a timer / counter CSR (cycle, time, instret, their M- and high forms) reads what the core read:
 * the testbench hands it over before the step (scr1_ref_timer); without one, the model's own value */
static int timing_csr(void *ctx, uint32_t csr, uint64_t order, uint32_t *value)
{
    (void)ctx; (void)csr; (void)order;
    if (!timer_set) return 0;
    *value = timer_val;
    timer_set = 0;
    return 1;
}

/* the next timer/counter CSR read of the model returns v (the value the core read) */
void scr1_ref_timer(int v) { timer_val = (uint32_t)v; timer_set = 1; }

static uint32_t mmio_load(void *ctx, uint32_t a, int n) { (void)ctx; (void)a; (void)n; return 0; }
static void mmio_store(void *ctx, uint32_t a, int n, uint32_t v) { (void)ctx; (void)a; (void)n; (void)v; }

void scr1_ref_load(int addr, int data)
{
    uint32_t a = (uint32_t)addr & (RAM_BYTES - 4);
    for (int i = 0; i < 4; i++) ram[a + i] = (uint8_t)((uint32_t)data >> (8 * i));
}

int scr1_ref_start(void)
{
    static const cpu_region_t regions[2] = { { 0, RAM_BYTES, ram }, { TCM_BASE, TCM_BYTES, tcm } };
    static const cpu_csr_t fixed[] = { { 0x301, 0x40001104 }, { 0xF11, 0 }, { 0xF12, 8 }, { 0xF13, 0x22011200 } };
    cpu_env_t env = { regions, 2, mmio_load, mmio_store, timing_csr, NULL, fixed, 4 };
    const char *name = getenv("SCR1_REF");                   /* jit (default on aarch64), fast (elsewhere), iss, spike */
    char err[256];
    cpu_destroy(cpu);
    timer_set = 0;
#if defined(__aarch64__)
    const char *def = "jit";
#else
    const char *def = "fast";
#endif
    cpu = cpu_create(name ? name : def, "rv32imc_zicsr_zifencei_zicntr", &env, RESET_PC, err, sizeof err);
    if (!cpu && !name) cpu = cpu_create("fast", "rv32imc_zicsr_zifencei_zicntr", &env, RESET_PC, err, sizeof err);
    if (!cpu) { fprintf(stderr, "scr1_ref: %s\n", err); return 0; }
    return 1;
}

void scr1_ref_step(int *pc, int *pc_next, int *rd_addr, int *rd_wdata, int *trap)
{
    cpu_retire_t r;
    cpu_step(cpu, &r);
    *pc = (int)r.pc; *pc_next = (int)r.pc_next; *rd_addr = (int)r.rd_addr;
    *rd_wdata = (int)r.rd_wdata; *trap = (int)r.trap;
}

void scr1_ref_step_all(int *pc, int *pc_next, int *rd_addr, int *rd_wdata, int *trap,
                       int *mem_we, int *mem_wmask, int *mem_addr, int *mem_wdata,
                       int *csrw_we, int *csrw_cmd, int *csrw_addr, int *csrw_data)
{
    cpu_retire_t r;
    cpu_step(cpu, &r);
    *pc = (int)r.pc; *pc_next = (int)r.pc_next; *rd_addr = (int)r.rd_addr;
    *rd_wdata = (int)r.rd_wdata; *trap = (int)r.trap;
    *mem_we = (int)r.mem_we; *mem_wmask = (int)r.mem_wmask; *mem_addr = (int)r.mem_addr; *mem_wdata = (int)r.mem_wdata;
    *csrw_we = (int)r.csr_we; *csrw_cmd = (int)r.csr_wcmd; *csrw_addr = (int)r.csr_waddr; *csrw_data = (int)r.csr_wdata;
}

