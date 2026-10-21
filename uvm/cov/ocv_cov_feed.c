/* ocv_cov_feed.c - RVFI records for a testbench's own coverage models, from a file the reference model wrote
 * (--model-opt rvfi_out=<file>, models/cpu/ocv_cpu_model.c): one line per retired instruction, hex fields
 * insn pc trap rs1 rs1_rdata rs2 rs2_rdata rd rd_wdata mem_addr intr mcause mstatus mie mip [context]: context 1 -
 * a record the testbench's code sees but no covergroup samples (the state before a kept record, a record
 * filter's output: docs/COVERAGE.md).
 * DPI: ocv_cov_open(file) (0 = opened), ocv_cov_next(f[16]) (1 = a record in f, 0 = no more). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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
    char line[512];
    if (!feed) return 0;
    while (fgets(line, sizeof line, feed)) {
        char *p = line, *e;
        int n = 0;
        f[15] = 0;
        while (n < 16) {
            const unsigned long long v = strtoull(p, &e, 16);
            if (e == p) break;
            f[n++] = v;
            p = e;
        }
        if (n >= 15) return 1;
    }
    return 0;
}

#ifdef __cplusplus
}
#endif
