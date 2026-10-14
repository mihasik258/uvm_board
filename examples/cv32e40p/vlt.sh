#!/usr/bin/env bash
# vlt.sh - the core-v-verif CV32E40P UVM testbench, unmodified, through Verilator (OCV's Verilator 5.052
# and UVM): can it be built at all? That decides both the PC baseline and the board form.
#
#   examples/cv32e40p/vlt.sh lint       parse + elaborate only (--lint-only)
#   examples/cv32e40p/vlt.sh build      the simulation (Verilator --binary): build/obj/Vtb
#   examples/cv32e40p/vlt.sh run +firmware=<hex> [plusargs]   the firmware test (prog.sh makes hex)
#   examples/cv32e40p/vlt.sh host|aarch64|vd100   the board form, lockstep (uvm/lockstep.py): host = the
#                                           FPGA simulated in the program, aarch64 = for the board, vd100 = its
#                                           FPGA image (VIVADO_SETTINGS, REF_BOOTBIN, LINUX_DIR; OCV_CLK_MHZ, 50)
#
# Without Imperas's ISS: its component is replaced by no_iss/ (as a run without +USE_ISS).
# Sources: CORE_V_VERIF (default pvo_scr1/ext/core-v-verif) and CV32E40P (default pvo_scr1/ext/cv32e40p,
# the hash core-v-verif names in cv32e40p/sim/ExternalRepos.mk). The file lists are core-v-verif's own.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OCV=$(cd "$HERE/../.." && pwd)
EXT=$(cd "$OCV/ext" && pwd)
export CORE_V_VERIF=${CORE_V_VERIF:-$EXT/core-v-verif}
export DESIGN_RTL_DIR=${CV32E40P:-$EXT/cv32e40p}/rtl
CV=$CORE_V_VERIF/cv32e40p
export DV_UVMT_PATH=$CV/tb/uvmt DV_UVME_PATH=$CV/env/uvme TBSRC_HOME=$CV/tb
export DV_SVLIB_PATH=$CV/vendor_lib/verilab
L=$CORE_V_VERIF/lib
export DV_UVML_HRTBT_PATH=$L/uvm_libs/uvml_hrtbt DV_UVML_TRN_PATH=$L/uvm_libs/uvml_trn DV_UVML_LOGS_PATH=$L/uvm_libs/uvml_logs
export DV_UVML_SB_PATH=$L/uvm_libs/uvml_sb DV_UVML_MEM_PATH=$L/uvm_libs/uvml_mem
for a in clknrst interrupt debug obi_memory core_cntrl isacov rvfi rvvi pma fencei; do
    v=DV_UVMA_$(echo $a | tr a-z A-Z)_PATH; export "$v=$L/uvm_agents/uvma_$a"
done
export DV_OVPM_HOME=$CORE_V_VERIF/vendor_lib/imperas DV_OVPM_MODEL=$CORE_V_VERIF/vendor_lib/imperas/imperas_DV_COREV
export DV_OVPM_DESIGN=$CORE_V_VERIF/vendor_lib/imperas/design
V=$OCV/build/verilator/install/bin/verilator
UVM=$OCV/build/verilator/uvm_ocv/uvm_pkg_all_v2020_3_2_nodpi.svh
OUT=${OUT:-$HERE/build}
mkdir -p "$OUT"
# svlib's DPI side, in C (Verilator would compile a .c as C++); io_printf (PLI 1.0's print to the
# simulator log, only on svlib's internal errors) is printf here
VI=$(dirname "$V")/../share/verilator/include
cc -std=gnu99 -O2 -w -fPIC -I"$VI" -I"$VI/vltstd" -Dio_printf=printf \
    -c "$DV_SVLIB_PATH/svlib/svlib/src/dpi/svlib_dpi.c" -o "$OUT/svlib_dpi.o"
cc -O2 -fno-pie -c "$OCV/uvm/vlt/ocv_prof.c" -o "$OUT/ocv_prof.o"
# the ISS component without the ISS (Imperas's library is commercial; no_iss/gen_no_iss.py says why)
python3 "$HERE/no_iss/gen_no_iss.py" "$CORE_V_VERIF" "$OUT/no_iss"
ARGS=(--timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style -Wno-BADSTDPRAGMA -Wno-SUPERNFIRST --error-limit 100000 +define+UVM
      +define+ISS +define+CV32E40P_TRACE_EXECUTION +incdir+"$OCV/uvm/vlt" "$OCV/uvm/vlt/ocv_fast_random.cpp" "$UVM"
      -f "$DESIGN_RTL_DIR/../cv32e40p_manifest.flist" -f "$DV_UVMT_PATH/uvmt_cv32e40p.flist" -f "$OUT/no_iss/no_iss.flist"
      --vpi -LDFLAGS "$OUT/svlib_dpi.o $OUT/ocv_prof.o -no-pie"   # svlib's DPI side (core-v-verif:
      # SVLIB_SRC); OCV's sampling profiler, idle unless OCV_PROF=<file> (tools/prof_report.py)
      --top-module uvmt_cv32e40p_tb)
