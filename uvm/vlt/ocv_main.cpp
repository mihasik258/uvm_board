// ocv_main.cpp - main() of an OCV build of a UVM testbench (in place of Verilator's --main): the same
// simulation loop, and an exit code that says how the test ended - 0 when UVM reported no UVM_ERROR or
// UVM_FATAL, 1 when it did, 2 when run_test never summarized (the simulation stopped some other way).
// Scripts and CI can then tell a failed test from a passed one without reading the log.
// Build: -CFLAGS -DOCV_VTOP=V<top> (uvm/build_board.sh, examples/cv32e40p/vlt.sh).
#include "verilated.h"
#define OCV_STR(x)  #x
#define OCV_HDR(t)  OCV_STR(t.h)
#define OCV_HDRX(t) OCV_HDR(t)
#include OCV_HDRX(OCV_VTOP)                    // "V<top>.h"

#include <memory>

extern int ocv_uvm_errors;                     // uvm/vlt/ocv_fast_random.cpp

int main(int argc, char** argv, char**) {
    Verilated::debug(0);
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->threads(1);
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<OCV_VTOP> topp{new OCV_VTOP{contextp.get(), ""}};
    while (VL_LIKELY(!contextp->gotFinish())) {
        topp->eval();
        if (!topp->eventsPending()) break;
        contextp->time(topp->nextTimeSlot());
    }
    topp->final();
    contextp->statsPrintSummary();
    return ocv_uvm_errors < 0 ? 2 : ocv_uvm_errors > 0 ? 1 : 0;
}
