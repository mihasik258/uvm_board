/* ocv_board_main.c - entry point on the PS: map the hub and run the generic runner.
 *
 *   ocv_<dut> --base 0x80300000 [--span 0x40000] [runner options]
 *
 * --base is the physical address the platform layer gave the hub; --span (default 1 MiB) must
 * cover the hub's AXI4-Lite window (2^addr_w bytes, see <dut>_ocv_meta.json).
 * An image built with DMA rings (ocv_gen.py --dma) gets PS memory for them (ocv_bus_mmap_dma); the
 * runner's --no-dma reads the outputs over the bus instead.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_bus_mmap.h"
#include "ocv_runner.h"

int main(int argc, char **argv)
{
    ocv_runner_set_exec(argc, argv);        /* before the options are taken out: for a squash replay */
    uint64_t base = 0;
    size_t span = 1u << 20;
    int out = 1;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--base") && i + 1 < argc)      base = strtoull(argv[++i], 0, 0);
        else if (!strcmp(argv[i], "--span") && i + 1 < argc) span = strtoull(argv[++i], 0, 0);
        else argv[out++] = argv[i];   /* keep for the runner */
    }
    if (!base) {
        fprintf(stderr, "usage: %s --base <hub physical address> [--span bytes] [runner options]\n", argv[0]);
        return 1;
    }
    ocv_bus_t bus;
    if (ocv_bus_mmap_open(&bus, base, span)) return 1;
    int no_dma = 0;
    for (int i = 1; i < out; i++) if (!strcmp(argv[i], "--no-dma")) no_dma = 1;
    if (!no_dma && ocv_bus_mmap_dma(&bus, 0) && getenv("OCV_DMA_VERBOSE"))
        fprintf(stderr, "ocv: no DMA memory (huge page or OCV_DMA_PHYS): outputs over the bus\n");
    return ocv_runner_main(out, argv, &bus);
}
