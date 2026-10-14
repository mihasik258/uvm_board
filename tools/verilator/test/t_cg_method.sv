// t_cg_method.sv - an embedded covergroup whose coverpoint calls a method of the enclosing class
// (IEEE 1800-2023 19.4: the covergroup sees the class's members). The method reads the object's
// own field, so a wrong object would hit a different bin.
class base_c;
    int off;
    function int shifted(int v); return v + off; endfunction
endclass

class cov_c extends base_c;
    int k;
    function int plus_k(int v); return v + k; endfunction
    covergroup cg with function sample(int v);
        cp_own  : coverpoint plus_k(v)  { bins hit = {3}; }   // a: 2+1
        cp_base : coverpoint shifted(v) { bins hit = {6}; }   // a: 2+4
    endgroup
    function new(int k_, int off_); k = k_; off = off_; cg = new; endfunction
endclass

module t;
    initial begin
        cov_c a = new(1, 4), b = new(5, 8);
        a.cg.sample(2);                 // plus_k 3, shifted 6
        b.cg.sample(2);                 // plus_k 7, shifted 10 (b only)
        // a hits both bins (100 %), b neither (0 %): each call ran on its own object
        if (a.cg.get_inst_coverage() == 100.0 && b.cg.get_inst_coverage() == 0.0) $display("RESULT ok");
        else $display("RESULT bad a=%0.2f b=%0.2f", a.cg.get_inst_coverage(), b.cg.get_inst_coverage());
        $finish;
    end
endmodule
