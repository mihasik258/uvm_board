// ocv_uvm_bus_vlt.cpp - the UVM layer's bus on a PC: the FPGA image (generated <dut>_ocv wrapper:
// hub + DUT) as a Verilator model in the testbench's process. Every register access is a real
// AXI4-Lite transaction on it, so the testbench runs exactly the code path it runs on the board.
// Built with -DOCV_VTOP=V<dut>_ocv against the Verilated wrapper. OCV_UVM_TRACE=file.vcd dumps it.
#include <cstdlib>

#define OCV_STR2(x) #x
#define OCV_STR(x) OCV_STR2(x)
#include OCV_STR(OCV_VTOP.h)

#include "ocv_vlt_sim.h"

namespace {
OcvVltSim *g_sim;
VerilatedContext *g_tb;     // the testbench is a Verilator model too: its context stays the thread's
struct KeepTb { ~KeepTb() { Verilated::threadContextp(g_tb); } };
uint32_t bus_rd(ocv_bus_t *, uint32_t off) { KeepTb k; return g_sim->read(off); }
void bus_wr(ocv_bus_t *, uint32_t off, uint32_t v) { KeepTb k; g_sim->write(off, v); }
}  // namespace

extern "C" int ocv_uvm_bus_open(ocv_bus_t *bus, uint64_t, char *, size_t)
{
    g_tb = Verilated::threadContextp();
    KeepTb k;
    g_sim = new OcvVltSim;
    if (const char *f = getenv("OCV_UVM_TRACE")) {
        g_sim->ctx->traceEverOn(true);
        g_sim->vcd = new VerilatedVcdC;
        g_sim->top->trace(g_sim->vcd, 99);
        g_sim->vcd->open(f);
    }
    g_sim->power_on();
    *bus = ocv_bus_t{bus_rd, bus_wr, nullptr, nullptr, nullptr, 0, 0, nullptr};
    return 0;
}

extern "C" void ocv_uvm_bus_close(ocv_bus_t *)
{
    KeepTb k;
    g_sim->top->final();
    if (g_sim->vcd) { g_sim->vcd->close(); delete g_sim->vcd; }
    delete g_sim;
    g_sim = nullptr;
}
