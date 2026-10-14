// ocv_cosim_main.cpp - co-simulation entry point: the generated <dut>_ocv wrapper runs in
// Verilator and the generic runner (the same C code as on the PS) talks to it through a bus
// backend that performs real AXI4-Lite transactions on the model.
//
// Built by sim/cosim.sh with -DOCV_VTOP=V<dut>_ocv. Extra options (before the runner's):
//   --axi-jitter N   hold RREADY/BREADY low for 0..N random cycles on each transaction
//   --trace FILE     write a VCD waveform
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>

#include "verilated.h"
#include "verilated_vcd_c.h"

#define OCV_STR2(x) #x
#define OCV_STR(x) OCV_STR2(x)
#include OCV_STR(OCV_VTOP.h)

#include "ocv.h"
#include "ocv_runner.h"
#include "ocv_vlt_sim.h"

namespace {

using Sim = OcvVltSim;
Sim *g_sim;
uint32_t bus_rd(ocv_bus_t *, uint32_t off) { return g_sim->read(off); }
void bus_wr(ocv_bus_t *, uint32_t off, uint32_t v) { g_sim->write(off, v); }

}  // namespace

int main(int argc, char **argv) {
    ocv_runner_set_exec(argc, argv);     // the full command line: a squash replay runs it again
    Sim sim;
    g_sim = &sim;
    const char *trace = nullptr;
    int out = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--axi-jitter") && i + 1 < argc) sim.jitter = (unsigned)atoi(argv[++i]);
#ifdef OCV_DMA_DW
        else if (!strcmp(argv[i], "--dma-ready") && i + 1 < argc) sim.dma_ready = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dma-bdelay") && i + 1 < argc) sim.dma_bdelay = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dma-bytes") && i + 1 < argc) sim.dma_mem.resize(strtoull(argv[++i], 0, 0));
#endif
        else if (!strcmp(argv[i], "--trace") && i + 1 < argc) trace = argv[++i];
        else argv[out++] = argv[i];
    }
    if (trace) {
        sim.ctx->traceEverOn(true);
        sim.vcd = new VerilatedVcdC;
        sim.top->trace(sim.vcd, 99);
        sim.vcd->open(trace);
    }

    sim.power_on();

    ocv_bus_t bus{bus_rd, bus_wr, nullptr, nullptr, nullptr, 0, 0, nullptr};
#ifdef OCV_DMA_DW
    if (sim.dma_mem.empty()) sim.dma_mem.resize(1u << 20);        // the default "PS memory": 1 MiB
    bus.dma_va = sim.dma_mem.data();
    bus.dma_pa = sim.dma_pa;
    bus.dma_size = sim.dma_mem.size();
#endif
    int rc = ocv_runner_main(out, argv, &bus);
    std::printf("COSIM: %llu clock cycles simulated\n", (unsigned long long)sim.cycle);
#ifdef OCV_DMA_DW
    std::printf("COSIM: %llu DMA bursts\n", (unsigned long long)sim.dma_bursts);
    if (sim.dma_errors && rc == 0) { std::printf("COSIM: FAIL - %llu bad DMA bursts\n", (unsigned long long)sim.dma_errors); rc = 2; }
#endif

    sim.top->final();
    if (sim.vcd) { sim.vcd->close(); delete sim.vcd; }
    return rc;
}
