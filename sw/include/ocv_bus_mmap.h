/* ocv_bus_mmap.h - bus backend for the PS (Linux, /dev/mem). */
#ifndef OCV_BUS_MMAP_H
#define OCV_BUS_MMAP_H

#include <stddef.h>
#include <stdint.h>
#include "ocv.h"

/* Map `span` bytes of the hub at physical address `phys_base`. Returns 0 or -1 (errno printed). */
int ocv_bus_mmap_open(ocv_bus_t *bus, uint64_t phys_base, size_t span);

/* Give the bus memory the FPGA can write (the DMA rings of outputs built with OCV_KIND_DMA):
 * physically contiguous, up to `bytes` (0 or more than 2 MiB: 2 MiB). Tried in order: the region
 * OCV_DMA_PHYS=<address>[:<bytes>] (through /dev/mem), a huge page (hugetlbfs; one is reserved if
 * the pool is empty), a transparent huge page. Needs root (physical addresses from pagemap).
 * Returns 0, or -1: then the outputs are read over the bus as before. */
int ocv_bus_mmap_dma(ocv_bus_t *bus, size_t bytes);

#endif /* OCV_BUS_MMAP_H */
