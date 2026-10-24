// cpu_spike.cc - Spike (riscv-isa-sim, the RISC-V reference ISA simulator) behind the cpu_model
// interface: the full ISA with traps, CSRs and privilege, as the golden model of a RISC-V DUT.
//
// Memory: regions with host memory are handed to Spike as is (its TLB caches pages, so regions
// must be 4 KiB aligned and sized); everything else goes through the environment's MMIO callbacks.
// One cpu_step() is processor_t::step(1): the instruction either retires (minstret advances) or
// traps (Spike takes the trap, pc goes to the handler). The written register is read back from the
// architectural state after the step - no commit log, so Spike keeps its fast execution path.
// Timing CSRs read by the instruction are replaced by the value the environment supplies (what the
// DUT read), in the record and in Spike's register file.
#include "cpu_model.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <strings.h>
#include <iostream>
#include <map>
#include <memory>
#include <new>

#include "cfg.h"
#include "csrs.h"
#include "mmu.h"
#include "processor.h"
#include "simif.h"

extern "C" uint32_t rv32_rvc_expand(uint16_t c);    // rv32_iss.c: compressed -> 32-bit form

extern "C" const cpu_impl_t cpu_spike_impl;

namespace {

class spike_cpu : public simif_t {
public:
    cpu_env_t       env;
    cfg_t           cfg;
    std::map<size_t, processor_t *> harts;
    processor_t    *proc = nullptr;
    uint64_t        order = 0;
    std::string     isa;
    int             xlen = 32;                      // from the ISA string (rv32... / rv64...)

