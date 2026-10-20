/* Embench board support for OCV (tools/embench.sh with EMBENCH_BOARD=embench_board_instret): as the generic
 * one (nothing printed, main() checks the result), and the triggers read the retired-instruction counter,
 * both halves - as Embench's own RISC-V boards (examples/riscv32/cv32e40pv2fpga) read the cycle counter. */
#include <stdint.h>
#include <support.h>

volatile uint32_t start_instret_hi, start_instret_lo, stop_instret_hi, stop_instret_lo;

void initialise_board(void) {}
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
