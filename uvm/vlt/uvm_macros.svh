// uvm_macros.svh - for the Verilator build: the UVM macros come with the single-file UVM package
// (uvm_pkg_all_*.svh, compiled first). This file only lets testbench sources keep their usual
// `include "uvm_macros.svh" unchanged.
`ifndef UVM_MACROS_SVH
`error "compile the single-file UVM package (uvm_pkg_all_*.svh) before the testbench"
`endif
