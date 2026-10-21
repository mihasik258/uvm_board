/* ocv_cva6_cov_stubs.cpp - DPI functions of the CVA6 testbench that its coverage never calls (ELF loading, Spike's parameters):
 * present for the link only; any call says so */
#include <cstdio>
#include <cstdint>
#include <functional>
#include "svdpi.h"
struct extension_t;
static void ocv_unused(const char* n) { std::fprintf(stderr, "ocv coverage harness: DPI %s called (a stub)\n", n); }
extern "C" {
void read_elf(const char*) { ocv_unused("read_elf"); }
char get_section(int64_t*, int64_t*) { ocv_unused("get_section"); return 0; }
void read_section_sv(int64_t, const svOpenArrayHandle) { ocv_unused("read_section_sv"); }
char read_symbol(const char*, uint64_t*) { ocv_unused("read_symbol"); return 1; }
void spike_set_param_uint64_t(const char*, const char*, uint64_t) {}
void spike_set_param_str(const char*, const char*, const char*) {}
void spike_set_param_bool(const char*, const char*, svBit) {}
void spike_set_default_params(const char*) {}
}
/* Spike's extension registry: the disassembler asks for none (no custom extensions) */
std::function<extension_t*()> find_extension(const char*) { return [] { return (extension_t*)nullptr; }; }