    char *addr_to_mem(reg_t paddr) override
    {
        uint32_t avail;
        return reinterpret_cast<char *>(cpu_env_host(&env, (uint32_t)paddr, &avail));
    }
    bool mmio_load(reg_t paddr, size_t len, uint8_t *bytes) override
    {
        for (size_t o = 0; o < len; o += 4) {
            int n = (int)(len - o < 4 ? len - o : 4);
            uint32_t v = env.mmio_load ? env.mmio_load(env.ctx, (uint32_t)(paddr + o), n) : 0;
            for (int i = 0; i < n; i++) bytes[o + i] = (uint8_t)(v >> (8 * i));
        }
        return true;                                // unmapped space reads 0, as on the DUT's bus
    }
    bool mmio_store(reg_t paddr, size_t len, const uint8_t *bytes) override
    {
        for (size_t o = 0; o < len; o += 4) {
            int n = (int)(len - o < 4 ? len - o : 4);
            uint32_t v = 0;
            for (int i = 0; i < n; i++) v |= (uint32_t)bytes[o + i] << (8 * i);
            if (env.mmio_store) env.mmio_store(env.ctx, (uint32_t)(paddr + o), n, v);
        }
        return true;
    }
    void proc_reset(unsigned) override {}
    const cfg_t &get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t *> &get_harts() const override { return harts; }
    const char *get_symbol(uint64_t) override { return nullptr; }
};

struct spike_model {                                // what the C side sees: base first
    cpu_model_t base;
    spike_cpu  *cpu;
};
spike_cpu *of(cpu_model_t *m) { return reinterpret_cast<spike_model *>(m)->cpu; }

// RV64C where it differs from RV32C (the rest expands as RV32C): c.ld/c.sd, c.ldsp/c.sdsp in place of the FP
// loads/stores, c.addiw in place of c.jal, c.subw/c.addw, 6-bit shift amounts
uint32_t rv64_rvc_expand(uint16_t c)
{
    const uint32_t q = c & 3, f3 = (c >> 13) & 7;
    const uint32_t r1p = 8 + ((c >> 7) & 7), r2p = 8 + ((c >> 2) & 7), rd = (c >> 7) & 31, rs2 = (c >> 2) & 31;
    const uint32_t ldoff = ((c >> 10) & 7) << 3 | ((c >> 5) & 3) << 6;               // c.ld / c.sd offset
    if (q == 0 && f3 == 3) return ldoff << 20 | r1p << 15 | 3 << 12 | r2p << 7 | 0x03;   // ld rd', off(rs1')
    if (q == 0 && f3 == 7) {                                                         // sd rs2', off(rs1')
        return (ldoff >> 5) << 25 | r2p << 20 | r1p << 15 | 3 << 12 | (ldoff & 31) << 7 | 0x23;
    }
    if (q == 1 && f3 == 1 && rd) {                                                   // addiw rd, rd, imm
        int32_t imm = (int32_t)(((c >> 12) & 1) << 5 | ((c >> 2) & 31)) << 26 >> 26;
        return (uint32_t)imm << 20 | rd << 15 | rd << 7 | 0x1B;
    }
    if (q == 1 && f3 == 4 && ((c >> 10) & 3) == 3 && ((c >> 12) & 1)) {             // subw / addw
        const uint32_t op = (c >> 5) & 3;
        if (op == 0) return 0x20u << 25 | r2p << 20 | r1p << 15 | r1p << 7 | 0x3B;  // subw
        if (op == 1) return r2p << 20 | r1p << 15 | r1p << 7 | 0x3B;                 // addw
    }
    if ((q == 1 && f3 == 4 && ((c >> 10) & 3) < 2) || (q == 2 && f3 == 0)) {         // srli/srai/slli: shamt[5]
        const uint32_t sh = ((c >> 12) & 1) << 5 | ((c >> 2) & 31);
        if (q == 2) return sh << 20 | rd << 15 | 1 << 12 | rd << 7 | 0x13;
        const uint32_t sra = (c >> 10) & 1;
        return (sra << 30) | sh << 20 | r1p << 15 | 5 << 12 | r1p << 7 | 0x13;
    }
    const uint32_t spoff_l = ((c >> 5) & 3) << 3 | ((c >> 12) & 1) << 5 | ((c >> 2) & 7) << 6;   // c.ldsp
    if (q == 2 && f3 == 3 && rd) return spoff_l << 20 | 2 << 15 | 3 << 12 | rd << 7 | 0x03;
    if (q == 2 && f3 == 7) {                                                         // c.sdsp
        const uint32_t off = ((c >> 10) & 7) << 3 | ((c >> 7) & 7) << 6;
        return (off >> 5) << 25 | rs2 << 20 | 2 << 15 | 3 << 12 | (off & 31) << 7 | 0x23;
    }
    return rv32_rvc_expand(c);
}

uint32_t fetch_insn(const cpu_env_t *env, uint32_t pc, int xlen)
{
    uint32_t lo = cpu_env_load(env, pc, 2);
    if ((lo & 3) == 3) return cpu_env_load(env, pc, 4);
    return xlen == 64 ? rv64_rvc_expand((uint16_t)lo) : rv32_rvc_expand((uint16_t)lo);
}

bool writes_rd(uint32_t insn)
{
    switch (insn & 0x7F) {
    case 0x37: case 0x17: case 0x6F: case 0x67:     // lui auipc jal jalr
    case 0x03: case 0x13: case 0x33: case 0x2F:     // load op-imm op amo
    case 0x1B: case 0x3B:                           // op-imm-32 op-32 (RV64)
        return true;
    case 0x73:                                      // csr* (not ecall/ebreak/mret/wfi)
        return ((insn >> 12) & 7) != 0;
    default:
        return false;
    }
}

cpu_model_t *spike_create(const char *isa, const cpu_env_t *env, uint32_t reset_pc, char *err, size_t n)
{
    spike_model *w = new (std::nothrow) spike_model;
    spike_cpu *m = new (std::nothrow) spike_cpu;
    if (!w || !m) { delete w; delete m; snprintf(err, n, "out of memory"); return nullptr; }
    w->base.impl = &cpu_spike_impl;
    w->cpu = m;
    m->env = *env;
    for (int i = 0; i < env->n_regions; i++) {
        const cpu_region_t &r = env->regions[i];
        if (r.host && ((r.base | r.size) & 0xFFF)) {
            snprintf(err, n, "spike: host region 0x%x+0x%x must be 4 KiB aligned", r.base, r.size);
            delete m; delete w;
            return nullptr;
        }
    }
    m->isa = isa;
    m->xlen = !strncasecmp(isa, "rv64", 4) ? 64 : 32;
    m->cfg.isa = m->isa.c_str();
    m->cfg.priv = "M";
    m->cfg.hartids = {0};
    try {
        m->proc = new processor_t(m->cfg.isa, m->cfg.priv, &m->cfg, m, 0, false, nullptr, std::cerr);
    } catch (std::exception &e) {
        snprintf(err, n, "spike: %s", e.what());
        delete m; delete w;
        return nullptr;
    }
    m->harts[0] = m->proc;
    m->proc->reset();
    // the DUT's own values of implementation-defined CSRs: read-only constants (a write is ignored,
    // as by a WARL field with nothing writable); Spike's internal state (e.g. its misa) is untouched
    for (int i = 0; i < env->n_fixed_csrs; i++) {
        const cpu_csr_t &c = env->fixed_csrs[i];
        m->proc->get_state()->csrmap[c.csr] = std::make_shared<const_csr_t>(m->proc, c.csr, c.value);
    }
    m->proc->get_state()->pc = reset_pc;
    return &w->base;
}

void spike_step(cpu_model_t *mm, cpu_retire_t *r)
{
    spike_cpu *m = of(mm);
    state_t *st = m->proc->get_state();
    // values of XLEN bits (Spike keeps RV32's sign-extended in 64)
    const uint64_t xm = m->xlen == 64 ? ~0ull : 0xFFFFFFFFull;
    uint64_t pc = st->pc & xm;
    uint32_t insn = fetch_insn(&m->env, (uint32_t)pc, m->xlen);
    reg_t retired = st->minstret->read();
    uint64_t x1 = st->XPR[(insn >> 15) & 31] & xm, x2 = st->XPR[(insn >> 20) & 31] & xm;  // before it
    m->proc->step(1);
    bool trap = st->minstret->read() == retired;

    memset(r, 0, sizeof *r);
    r->order = m->order++;
    r->pc = pc;
    r->pc_next = st->pc & xm;
    r->insn = insn;
    r->trap = trap;
    if (trap && getenv("OCV_CPU_TRACE_TRAP"))      // debugging aid: why did the model trap?
        fprintf(stderr, "spike: trap at pc 0x%08llx insn 0x%08x mcause 0x%lx mtval 0x%lx\n", (unsigned long long)pc, insn,
                (unsigned long)st->mcause->read(), (unsigned long)st->mtval->read());
    uint32_t f3 = (insn >> 12) & 7, rs1 = (insn >> 15) & 31;
    if (!trap && (insn & 0x7F) == 0x23 && f3 <= (m->xlen == 64 ? 3u : 2u)) {   // a store: what it wrote
        int32_t imm = ((int32_t)insn >> 25 << 5) | (int32_t)((insn >> 7) & 0x1F);
        r->mem_we = 1;
        r->mem_wmask = (1u << (1u << f3)) - 1;
        r->mem_addr = (x1 + (uint64_t)(int64_t)imm) & xm;
        r->mem_wdata = x2 & (f3 == 3 ? ~0ull : (1ull << (8u << f3)) - 1);
    }
    if (!trap && (insn & 0x7F) == 0x73 && (f3 & 3) && ((f3 & 3) == 1 || rs1)) {   // a CSR write
        r->csr_we = 1;
        r->csr_wcmd = (f3 & 3) - 1;
        r->csr_waddr = insn >> 20;
        r->csr_wdata = (f3 & 4) ? rs1 : x1;
    }
    uint32_t rd = (insn >> 7) & 31;
    if (!trap && rd && writes_rd(insn)) {
        uint64_t v = st->XPR[rd] & xm;
        uint32_t csr = insn >> 20;
        if ((insn & 0x7F) == 0x73 && cpu_is_timing_csr(csr)) {
            r->timing_csr = 1;
            uint64_t dut;
            if (m->env.timing_csr && m->env.timing_csr(m->env.ctx, csr, r->order, &dut)) {
                v = dut & xm;                        // the DUT's value, also in Spike's registers
                st->XPR.write(rd, m->xlen == 64 ? (reg_t)v : (reg_t)(int64_t)(int32_t)(uint32_t)v);
            }
        }
        r->rd_addr = rd;
        r->rd_wdata = v;
    }
}

uint64_t spike_xreg(cpu_model_t *m, int i)
{
    return of(m)->proc->get_state()->XPR[i & 31] & (of(m)->xlen == 64 ? ~0ull : 0xFFFFFFFFull);
}
uint64_t spike_pc(cpu_model_t *m) { return of(m)->proc->get_state()->pc & (of(m)->xlen == 64 ? ~0ull : 0xFFFFFFFFull); }
void spike_destroy(cpu_model_t *mm)
{
    spike_cpu *m = of(mm);
    delete m->proc;
    delete m;
    delete reinterpret_cast<spike_model *>(mm);
}

}  // namespace

extern "C" const cpu_impl_t cpu_spike_impl = {
    "spike", "Spike, the RISC-V reference ISA simulator (riscv-isa-sim): full ISA, traps, CSRs", 1,
    spike_create, spike_step, spike_xreg, spike_pc, spike_destroy, NULL, NULL, NULL, 0, NULL, NULL
};
