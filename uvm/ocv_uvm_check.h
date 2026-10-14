/* ocv_uvm_check.h - reference checkers of the OCV UVM layer: the testbench's reference model of
 * one output channel, as a C function over records. The same function checks every transaction
 * in simulation (called through DPI by ocv_checker, ocv_uvm_pkg.sv) and on the board (called right
 * where the records come out of the FPGA, without a UVM object per transaction - only mismatches,
 * counts and the end of the test reach UVM).
 *
 *   static const ocv_field_t *f_pc;           // looked up once: ocv_uvm_field("retire", "pc")
 *   static int my_ref(const uint32_t *dut, uint32_t *expected)
 *   {   ... ocv_set_raw(expected, f_pc, pc); ocv_get_raw(dut, f_pc) ...
 *       return is_last;                     // 1: this transaction ends the test
 *   }
 *   OCV_UVM_CHECKER("retire", my_ref)
 *
 * The comparison: what the testbench's scoreboard compares, given with OCV_UVM_CHECKER_CMP (uvm2board.py
 * writes it from the scoreboard: field -> compared bits); a plain OCV_UVM_CHECKER uses the descriptor's
 * field rules (exact, ignore, mask, abs, ulp).
 * With +OCV_SQUASH=N > 1 (a channel built with "squash") the function is called without the DUT's
 * record (dut = NULL): it must not need it, and should tell the end of the test from its own model.
 */
#ifndef OCV_UVM_CHECK_H
#define OCV_UVM_CHECK_H
#include <stdint.h>

#include "ocv.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*ocv_uvm_check_fn)(const uint32_t *dut, uint32_t *expected);
/* one compared field: its name and how - kind 0: exact equality of `bits`; kind 1: the absolute
 * difference at most `tol` (as integers of the field's width and signedness; no squash then) */
typedef struct { const char *field; uint64_t bits; int kind; uint64_t tol; } ocv_uvm_cmp_t;
/* a break pattern term: records with (field & mask) == value in every term of pattern `pat` close their
 * squash window and reach the reference function whole (as its `dut`) - the model takes a DUT value */
typedef struct { int pat; const char *field; uint64_t mask, value; } ocv_uvm_brk_t;
void ocv_uvm_checker(const char *channel, ocv_uvm_check_fn fn);
void ocv_uvm_checker_brk(const char *channel, const ocv_uvm_brk_t *brk, int n_brk);
void ocv_uvm_checker_cmp(const char *channel, ocv_uvm_check_fn fn, const ocv_uvm_cmp_t *cmp, int n_cmp);
/* a field of a channel of this DUT (exits with a message if there is none) */
const ocv_field_t *ocv_uvm_field(const char *channel, const char *field);
/* engine side (ocv_uvm_dpi.c): window of the squashed channels; run again with +OCV_SQUASH=1 */
void ocv_check_set_window(uint32_t n);
void ocv_check_replay(void);
/* 1 if channel ch may be squashed: the bits its checker compares are the bits the FPGA signs */
int  ocv_check_squash_ok(int ch);
/* the record words' compared bits of channel ch's checker (NULL if it has no exact comparison) */
const uint32_t *ocv_check_mask(int ch);
/* the break patterns of channel ch as record words (masks, values: [4][words]); their number */
int ocv_check_breaks(int ch, uint32_t mask[][32], uint32_t value[][32]);

#define OCV_UVM_CHECKER(channel, fn) \
    __attribute__((constructor)) static void ocv_uvm_register_##fn(void) { ocv_uvm_checker(channel, fn); }
#define OCV_UVM_CHECKER_BRK(channel, brk) \
    __attribute__((constructor)) static void ocv_uvm_register_brk_##brk(void) \
    { ocv_uvm_checker_brk(channel, brk, (int)(sizeof brk / sizeof brk[0])); }
#define OCV_UVM_CHECKER_CMP(channel, fn, cmp) \
    __attribute__((constructor)) static void ocv_uvm_register_##fn(void) \
    { ocv_uvm_checker_cmp(channel, fn, cmp, (int)(sizeof cmp / sizeof cmp[0])); }

#ifdef __cplusplus
}
#endif
#endif /* OCV_UVM_CHECK_H */
