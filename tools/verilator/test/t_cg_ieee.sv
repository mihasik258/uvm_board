// t_cg_ieee.sv - covergroup forms core-v-verif's coverage uses (CVA6: uvma_isacov_cov_model, uvme_*_covg), each
// against the coverage IEEE 1800-2023 (19.5, 19.6, 19.11) gives it. One covergroup per case; each case prints
// "CASE <name> got <coverage> want <coverage>"; RESULT ok when all agree. Coverage of a covergroup is the
// average of its coverpoints and crosses (19.11, every weight 1).
typedef enum logic [1:0] {ZERO, POS, NEG, NONZERO} vt_t;

class cases;
    bit flag;

    // ignore_bins with a constant filter (isacov: ignore_bins POS_OFF = {POSITIVE} with (!rs1_is_signed))
    covergroup cg_ign_with(bit signedv) with function sample(vt_t v);
        cp: coverpoint v {
            ignore_bins POS_OFF = {POS} with (!signedv);
            ignore_bins NEG_OFF = {NEG} with (!signedv);
            ignore_bins NZ_OFF  = {NONZERO} with (signedv);
        }
    endgroup
    // ignored values are not in the automatic bins (19.5.5)
    covergroup cg_ign_auto with function sample(bit [1:0] v);
        cp: coverpoint v { ignore_bins IG = {2}; }
    endgroup
    // ignored values leave an explicit array bin too
    covergroup cg_ign_array with function sample(bit [1:0] v);
        cp: coverpoint v { bins B[] = {[0:3]}; ignore_bins IG = {2}; }
    endgroup
    // a bin's own iff (isacov: bins RD[] = {[0:31]} iff (instr.rd == instr.rs1))
    covergroup cg_bin_iff with function sample(bit [1:0] v, bit en);
        cp: coverpoint v { bins B[] = {[0:3]} iff (en); }
    endgroup
    // with on the values (19.5.1.1): bins of the values that pass
    covergroup cg_with_item with function sample(bit [2:0] v);
        cp: coverpoint v { bins EVEN[] = {[0:7]} with (item % 2 == 0); }
    endgroup
    // with filtering a wide range down to a few bins (isacov: bins CSR[] = {[USTATUS:MCONFIGPTR]} with (...))
    covergroup cg_with_wide(int lim) with function sample(bit [11:0] v);
        cp: coverpoint v { bins W[] = {[0:4095]} with (item < lim); }
    endgroup
    // a fixed number of array bins (19.5: values spread evenly, the last takes the rest)
    covergroup cg_sized with function sample(bit [2:0] v);
        cp: coverpoint v { bins Y[2] = {[0:7]}; }
    endgroup
    covergroup cg_sized_uneven with function sample(bit [2:0] v);
        cp: coverpoint v { bins Y[3] = {[0:7]}; }       // {0,1} {2,3} {4..7}
    endgroup
    // a fixed number of bins of the values a with that reads an argument lets through
    covergroup cg_sized_arg(int lim) with function sample(bit [2:0] v);
        cp: coverpoint v { bins Z[2] = {[0:7]} with (item != lim); }   // lim = 4: {0,1,2} {3,5,6,7}
    endgroup
    // a fixed number of bins over a huge range (CVA6's CSR model: bins other_values[3] = {[1:$]})
    covergroup cg_sized_huge with function sample(bit [31:0] v);
        cp: coverpoint v { bins O[3] = {[1:$]}; }
    endgroup
    // a cross switched off by an argument (isacov: ignore_bins IGN_OFF = cross_rd_rs1 with (!reg_crosses_enabled))
    covergroup cg_cross_off(bit en) with function sample(bit a, bit b);
        cpa: coverpoint a;
        cpb: coverpoint b;
        cx: cross cpa, cpb { ignore_bins IGN_OFF = cx with (!en); }
    endgroup
    // binsof ... intersect (isacov cg_sequential: ignore_bins IGN_HAZ = binsof(cp_gpr_raw_hazard) intersect {0})
    covergroup cg_binsof with function sample(bit [1:0] a, bit b);
        cpa: coverpoint a;
        cpb: coverpoint b;
        cx: cross cpa, cpb { ignore_bins IGN = binsof(cpa) intersect {0}; }
    endgroup
    // !binsof ... intersect (CVA6 exceptions: ignore_bins IGN = !binsof(cp_exception) intersect{2})
    covergroup cg_not_binsof with function sample(bit [1:0] a, bit b);
        cpa: coverpoint a;
        cpb: coverpoint b;
        cx: cross cpa, cpb { ignore_bins IGN = !binsof(cpa) intersect {2}; }
    endgroup
    // && of selections (CVA6 AXI: binsof(rid) intersect{3} && binsof(rlast) intersect{0})
    covergroup cg_binsof_and with function sample(bit [1:0] a, bit b);
        cpa: coverpoint a;
        cpb: coverpoint b;
        cx: cross cpa, cpb { ignore_bins IGN = binsof(cpa) intersect {1} && binsof(cpb) intersect {0}; }
    endgroup
    // || of selections
    covergroup cg_binsof_or with function sample(bit [1:0] a, bit b);
        cpa: coverpoint a;
        cpb: coverpoint b;
        cx: cross cpa, cpb { ignore_bins IGN = binsof(cpa) intersect {0} || binsof(cpb) intersect {1}; }
    endgroup
    // explicit cross bins (19.6.1): the named bin, and automatic bins for the tuples no named bin takes
    covergroup cg_cross_bins with function sample(bit [1:0] a, bit b);
        cpa: coverpoint a;
        cpb: coverpoint b;
        cx: cross cpa, cpb { bins ZB = binsof(cpb) intersect {0}; }
    endgroup

    function new(bit signedv, int lim, bit en);
        cg_ign_with = new(signedv);
        cg_ign_auto = new; cg_ign_array = new; cg_bin_iff = new; cg_with_item = new;
        cg_with_wide = new(lim); cg_sized = new; cg_sized_uneven = new; cg_sized_arg = new(lim);
        cg_sized_huge = new;
        cg_cross_off = new(en); cg_binsof = new; cg_not_binsof = new; cg_binsof_and = new; cg_binsof_or = new;
        cg_cross_bins = new;
    endfunction
