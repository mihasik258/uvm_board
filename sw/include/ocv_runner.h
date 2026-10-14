/* ocv_runner.h - generic verification run, shared by the board and co-simulation mains. */
#ifndef OCV_RUNNER_H
#define OCV_RUNNER_H

#include "ocv.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Parse runner options from argv, verify the environment behind `bus` against the linked
 * model's metadata and run. Returns the process exit status (0 pass, 2 mismatch, 1 error). */
int ocv_runner_main(int argc, char **argv, ocv_bus_t *bus);
/* The main's own command line: a window that differs under --squash N is then located by running
 * the whole program again with --squash 1 (execv). Optional. */
void ocv_runner_set_exec(int argc, char **argv);

#ifdef __cplusplus
}
#endif
#endif /* OCV_RUNNER_H */
