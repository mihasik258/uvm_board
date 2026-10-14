/* Embench board support for OCV (tools/embench.sh): nothing timed, nothing printed, no early exit - main()
 * checks the result (verify_benchmark) and returns it; the BSP's exit writes it to the status device. */
#include <support.h>

void initialise_board(void) {}
void __attribute__((noinline)) __attribute__((externally_visible)) start_trigger(void) {}
void __attribute__((noinline)) __attribute__((externally_visible)) stop_trigger(void) {}
