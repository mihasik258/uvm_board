/* cpu_model.c - the processor-model registry, memory helpers, the built-in light ISS ("iss",
 * models/cpu/iss/rv32_iss.c: RV32IMC, no traps, no M-mode CSR state) and the same model as a
 * predecoding interpreter ("fast", rv32_fast.c). */
#include "cpu_model.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "rv32_iss.h"

/* ---------------- memory helpers ---------------- */
uint8_t *cpu_env_host(const cpu_env_t *env, uint32_t addr, uint32_t *avail)
{
    for (int i = 0; i < env->n_regions; i++) {
        const cpu_region_t *r = &env->regions[i];
        if (r->host && addr - r->base < r->size) {
            if (avail) *avail = r->size - (addr - r->base);
            return r->host + (addr - r->base);
        }
    }
    return NULL;
}

uint32_t cpu_env_load(const cpu_env_t *env, uint32_t addr, int size)
{
    uint32_t avail;
    uint8_t *p = cpu_env_host(env, addr, &avail);
    if (p && avail >= (uint32_t)size) {
        uint32_t v = 0;
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
        memcpy(&v, p, (size_t)size);                 /* the model's memory is little-endian too */
#else
        for (int i = 0; i < size; i++) v |= (uint32_t)p[i] << (8 * i);
#endif
        return v;
    }
    return env->mmio_load ? env->mmio_load(env->ctx, addr, size) : 0;
}

void cpu_env_store(const cpu_env_t *env, uint32_t addr, int size, uint32_t value)
{
    uint32_t avail;
    uint8_t *p = cpu_env_host(env, addr, &avail);
    if (p && avail >= (uint32_t)size) {
        for (int i = 0; i < size; i++) p[i] = (uint8_t)(value >> (8 * i));
        return;
    }
    if (env->mmio_store) env->mmio_store(env->ctx, addr, size, value);
}

int cpu_is_timing_csr(uint32_t csr) { return rv32_is_timing_csr(csr); }

/* ---------------- "iss": the built-in light model ---------------- */
typedef struct {
    cpu_model_t base;
    cpu_env_t   env;
    rv32_iss_t  s;
} iss_t;

static uint32_t iss_load(void *ctx, uint32_t a, int n) { return cpu_env_load(&((iss_t *)ctx)->env, a, n); }
static void iss_store(void *ctx, uint32_t a, int n, uint32_t v) { cpu_env_store(&((iss_t *)ctx)->env, a, n, v); }
static int iss_timing(void *ctx, uint32_t csr, uint64_t order, uint32_t *v)
{
    iss_t *m = ctx;
    return m->env.timing_csr ? m->env.timing_csr(m->env.ctx, csr, order, v) : 0;
}

static const cpu_impl_t iss_impl;

static cpu_model_t *iss_create(const char *isa, const cpu_env_t *env, uint32_t reset_pc, char *err, size_t n)
{
    (void)isa;                                   /* RV32IMC, whatever is asked: checked by the caller */
    iss_t *m = calloc(1, sizeof *m);
    if (!m) { snprintf(err, n, "out of memory"); return NULL; }
    m->base.impl = &iss_impl;
    m->env = *env;
    rv32_env_t e = { iss_load, iss_store, iss_timing, m };
    rv32_reset(&m->s, &e, reset_pc);
    return &m->base;
}

static void iss_step(cpu_model_t *mm, cpu_retire_t *r)
{
    iss_t *m = (iss_t *)mm;
    rv32_retire_t x;
    rv32_step(&m->s, &x);
    r->order = x.order; r->pc = x.pc; r->pc_next = x.pc_next;
    r->rd_addr = x.rd_addr; r->rd_wdata = x.rd_wdata; r->trap = x.trap;
    r->insn = x.insn; r->timing_csr = x.timing_csr;
    r->mem_we = x.mem_we; r->mem_wmask = x.mem_wmask; r->mem_addr = x.mem_addr; r->mem_wdata = x.mem_wdata;
    r->csr_we = x.csr_we; r->csr_wcmd = x.csr_wcmd; r->csr_waddr = x.csr_waddr; r->csr_wdata = x.csr_wdata;
}

static uint32_t iss_xreg(cpu_model_t *m, int i) { return ((iss_t *)m)->s.x[i & 31]; }
static uint32_t iss_pc(cpu_model_t *m) { return ((iss_t *)m)->s.pc; }
static void iss_destroy(cpu_model_t *m) { free(m); }

static const cpu_impl_t iss_impl = {
    "iss", "built-in light RV32IMC model (no traps, no M-mode CSR state)", 0,
    iss_create, iss_step, iss_xreg, iss_pc, iss_destroy, NULL, NULL, NULL, 0, NULL, NULL
};

/* ---------------- "fast": the same model as a predecoding interpreter ---------------- */
#include "rv32_fast.c"

/* ---------------- "jit": "fast" translated into AArch64 code (aarch64 hosts) ---------------- */
#include "rv32_jit.c"

/* ---------------- registry ---------------- */
#ifdef OCV_CPU_SPIKE
extern const cpu_impl_t cpu_spike_impl;
#endif
static const cpu_impl_t *const impls[] = {
    &iss_impl,
    &cpu_fast_impl,
#if defined(__aarch64__)
    &cpu_jit_impl,
#endif
#ifdef OCV_CPU_SPIKE
    &cpu_spike_impl,
#endif
};

const char *cpu_impls(void)
{
    static char buf[128];
    buf[0] = 0;
    for (size_t i = 0; i < sizeof impls / sizeof impls[0]; i++) {
        if (i) strncat(buf, " ", sizeof buf - strlen(buf) - 1);
        strncat(buf, impls[i]->name, sizeof buf - strlen(buf) - 1);
    }
    return buf;
}

cpu_model_t *cpu_create(const char *name, const char *isa, const cpu_env_t *env, uint32_t reset_pc,
                        char *err, size_t errlen)
{
    for (size_t i = 0; i < sizeof impls / sizeof impls[0]; i++)
        if (!strcmp(impls[i]->name, name)) return impls[i]->create(isa, env, reset_pc, err, errlen);
    snprintf(err, errlen, "processor model '%s' is not built in (available: %s)", name, cpu_impls());
    return NULL;
}
