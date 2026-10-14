/* bridge_dpi.c - the PS program of the board inside the bridge simulation (bridge_tb.sv): the same
 * runner and DUT model, with the bus going to the testbench's AXI4 master instead of mmap. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ocv.h"
#include "ocv_runner.h"

extern int sv_wr32(int off, int data);    /* exported SV tasks (bridge_tb.sv) */
extern int sv_rd32(int off, int *data);

static uint32_t tb_rd(ocv_bus_t *bus, uint32_t off)
{
    (void)bus;
    int v = 0;
    sv_rd32((int)off, &v);
    return (uint32_t)v;
}

static void tb_wr(ocv_bus_t *bus, uint32_t off, uint32_t v)
{
    (void)bus;
    sv_wr32((int)off, (int)v);
}

int ocv_dpi_main(const char *args, int *rc)
{
    static char buf[1024];
    char *argv[64];
    int argc = 0;
    snprintf(buf, sizeof buf, "%s", args);
    argv[argc++] = "ocv_bridge";
    for (char *t = strtok(buf, " ,"); t && argc < 63; t = strtok(NULL, " ,")) argv[argc++] = t;
    argv[argc] = NULL;
    ocv_bus_t bus = { tb_rd, tb_wr, NULL, NULL, NULL, 0, 0, NULL };
    fflush(stdout);
    *rc = ocv_runner_main(argc, argv, &bus);
    fflush(stdout);
    return 0;
}
