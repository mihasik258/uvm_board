// ocv_main.cpp - main() of an OCV build of a UVM testbench (in place of Verilator's --main): the same
// simulation loop, and an exit code that says how the test ended - 0 when UVM reported no UVM_ERROR or
// UVM_FATAL, 1 when it did, 2 when run_test never summarized (the simulation stopped some other way).
// Scripts and CI can then tell a failed test from a passed one without reading the log.
// Build: -CFLAGS -DOCV_VTOP=V<top> (uvm/build_board.sh, examples/cv32e40p/vlt.sh).
#include "verilated.h"
#if VM_COVERAGE
#include "verilated_cov.h"
#endif
#include <string>
#define OCV_STR(x)  #x
#define OCV_HDR(t)  OCV_STR(t.h)
#define OCV_HDRX(t) OCV_HDR(t)
#include OCV_HDRX(OCV_VTOP)                    // "V<top>.h"

#include <memory>

extern int ocv_uvm_errors;                     // uvm/vlt/ocv_fast_random.cpp
// the coverage of every covergroup instance (Verilator's verilated_covergroup.cpp, OCV): absent in a
// build without covergroups
extern "C" void vl_covergroup_report(const char* filename, int parts) __attribute__((weak));

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
    // +ocv_cov_report=<file>: a line per covergroup instance "<covergroup> <option.name> <percent>",
    // each followed by its coverpoints and crosses "  <name> <covered>/<total> <percent>"
    {
        const std::string arg = contextp->commandArgsPlusMatch("ocv_cov_report=");
        if (!arg.empty() && vl_covergroup_report)
            vl_covergroup_report(arg.substr(std::string{"+ocv_cov_report="}.size()).c_str(), 1);
    }
#if VM_COVERAGE
    // the coverage database (--coverage: functional coverage included): +ocv_cov_dat=<file>, default coverage.dat
    {
        const std::string arg = contextp->commandArgsPlusMatch("ocv_cov_dat=");
        contextp->coveragep()->write(arg.empty() ? "coverage.dat" : arg.substr(std::string{"+ocv_cov_dat="}.size()));
    }
#endif
    contextp->statsPrintSummary();
    return ocv_uvm_errors < 0 ? 2 : ocv_uvm_errors > 0 ? 1 : 0;
}
