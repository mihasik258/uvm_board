/* t_fast.c - "fast" against "iss", retirement by retirement: the same program (objcopy -O verilog hex)
 * in both, SCR1's memory map (RAM 64 KiB at 0, TCM 64 KiB at 0x480000, the rest unmapped), the same
 * counter values; every field of every retirement must agree until the program jumps to SIM_EXIT (0xF8)
 * or the step limit. Also the speed of each model (ns per instruction on this machine).
 *
 * The model under test is driven by cpu_step and cpu_step_n in turn (n from 1 to 64); cpu_pc and every
 * cpu_xreg are compared whenever its batch is used up. The model under test: "fast", or the third argument
 * ("jit" on aarch64).
 *
 *   t_fast <program.hex> [max steps] [model]       exit 0: identical
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "cpu_model.h"
#include "rv32_iss.h"   /* rv32_rvc_expand */

#define RAM 0x10000u
#define TCM_BASE 0x480000u

static uint8_t ram[2][RAM], tcm[2][RAM];
static uint32_t mm_load(void *c, uint32_t a, int n) { (void)c; return a * 2654435761u ^ (uint32_t)n; }   /* any stable value */
static void mm_store(void *c, uint32_t a, int n, uint32_t v) { (void)c; (void)a; (void)n; (void)v; }
static int timing(void *c, uint32_t csr, uint64_t order, uint32_t *v) { (void)c; *v = (uint32_t)(order * 7 + csr); return 1; }

static int load_hex(const char *f, uint8_t *mem)
{
    FILE *h = fopen(f, "r");
    if (!h) return 0;
    char tok[64];
    uint32_t a = 0;
    while (fscanf(h, "%63s", tok) == 1) {
        if (tok[0] == '@') a = (uint32_t)strtoul(tok + 1, NULL, 16);
        else { if (a < RAM) mem[a] = (uint8_t)strtoul(tok, NULL, 16); a++; }
    }
    fclose(h);
    return 1;
}

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "t_fast <program.hex> [max steps]\n"); return 2; }
    long max = argc > 2 ? atol(argv[2]) : 50000000L;
    const char *model = argc > 3 ? argv[3] : "fast";
    cpu_model_t *m[2];
    cpu_region_t reg[2][2];
    for (int k = 0; k < 2; k++) {
        if (!load_hex(argv[1], ram[k])) { fprintf(stderr, "t_fast: %s: cannot read\n", argv[1]); return 2; }
        reg[k][0] = (cpu_region_t){ 0, RAM, ram[k] };
        reg[k][1] = (cpu_region_t){ TCM_BASE, RAM, tcm[k] };
        cpu_env_t env = { reg[k], 2, mm_load, mm_store, timing, NULL, NULL, 0 };
        char err[256];
        if (!(m[k] = cpu_create(k ? model : "iss", "rv32imc", &env, 0x200, err, sizeof err))) { fprintf(stderr, "%s\n", err); return 2; }
    }
    long n = 0, calls = 0;
    cpu_retire_t a, b;
    static cpu_retire_t bat[64];
    int bi = 0, bn = 0;
    for (; n < max; n++) {
        uint32_t xr[32];                       /* (the registers it reads: src1 / src2 checked against them) */
        for (int i = 0; i < 32; i++) xr[i] = cpu_xreg(m[0], i);
        memset(&a, 0, sizeof a);
        cpu_step(m[0], &a);
        if (bi == bn) {
            memset(bat, 0, sizeof bat);
            if (calls % 4 == 3) { cpu_step(m[1], &bat[0]); bn = 1; }
            else bn = cpu_step_n(m[1], bat, 1 + (int)(calls % 64));
            bi = 0; calls++;
        }
        b = bat[bi++];
        /* raw / src1 / src2: only from a model that gives them (cpu_impl_t.gives_src) - checked against the
         * instruction and the registers here, then left out of the comparison */
        if (m[1]->impl->gives_src) {
            const uint32_t i = b.insn, r = b.raw;
            if (((r & 3) == 3 ? r != i : rv32_rvc_expand((uint16_t)r) != i) && !b.trap) {
                printf("t_fast: %s: raw 0x%x does not give insn 0x%x at retirement %ld\n", argv[1], r, i, n);
                return 1;
            }
            if (!b.trap && (b.src1 != xr[(i >> 15) & 31] || b.src2 != xr[(i >> 20) & 31])) {
                printf("t_fast: %s: src1 0x%x src2 0x%x, the registers hold 0x%x 0x%x at retirement %ld\n", argv[1],
                       b.src1, b.src2, xr[(i >> 15) & 31], xr[(i >> 20) & 31], n);
                return 1;
            }
        }
        a.raw = b.raw = a.src1 = b.src1 = a.src2 = b.src2 = 0;
        if (memcmp(&a, &b, sizeof a)) {
            printf("t_fast: %s: DIFFER at retirement %ld, pc 0x%x: iss rd x%u=0x%x next 0x%x mem %u@0x%x=0x%x csr %u; "
                   "%s rd x%u=0x%x next 0x%x mem %u@0x%x=0x%x csr %u\n", argv[1], n, a.pc, a.rd_addr, a.rd_wdata, a.pc_next,
                   a.mem_we, a.mem_addr, a.mem_wdata, a.csr_we, model, b.rd_addr, b.rd_wdata, b.pc_next, b.mem_we, b.mem_addr,
                   b.mem_wdata, b.csr_we);
            return 1;
        }
        if (bi < bn) { if (a.pc_next == 0xF8) { n++; break; } continue; }   /* (state: at batch ends) */
        if (cpu_pc(m[0]) != cpu_pc(m[1])) { printf("t_fast: %s: pc differs after retirement %ld\n", argv[1], n); return 1; }
        for (int i = 0; i < 32; i++)
            if (cpu_xreg(m[0], i) != cpu_xreg(m[1], i)) {
                printf("t_fast: %s: x%d differs after retirement %ld (pc 0x%x): iss 0x%x %s 0x%x\n", argv[1], i, n, a.pc,
                       cpu_xreg(m[0], i), model, cpu_xreg(m[1], i));
                return 1;
            }
        if (a.pc_next == 0xF8) { n++; break; }
    }
    if (memcmp(ram[0], ram[1], RAM) || memcmp(tcm[0], tcm[1], RAM)) { printf("t_fast: %s: memories differ\n", argv[1]); return 1; }
    /* speed: each model alone over the same steps */
    double t[2];
    for (int k = 0; k < 2; k++) {
        cpu_destroy(m[k]);
        memset(ram[k], 0, RAM); memset(tcm[k], 0, RAM);
        load_hex(argv[1], ram[k]);
        cpu_env_t env = { reg[k], 2, mm_load, mm_store, timing, NULL, NULL, 0 };
        char err[256];
        m[k] = cpu_create(k ? model : "iss", "rv32imc", &env, 0x200, err, sizeof err);
        double t0 = now();
        for (long i = 0; i < n; i++) cpu_step(m[k], &a);
        t[k] = now() - t0;
    }
    printf("t_fast: %s: %ld retirements identical; iss %.1f ns, %s %.1f ns per instruction (x%.1f)\n",
           argv[1], n, 1e9 * t[0] / n, model, 1e9 * t[1] / n, t[0] / t[1]);
    return 0;
}
