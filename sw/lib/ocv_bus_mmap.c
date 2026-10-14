/* ocv_bus_mmap.c - bus backend for the PS: the hub's AXI4-Lite window mapped from /dev/mem. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE      /* madvise, MAP_ANONYMOUS, MAP_HUGETLB */
#endif
#include "ocv_bus_mmap.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef MAP_HUGETLB
#define MAP_HUGETLB 0x40000
#endif
#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS 0x20
#endif
/* (a build may include the C headers before _DEFAULT_SOURCE above takes effect, e.g. -include of the
 * metadata: then the Linux calls are not declared by them) */
int madvise(void *addr, size_t len, int advice);
#ifndef MADV_HUGEPAGE
#define MADV_HUGEPAGE 14
#endif

static uint32_t mm_rd(ocv_bus_t *bus, uint32_t off)
{
    return ((volatile uint32_t *)bus->priv)[off >> 2];
}

static void mm_wr(ocv_bus_t *bus, uint32_t off, uint32_t v)
{
    ((volatile uint32_t *)bus->priv)[off >> 2] = v;
}

/* Block read. Reads of the device window are performed one at a time (~400 ns each on the VD100),
 * so the width of one read decides the speed: on AArch64 32 bytes per instruction (two 128-bit
 * loads), measured 4x faster than word by word. The window needs natural alignment, so the edges
 * go word by word. */
static void mm_rd_block(ocv_bus_t *bus, uint32_t off, uint32_t *dst, uint32_t n)
{
    const volatile uint32_t *src = (const volatile uint32_t *)bus->priv + (off >> 2);
#if defined(__aarch64__)
    while (n && ((uintptr_t)src & 15)) { *dst++ = *src++; n--; }
    for (; n >= 8; n -= 8, src += 8, dst += 8)
        __asm__ volatile("ldp q0, q1, [%1]\n\tstp q0, q1, [%0]" : : "r"(dst), "r"(src) : "v0", "v1", "memory");
#endif
    while (n--) *dst++ = *src++;
}

int ocv_bus_mmap_open(ocv_bus_t *bus, uint64_t phys_base, size_t span)
{
    memset(bus, 0, sizeof *bus);
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("ocv: /dev/mem (run as root)"); return -1; }
    void *p = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys_base);
    close(fd);
    if (p == MAP_FAILED) { perror("ocv: mmap"); return -1; }
    bus->rd = mm_rd;
    bus->wr = mm_wr;
    bus->rd_block = mm_rd_block;
    bus->priv = p;
    return 0;
}

/* ---------------- DMA memory for the output rings ----------------
 * The FPGA writes the rings through the NoC straight into DDR, past the A72 caches (not coherent):
 * before the CPU reads what the FPGA wrote, those lines are cleaned and invalidated (DC CIVAC, which
 * Linux lets user space execute). The ring is only read by the CPU, so nothing of the CPU's is lost. */
