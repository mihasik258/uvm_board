/* ocv_cov_feed.c - RVFI records for a testbench's own coverage models, from a file the reference model wrote
 * (--model-opt rvfi_out=<file>, models/cpu/ocv_cpu_model.c): one line per retired instruction, hex fields
 * insn pc trap rs1 rs1_rdata rs2 rs2_rdata rd rd_wdata mem_addr intr mcause mstatus mie mip.
 * DPI: ocv_cov_open(file) (0 = opened), ocv_cov_next(f[15]) (1 = a record in f, 0 = no more). */
#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {          /* (Verilator compiles a .c as C++) */
#endif

static FILE *feed;

int ocv_cov_open(const char *file)
{
    if (feed) fclose(feed);
    feed = fopen(file, "r");
    if (!feed) perror(file);
    return feed ? 0 : -1;
}

int ocv_cov_next(uint64_t *f)
{
    if (!feed) return 0;
    for (int i = 0; i < 15; i++) {
        unsigned long long v;
        if (fscanf(feed, "%llx", &v) != 1) return 0;
        f[i] = v;
    }
    return 1;
}

#ifdef __cplusplus
}
#endif
