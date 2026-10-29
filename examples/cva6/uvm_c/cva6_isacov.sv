// cva6_isacov.sv - the core-v-verif packages of the test's functional coverage (cva6_c_pkg.sv, isacov_cov): the
// isacov agent (uvma_isacov) with what it imports, and CVA6's configuration utilities (cv32a60x), unmodified, from
// CORE_V_VERIF (ext/core-v-verif) and CVA6 (ext/cva6); the include paths: run.sh. In simulation CVA6's RTL brings its
// configuration packages; the board builds (no RTL) take them here.
`ifdef OCV_BOARD
`include "config_pkg.sv"
`include "cv32a60x_config_pkg.sv"
`include "riscv_pkg.sv"
`include "ariane_pkg.sv"
`include "build_config_pkg.sv"
`endif
`include "uvml_hrtbt_pkg.sv"
`include "uvml_trn_pkg.sv"
`include "uvml_logs_pkg.sv"
`include "uvma_core_cntrl_pkg.sv"
`include "uvma_rvfi_pkg.sv"
`include "uvma_isacov_pkg.sv"
`include "uvma_cva6pkg_utils_pkg.sv"
