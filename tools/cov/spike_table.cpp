// spike_table - Spike's instruction-name table as its disassembler searches it (disasm.cc: lookup, probe_once),
// for a model that names instructions as isacov's monitor does without Spike (models/cpu/ocv_cov_filter.c):
// one line per entry, "<bucket> <match> <mask> <name>", each bucket in the order it is searched (the last
// added first). A word's name: the first entry of bucket (w & 0x7f) % 255, then (w & 0xe003) % 255, then 255
// whose (w & mask) == match; none: "unknown". The ISA string as isacov's monitor sets it (rv32imc).
//   spike_table [isa] > spike.tab        (with -names: also "<word> <name>" per hex word on stdin, Spike's own)
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <algorithm>                    // (the standard headers disasm.h uses, before the access trick below)
#include <bitset>
#include <cinttypes>
#include <sstream>
#include <string>
#include <type_traits>
#include <unordered_map>
#include <vector>
#define private public                  // (the search order: disassembler_t's chains)
#include "disasm.h"
#undef private
extern "C" void set_config(uint32_t bsize, char* isa, uint8_t is_big_endian);
extern "C" const char* get_insn_name(uint64_t insn);
extern disassembler_t* gp_disassembler;

int main(int argc, char** argv) {
    char isa[64] = "rv32imc";
    int names = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-names")) names = 1;
        else snprintf(isa, sizeof isa, "%s", argv[i]);
    }
    set_config(32, isa, 0);
    if (names) {
        unsigned long long w;
        while (scanf("%llx", &w) == 1) printf("%llx %s\n", w, get_insn_name(w));
        return 0;
    }
    for (int b = 0; b <= disassembler_t::HASH_SIZE; b++)
        for (auto it = gp_disassembler->chain[b].rbegin(); it != gp_disassembler->chain[b].rend(); ++it)
            printf("%d %x %x %s\n", b, (unsigned)(*it)->match, (unsigned)(*it)->mask, (*it)->get_name());
}