static void dma_sync_civac(ocv_bus_t *bus, const void *p, size_t n)
{
    (void)bus;
#if defined(__aarch64__)
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    const uintptr_t line = 4u << ((ctr >> 16) & 0xF);          /* DminLine: smallest D-cache line */
    for (uintptr_t a = (uintptr_t)p & ~(line - 1); a < (uintptr_t)p + n; a += line)
        __asm__ volatile("dc civac, %0" : : "r"(a) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
#else
    (void)p; (void)n;
#endif
}

/* physical address of a mapped, locked page (root: /proc/self/pagemap shows frame numbers) */
static uint64_t virt_to_phys(const void *va)
{
    long pg = sysconf(_SC_PAGESIZE);
    int fd = open("/proc/self/pagemap", O_RDONLY);
    if (fd < 0) return 0;
    uint64_t e = 0;
    off_t off = (off_t)((uintptr_t)va / (uintptr_t)pg) * 8;
    ssize_t got = pread(fd, &e, sizeof e, off);
    close(fd);
    if (got != (ssize_t)sizeof e || !(e & (1ull << 63))) return 0;          /* not present */
    uint64_t pfn = e & ((1ull << 55) - 1);
    if (!pfn) return 0;                                                     /* no CAP_SYS_ADMIN */
    return pfn * (uint64_t)pg + ((uintptr_t)va % (uintptr_t)pg);
}

/* every page of [va, va + n) physically follows the one before */
static int contiguous(const uint8_t *va, size_t n, uint64_t pa)
{
    long pg = sysconf(_SC_PAGESIZE);
    for (size_t o = 0; o < n; o += (size_t)pg)
        if (virt_to_phys(va + o) != pa + o) return 0;
    return 1;
}

static int dma_use(ocv_bus_t *bus, void *va, size_t n, const char *how)
{
    memset(va, 0, n);                                    /* fault every page in */
    if (mlock(va, n)) { /* not fatal: hugetlb pages do not move anyway */ }
    uint64_t pa = virt_to_phys(va);
    if (!pa || !contiguous(va, n, pa)) return -1;
    dma_sync_civac(bus, va, n);                          /* the zeros reach DDR before the FPGA writes */
    bus->dma_va = va;
    bus->dma_pa = pa;
    bus->dma_size = n;
    bus->dma_sync = dma_sync_civac;
    if (getenv("OCV_DMA_VERBOSE"))
        fprintf(stderr, "ocv: DMA memory %zu KiB at 0x%llx (%s)\n", n >> 10, (unsigned long long)pa, how);
    return 0;
}

int ocv_bus_mmap_dma(ocv_bus_t *bus, size_t bytes)
{
    const size_t huge = 2u << 20;
    if (bytes == 0 || bytes > huge) bytes = huge;        /* one 2 MiB page: physically contiguous */
    /* 1. an explicit region (e.g. memory kept from Linux with mem= on the kernel command line):
     *    OCV_DMA_PHYS=<address>:<bytes>, mapped through /dev/mem (uncached, slower reads) */
    const char *ex = getenv("OCV_DMA_PHYS");
    if (ex) {
        char *end;
        uint64_t pa = strtoull(ex, &end, 0);
        size_t n = *end == ':' ? (size_t)strtoull(end + 1, 0, 0) : bytes;
        int fd = open("/dev/mem", O_RDWR | O_SYNC);
        void *va = fd < 0 ? MAP_FAILED : mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)pa);
        if (fd >= 0) close(fd);
        if (va == MAP_FAILED) { perror("ocv: OCV_DMA_PHYS"); return -1; }
        bus->dma_va = va; bus->dma_pa = pa; bus->dma_size = n; bus->dma_sync = NULL;
        return 0;
    }
    /* 2. a huge page (hugetlbfs; one is reserved here if the pool is empty) */
    for (int attempt = 0; attempt < 2; attempt++) {
        void *va = mmap(NULL, huge, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
        if (va != MAP_FAILED) {
            if (!dma_use(bus, va, huge, "huge page")) return 0;
            munmap(va, huge);
            break;
        }
        FILE *f = fopen("/proc/sys/vm/nr_hugepages", "r+");
        if (!f) break;
        long have = 0;
        if (fscanf(f, "%ld", &have) != 1) have = 0;
        rewind(f);
        fprintf(f, "%ld\n", have + 1);
        fclose(f);
    }
    /* 3. a transparent huge page: 2 MiB aligned anonymous memory, if the kernel backs it with one */
    uint8_t *raw = mmap(NULL, 2 * huge, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw != MAP_FAILED) {
        uint8_t *va = (uint8_t *)(((uintptr_t)raw + huge - 1) & ~(uintptr_t)(huge - 1));
        madvise(va, huge, MADV_HUGEPAGE);
        if (!dma_use(bus, va, huge, "transparent huge page")) return 0;
        munmap(raw, 2 * huge);
    }
    errno = ENOMEM;
    return -1;
}
