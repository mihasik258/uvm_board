/* t_gen.c - the generated programs on the reference model alone: each reaches SIM_EXIT, coverage after
 * the run; with a second model (e.g. "jit" on aarch64), both compared retirement by retirement.
 *
 *   [T_ISA=rv32imc_zicsr_zifencei:cva6] t_gen [programs] [seed] [model] [second model]   (default 6 1 fast)
 */
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cpu_model.h"
#include "rv32_iss.h"
#include "cv32_cov.h"
#include "cv32_gen.h"

#define RAM 0x10000u
static uint8_t image[RAM], ram[2][RAM];
static uint32_t mm_load(void *c, uint32_t a, int n) { (void)c; (void)a; (void)n; return 0; }
static void mm_store(void *c, uint32_t a, int n, uint32_t v) { (void)c; (void)a; (void)n; (void)v; }

int main(int argc, char **argv)
{
    unsigned np = argc > 1 ? (unsigned)atoi(argv[1]) : 6;
    uint64_t seed = argc > 2 ? strtoull(argv[2], 0, 0) : 1;
    const char *m0 = argc > 3 ? argv[3] : "fast", *m1 = argc > 4 ? argv[4] : NULL;
    unsigned long long total = 0, traps = 0;
    cv32_gen_profile(getenv("T_ISA") && strstr(getenv("T_ISA"), ":cva6") ? 1 : 0);
    for (unsigned p = 0; p < np; p++) {
        static cov_bin_t aim[4096];
        uint64_t arng = seed * 0x100000001B3ull + p;
        unsigned n_aim = cov_unhit(aim, 400, &arng);   /* (cov_profile: by T_ISA, below) */
        if (!cv32_gen(image, RAM, seed + p, 4000, 10, aim, n_aim)) { printf("t_gen: program %u does not fit\n", p); return 1; }
        image[0xF8] = 0x6F; image[0xF9] = image[0xFA] = image[0xFB] = 0;
        cpu_model_t *m[2] = { NULL, NULL };
        cpu_region_t reg[2] = { { 0, RAM, ram[0] }, { 0, RAM, ram[1] } };
        char err[256];
        for (int k = 0; k < (m1 ? 2 : 1); k++) {
            memcpy(ram[k], image, RAM);
            cpu_env_t env = { &reg[k], 1, mm_load, mm_store, NULL, NULL, NULL, 0 };
            const char *isa = getenv("T_ISA") ? getenv("T_ISA") : "rv32imc_zicsr_zifencei:cv32e40p";   /* (or :cva6) */
            if (!(m[k] = cpu_create(k ? m1 : m0, isa, &env, 0x200, err, sizeof err))) { printf("%s\n", err); return 2; }
        }
        cpu_env_t env0 = { &reg[0], 1, mm_load, mm_store, NULL, NULL, NULL, 0 };
        unsigned long long n = 0;
        cpu_retire_t a, b;
        for (; n < 50000000ull; n++) {
            const uint32_t pc = cpu_pc(m[0]), raw = cpu_env_load(&env0, pc, 2);
            const int c = (raw & 3) != 3;
            const uint32_t insn = c ? rv32_rvc_expand((uint16_t)raw) : cpu_env_load(&env0, pc, 4);
            const uint32_t oa = cpu_xreg(m[0], (insn >> 15) & 31), ob = cpu_xreg(m[0], (insn >> 20) & 31);
            memset(&a, 0, sizeof a);
            cpu_step(m[0], &a);
            cov_exec(raw, c, insn, oa, ob, (int)a.trap);
            traps += a.trap;
            if (m1) {
                memset(&b, 0, sizeof b);
                cpu_step(m[1], &b);
                if (memcmp(&a, &b, sizeof a)) {
                    printf("t_gen: program %u retirement %llu pc 0x%x: %s next 0x%x rd x%u=0x%x trap %u; %s next 0x%x rd x%u=0x%x trap %u\n",
                           p, n, a.pc, m0, a.pc_next, a.rd_addr, a.rd_wdata, a.trap, m1, b.pc_next, b.rd_addr, b.rd_wdata, b.trap);
                    return 1;
                }
            }
            if (a.pc_next == 0xF8) { n++; break; }
        }
        if (n >= 50000000ull) { printf("t_gen: program %u does not end (pc 0x%x)\n", p, cpu_pc(m[0])); return 1; }
        total += n;
        printf("t_gen: program %u: %llu instructions, coverage %u/%u\n", p + 1, n, cov_hit(), cov_total());
        cpu_destroy(m[0]); if (m[1]) cpu_destroy(m[1]);
    }
    {
        cov_bin_t un[16]; uint64_t r = 1;
        unsigned nu = cov_unhit(un, 16, &r);
        for (unsigned i = 0; i < nu; i++) printf("t_gen: not hit: %s op %d c1 %d c2 %d\n", cov_group_name(un[i].group), un[i].op, un[i].c1, un[i].c2);
    }
    printf("t_gen: %llu instructions, %llu exceptions; coverage %u of %u -", total, traps, cov_hit(), cov_total());
    for (int g = 0; g < COV_NG; g++) printf(" %s %u/%u%s", cov_group_name(g), cov_group_hit(g), cov_group_total(g), g + 1 < COV_NG ? "," : "\n");
    return 0;
}
