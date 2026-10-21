// names: the Spike instruction name of each word on stdin (hex, one per line), as isacov's monitor gets it
#include <cstdint>
#include <cstdio>
extern "C" void set_config(uint32_t bsize, char* isa, uint8_t is_big_endian);
extern "C" void initialize_disassembler();
extern "C" const char* get_insn_name(uint64_t insn);
int main() {
    char isa[] = "rv32imc";
    set_config(32, isa, 0);
    initialize_disassembler();
    unsigned long long w;
    while (scanf("%llx", &w) == 1) printf("%llx %s\n", w, get_insn_name(w));
}