endclass

module t;
    int bad = 0;
    function void check(string name, real got, real want);
        $display("CASE %-16s got %6.2f want %6.2f%s", name, got, want, (got > want + 0.01 || got < want - 0.01) ? "  <- DIFFERS" : "");
        if (got > want + 0.01 || got < want - 0.01) bad++;
    endfunction
    initial begin
        cases u = new(0, 4, 0);      // unsigned value types, 4 values pass the wide filter, crosses off
        cases s = new(1, 4, 1);      // signed, crosses on
        u.cg_ign_with.sample(ZERO);  // unsigned: bins ZERO, NONZERO -> 1 of 2
        s.cg_ign_with.sample(ZERO);  // signed: bins ZERO, POS, NEG -> 1 of 3
        check("ign_with u", u.cg_ign_with.get_inst_coverage(), 50.0);
        check("ign_with s", s.cg_ign_with.get_inst_coverage(), 100.0 / 3);
        u.cg_ign_auto.sample(0); u.cg_ign_auto.sample(2);              // bins 0,1,3 -> 1 of 3
        check("ign_auto", u.cg_ign_auto.get_inst_coverage(), 100.0 / 3);
        u.cg_ign_array.sample(0); u.cg_ign_array.sample(2);            // B[0],B[1],B[3] -> 1 of 3
        check("ign_array", u.cg_ign_array.get_inst_coverage(), 100.0 / 3);
        u.cg_bin_iff.sample(0, 0); u.cg_bin_iff.sample(1, 1);          // 1 of 4
        check("bin_iff", u.cg_bin_iff.get_inst_coverage(), 25.0);
        u.cg_with_item.sample(2); u.cg_with_item.sample(3);            // EVEN 0,2,4,6 -> 1 of 4
        check("with_item", u.cg_with_item.get_inst_coverage(), 25.0);
        u.cg_with_wide.sample(1); u.cg_with_wide.sample(100);          // W[0..3] -> 1 of 4
        check("with_wide", u.cg_with_wide.get_inst_coverage(), 25.0);
        u.cg_sized.sample(5);                                          // Y[0]={0..3} Y[1]={4..7} -> 1 of 2
        check("sized", u.cg_sized.get_inst_coverage(), 50.0);
        u.cg_sized_uneven.sample(1); u.cg_sized_uneven.sample(7);      // {0,1} {2,3} {4..7} -> 2 of 3
        check("sized_uneven", u.cg_sized_uneven.get_inst_coverage(), 200.0 / 3);
        u.cg_sized_arg.sample(2); u.cg_sized_arg.sample(4);          // 2 -> Z[0]; 4 filtered -> 1 of 2
        check("sized_arg", u.cg_sized_arg.get_inst_coverage(), 50.0);
        u.cg_sized_arg.sample(3);                                      // Z[1]
        check("sized_arg 2", u.cg_sized_arg.get_inst_coverage(), 100.0);
        u.cg_sized_huge.sample(1); u.cg_sized_huge.sample(32'hFFFFFFFF); u.cg_sized_huge.sample(0);  // O[0], O[2]
        check("sized_huge", u.cg_sized_huge.get_inst_coverage(), 200.0 / 3);
        u.cg_cross_off.sample(0, 0); s.cg_cross_off.sample(0, 0);
        check("cross_off u", u.cg_cross_off.get_inst_coverage(), 50.0);          // (50 + 50) / 2, the cross ignored
        check("cross_off s", s.cg_cross_off.get_inst_coverage(), (50 + 50 + 25) / 3.0);
        u.cg_binsof.sample(1, 0);   // cross: a in {1,2,3} x b {0,1} = 6, 1 hit
        check("binsof", u.cg_binsof.get_inst_coverage(), (25 + 50 + 100.0 / 6) / 3);
        u.cg_not_binsof.sample(2, 0);  // cross: a == 2 only: 2 tuples, 1 hit
        check("not_binsof", u.cg_not_binsof.get_inst_coverage(), (25 + 50 + 50) / 3.0);
        u.cg_binsof_and.sample(0, 0);  // cross: 8 - (1,0) = 7 tuples, 1 hit
        check("binsof_and", u.cg_binsof_and.get_inst_coverage(), (25 + 50 + 100.0 / 7) / 3);
        u.cg_binsof_or.sample(1, 0);   // cross: a != 0 and b != 1: 3 tuples, 1 hit
        check("binsof_or", u.cg_binsof_or.get_inst_coverage(), (25 + 50 + 100.0 / 3) / 3);
        u.cg_cross_bins.sample(3, 0);  // the cross: ZB (the 4 tuples with b == 0) + 4 automatic (b == 1): 1 of 5
        check("cross_bins", u.cg_cross_bins.get_inst_coverage(), (25 + 50 + 20) / 3.0);
        if (bad == 0) $display("RESULT ok"); else $display("RESULT bad %0d", bad);
        $finish;
    end
endmodule
