// ocv_vlt_sim.h - the generated <dut>_ocv wrapper in Verilator, seen as the FPGA image: real
// AXI4-Lite transactions on the model for every hub register access. Shared by the co-simulation
// (ocv_cosim_main.cpp) and the UVM layer's PC bus (uvm/ocv_uvm_bus_vlt.cpp).
// Include after the Verilator top header; OCV_VTOP names the top class.
#ifndef OCV_VLT_SIM_H
#define OCV_VLT_SIM_H

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <memory>
#include <vector>

#include "verilated.h"
#include "verilated_vcd_c.h"

#include "ocv.h"

struct OcvVltSim {
    std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
    std::unique_ptr<OCV_VTOP> top;
    VerilatedVcdC *vcd = nullptr;
    uint64_t cycle = 0;
    unsigned jitter = 0;
    uint64_t rng = 0x9E3779B97F4A7C15ull;

    OcvVltSim() : top(new OCV_VTOP{ctx.get()}) {}

#ifdef OCV_DMA_DW
    // "PS memory" behind the wrapper's AXI4 master (DMA rings of the outputs): an AXI4 write slave
    // with random AWREADY/WREADY (dma_ready %), responses 0..dma_bdelay clocks late, per ID in order.
    static constexpr unsigned DWB = OCV_DMA_DW / 8;
    std::vector<uint8_t> dma_mem;
    uint64_t dma_pa = 0x800000000ull;   // the address the master uses for dma_mem[0]
    unsigned dma_ready = 100, dma_bdelay = 4;
    uint64_t dma_errors = 0, dma_bursts = 0;
    struct DmaAw { uint64_t addr; unsigned beats, id; };
    struct DmaB { uint64_t due; unsigned id; bool err; };
    std::deque<DmaAw> dma_aw;
    std::deque<std::vector<uint8_t>> dma_w;
    std::deque<bool> dma_wl;
    std::deque<DmaB> dma_b;
    bool dma_rand(unsigned pct) { return pct >= 100 || (unsigned)(ocv_rand(&rng) % 100) < pct; }
    void dma_beat(std::vector<uint8_t> &b) {
        b.resize(DWB);
#if OCV_DMA_DW <= 64
        uint64_t v = top->m_axi_wdata;
        std::memcpy(b.data(), &v, DWB);
#else
        for (unsigned i = 0; i < DWB / 4; i++) { uint32_t w = top->m_axi_wdata[i]; std::memcpy(&b[4 * i], &w, 4); }
#endif
    }
    void dma_before() {               // slave outputs for this clock
        top->m_axi_awready = dma_rand(dma_ready);
        top->m_axi_wready = dma_rand(dma_ready);
        const bool b = !dma_b.empty() && dma_b.front().due <= cycle;
        top->m_axi_bvalid = b;
        top->m_axi_bid = b ? dma_b.front().id : 0;
        top->m_axi_bresp = b && dma_b.front().err ? 2 : 0;
        top->m_axi_arready = 0; top->m_axi_rvalid = 0;
    }
    void dma_sample() {               // after the low-clock evaluation: what the rising edge transfers
        if (top->m_axi_awvalid && top->m_axi_awready)
            dma_aw.push_back({(uint64_t)top->m_axi_awaddr, (unsigned)top->m_axi_awlen + 1u, (unsigned)top->m_axi_awid});
        if (top->m_axi_wvalid && top->m_axi_wready) {
            dma_w.emplace_back();
            dma_beat(dma_w.back());
            dma_wl.push_back(top->m_axi_wlast);
        }
        if (top->m_axi_bvalid && top->m_axi_bready) dma_b.pop_front();
    }
    void dma_after() {                // complete bursts whose data is all here
        while (!dma_aw.empty() && dma_w.size() >= dma_aw.front().beats) {
            DmaAw a = dma_aw.front();
            dma_aw.pop_front();
            bool err = false;
            for (unsigned k = 0; k < a.beats; k++) {
                uint64_t at = a.addr + (uint64_t)k * DWB;
                if (dma_wl.front() != (k == a.beats - 1)) err = true;
                if (at < dma_pa || at + DWB > dma_pa + dma_mem.size()) err = true;
                else std::memcpy(&dma_mem[at - dma_pa], dma_w.front().data(), DWB);
                dma_w.pop_front();
                dma_wl.pop_front();
            }
            if (err && dma_errors++ < 5)
                std::fprintf(stderr, "COSIM: bad DMA burst at 0x%llx, %u beats (outside the memory or WLAST)\n",
                             (unsigned long long)a.addr, a.beats);
            dma_bursts++;
            uint64_t due = cycle + (dma_bdelay ? ocv_rand(&rng) % (dma_bdelay + 1) : 0);
            for (auto &b : dma_b) if (b.id == a.id && b.due > due) due = b.due;   // same ID: in order
            dma_b.push_back({due, a.id, err});
        }
    }
#else
    void dma_before() {}
    void dma_sample() {}
    void dma_after() {}
#endif

    void tick() {
        dma_before();
        top->clk = 0; top->eval(); dump(2 * cycle);
        dma_sample();
        top->clk = 1; top->eval(); dump(2 * cycle + 1);
        cycle++;
        dma_after();
    }
    void dump(uint64_t t) { if (vcd) vcd->dump(t); }
    unsigned delay() { return jitter ? (unsigned)(ocv_rand(&rng) % (jitter + 1)) : 0; }

    // Evaluate with the clock low so combinational outputs reflect the inputs just set; a
    // handshake seen here happens on the following rising edge.
    void settle() { top->clk = 0; top->eval(); }

    void write(uint32_t addr, uint32_t data) {
        top->s_axi_awaddr = addr; top->s_axi_awvalid = 1;
        top->s_axi_wdata = data;  top->s_axi_wstrb = 0xF; top->s_axi_wvalid = 1;
        top->s_axi_bready = 0;
        for (;;) { settle(); bool hs = top->s_axi_awready && top->s_axi_wready; tick(); if (hs) break; }
        top->s_axi_awvalid = 0; top->s_axi_wvalid = 0;
        for (unsigned d = delay(); d; d--) tick();
        top->s_axi_bready = 1;
        for (;;) { settle(); bool hs = top->s_axi_bvalid; tick(); if (hs) break; }
        top->s_axi_bready = 0;
    }

    uint32_t read(uint32_t addr) {
        top->s_axi_araddr = addr; top->s_axi_arvalid = 1; top->s_axi_rready = 0;
        for (;;) { settle(); bool hs = top->s_axi_arready; tick(); if (hs) break; }
        top->s_axi_arvalid = 0;
        for (unsigned d = delay(); d; d--) tick();
        top->s_axi_rready = 1;
        uint32_t v = 0;
        for (;;) { settle(); bool hs = top->s_axi_rvalid; v = top->s_axi_rdata; tick(); if (hs) break; }
        top->s_axi_rready = 0;
        return v;
    }

    // reset the wrapper (the hub; the DUT stays under the hub's own reset control)
    void power_on() {
        top->rst_n = 0;
        top->s_axi_awvalid = top->s_axi_wvalid = top->s_axi_bready = 0;
        top->s_axi_arvalid = top->s_axi_rready = 0;
        top->s_axi_awprot = top->s_axi_arprot = 0;
        for (int i = 0; i < 8; i++) tick();
        top->rst_n = 1;
        tick();
    }
};

#endif  // OCV_VLT_SIM_H
