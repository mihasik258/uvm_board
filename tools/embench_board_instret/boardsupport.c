/* Embench board support for OCV (tools/embench.sh with EMBENCH_BOARD=embench_board_instret): as the generic
 * one (nothing printed, main() checks the result), and the triggers read the retired-instruction counter,
 * both halves - as Embench's own RISC-V boards (examples/riscv32/cv32e40pv2fpga) read the cycle counter; on RV64 the
 * counter is one 64-bit CSR. */
#include <stdint.h>
#include <support.h>

void initialise_board(void) {}
#if __riscv_xlen == 64
volatile uint64_t start_instret, stop_instret;

void __attribute__((noinline)) __attribute__((externally_visible)) start_trigger(void)
{
    __asm__ volatile("csrr %0, minstret" : "=r"(start_instret));
}
void __attribute__((noinline)) __attribute__((externally_visible)) stop_trigger(void)
{
    __asm__ volatile("csrr %0, minstret" : "=r"(stop_instret));
}
#else
volatile uint32_t start_instret_hi, start_instret_lo, stop_instret_hi, stop_instret_lo;

void __attribute__((noinline)) __attribute__((externally_visible)) start_trigger(void)
{
    __asm__ volatile("csrr %0, minstret" : "=r"(start_instret_lo));
    __asm__ volatile("csrr %0, minstreth" : "=r"(start_instret_hi));
}
void __attribute__((noinline)) __attribute__((externally_visible)) stop_trigger(void)
{
    __asm__ volatile("csrr %0, minstret" : "=r"(stop_instret_lo));
    __asm__ volatile("csrr %0, minstreth" : "=r"(stop_instret_hi));
}
#endif