case ${1:-lint} in
    lint) rc=0; "$V" --lint-only "${ARGS[@]}" > "$OUT/lint.log" 2>&1 || rc=$?
          echo "lint rc=$rc, $(grep -c '^%Error' "$OUT/lint.log") errors, $(grep -c '^%Warning' "$OUT/lint.log") warnings ($OUT/lint.log)"
          grep -m15 '^%Error' "$OUT/lint.log" || true; exit $rc ;;
    build) rm -rf "$OUT/obj.new"
          "$V" --binary -j "${OCV_MAKE_J:-6}" "${ARGS[@]}" --Mdir "$OUT/obj" -o Vtb > "$OUT/build.log" 2>&1 \
              || { grep -m20 '%Error\|error:' "$OUT/build.log"; exit 1; }
          echo "build: $OUT/obj/Vtb" ;;
    debug) "$V" --binary -j "${OCV_MAKE_J:-6}" --decorations node -CFLAGS "-g -O0" "${ARGS[@]}" --Mdir "$OUT/obj_dbg" \
              -o Vtb > "$OUT/build_dbg.log" 2>&1 || { grep -m20 '%Error\|error:' "$OUT/build_dbg.log"; exit 1; }
          echo "debug build: $OUT/obj_dbg/Vtb (C++ annotated with the SystemVerilog source lines)" ;;
    host|aarch64|vd100)
          # the testbench as it is on the board: lockstep (uvm/lockstep.py) - the core in the FPGA (host: its
          # Verilator model in the program), one clock per clock of the testbench, which runs unchanged
          T=$1; LS=$OUT/ls; mkdir -p "$LS"
          python3 "$OCV/uvm/flist.py" -f "$DV_UVMT_PATH/uvmt_cv32e40p.flist" -f "$OUT/no_iss/no_iss.flist" > "$LS/tb_files.txt"
          mapfile -t RTLM < <(grep -v '^//\|^+\|^\s*$' "$DESIGN_RTL_DIR/../cv32e40p_manifest.flist" | sed "s#\${DESIGN_RTL_DIR}#$DESIGN_RTL_DIR#")
          python3 "$OCV/uvm/lockstep.py" --tb $(cat "$LS/tb_files.txt") --dut cv32e40p_wrapper \
              --rtl "$UVM" "${RTLM[@]}" -I "$OCV/uvm/vlt" -I "$DESIGN_RTL_DIR/include" -I "$DESIGN_RTL_DIR/../bhv" \
              -I "$DESIGN_RTL_DIR/../bhv/include" -D CV32E40P_TRACE_EXECUTION -D UVM \
              --fpga-module cv32e40p_core --fpga-inst core_i --no-probe core_i.id_stage_i.register_file_i.mem \
              --clock "core_i.clk_i=clk_i" --clock "core_i.clk=clk_i & core_i.sleep_unit_i.clock_en" -o "$LS"
          # the FPGA: the core (rtl/; its clock gate: the simulation model for the host, OCV's clock gate for the
          # board) and its lockstep wrapper
          RTL="$(realpath "${RTLM[@]}" | grep "^$(realpath "$DESIGN_RTL_DIR")/" | tr '\n' ' ')"
          if [ "$T" = vd100 ]; then CG=$HERE/fpga/cv32e40p_clock_gate.sv; else CG=$DESIGN_RTL_DIR/../bhv/cv32e40p_sim_clock_gate.sv; fi
          export RTL="$RTL $CG $LS/cv32e40p_wrapper_ocv_ls.sv"
          export RTL_DEFINES="-I$DESIGN_RTL_DIR/include"
          if [ "$T" = vd100 ]; then
              read -r -a RA <<< "$RTL"
              OCV_GEN_FLAGS=--uvm OCV_CLK_MHZ=${OCV_CLK_MHZ:-50} OUT=$OUT/vd100_ls \
                  exec "$OCV/platforms/vd100/build.sh" "$LS/cv32e40p_wrapper_ls.json" - "${RA[@]}"
          fi
          # the testbench: its own lists, the core's packages in place of its modules, the bridge in place of the core
          python3 "$OCV/uvm/flist.py" --modules-not-packages -f "$DESIGN_RTL_DIR/../cv32e40p_manifest.flist" > "$LS/rtl_pkgs.f"
          case $T in aarch64) TCC=aarch64-linux-gnu-gcc; TF="-mcpu=cortex-a72" ;; *) TCC=cc; TF= ;; esac
          $TCC -std=gnu99 -O2 -w $TF -I"$VI" -I"$VI/vltstd" -Dio_printf=printf \
              -c "$DV_SVLIB_PATH/svlib/svlib/src/dpi/svlib_dpi.c" -o "$LS/svlib_dpi_$T.o"
          export TB_VFLAGS="-Wno-BADSTDPRAGMA -Wno-SUPERNFIRST --error-limit 100000 +define+UVM +define+ISS
              +define+CV32E40P_TRACE_EXECUTION -f $LS/rtl_pkgs.f -f $DV_UVMT_PATH/uvmt_cv32e40p.flist -f $OUT/no_iss/no_iss.flist --vpi"
          export TB_LDFLAGS="$LS/svlib_dpi_$T.o"
          OCV_OPT=${OCV_OPT:--Os} OCV_OPT_SLOW=${OCV_OPT_SLOW:--O0} OUT=$OUT/board_$T exec "$OCV/uvm/build_board.sh" "$T" "$LS/cv32e40p_wrapper_ls.json" uvmt_cv32e40p_tb \
              "$LS/cv32e40p_wrapper_bridge.sv" ;;
    run)  shift; cd "$OUT"
          # constraints the in-process solver does not take go to z3 (PATH, or pvo_scr1/ext/z3venv)
          Z3=$(command -v z3 || ls "$EXT"/z3venv/bin/z3 2>/dev/null || true)
          [ -n "$Z3" ] && export VERILATOR_SOLVER="${VERILATOR_SOLVER:-$Z3 --in}"
          exec ./obj/Vtb +UVM_TESTNAME=uvmt_cv32e40p_firmware_test_c "$@" ;;
    *)    sed -n '2,11p' "$0"; exit 1 ;;
esac
