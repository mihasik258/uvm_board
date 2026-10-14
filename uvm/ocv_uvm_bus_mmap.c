/* ocv_uvm_bus_mmap.c - the UVM layer's bus on the board: the hub mapped from /dev/mem at the
 * physical address the platform layer gave it (+OCV_BASE=... on the testbench's command line). */
#include <stdio.h>
#include <stdlib.h>

#include "ocv.h"
#include "ocv_bus_mmap.h"

/* the hub window of this DUT (OCV_ADDR_W from the generated metadata, included by the build) */
#ifndef OCV_UVM_SPAN
#ifdef OCV_ADDR_W
#define OCV_UVM_SPAN (1u << (OCV_ADDR_W < 12 ? 12 : OCV_ADDR_W))
#else
#error "build with -include <dut>_ocv_meta.h (OCV_ADDR_W: the hub window)"
#endif
#endif

int ocv_uvm_bus_open(ocv_bus_t *bus, uint64_t base, char *err, size_t errlen)
{
    if (!base) { snprintf(err, errlen, "no hub address: give +OCV_BASE=<physical address>"); return -1; }
    if (ocv_bus_mmap_open(bus, base, OCV_UVM_SPAN)) {
        snprintf(err, errlen, "cannot map the hub at 0x%llx", (unsigned long long)base);
        return -1;
    }
    if (!getenv("OCV_NO_DMA")) (void)ocv_bus_mmap_dma(bus, 0);   /* DMA rings, if the image has them */
    return 0;
}

void ocv_uvm_bus_close(ocv_bus_t *bus) { (void)bus; }   /* the mapping goes with the process */
