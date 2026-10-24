/* ocv_cov_filter.h - the coverage-keeping record filter of the model's RVFI records (docs/COVERAGE.md, 2.3):
 * of every retired instruction's record, only those that give a testbench's covergroups something new, each with
 * the records before it its coverage models need (context). The table (which fields each coverpoint and cross
 * reads, the bit-wise ones, which records move isacov's history, Spike's instruction names) is generated from the
 * testbench's sources: tools/cov/cov_filter_gen.py. */
#ifndef OCV_COV_FILTER_H
#define OCV_COV_FILTER_H

#include <stdint.h>
#include <stdio.h>

#define COV_REC_N 15   /* insn pc trap rs1 rs1_rdata rs2 rs2_rdata rd rd_wdata mem_addr intr mcause mstatus mie mip */

/* the table; 0: loaded */
int  cov_filter_open(const char *table);
/* one record: written to out (as rvfi_out writes it) with its context when the filter keeps it */
void cov_filter_record(FILE *out, const uint32_t r[COV_REC_N]);
/* records seen, kept, context records written, distinct vectors, projection values (stderr) */
void cov_filter_report(void);
/* the record's line as rvfi_out writes it (context: the context flag after it) */
void cov_rvfi_line(FILE *out, const uint32_t r[COV_REC_N], int context);

#endif
