// t_soft.sv - soft constraints in OCV's in-process solver, as the SMT path relaxes them: all when they
// can hold; otherwise the later (higher priority) ones first, each kept if it still can - no SMT solver
class c_t;
    rand bit [7:0] x, y;
    constraint c_soft { soft x == 8'd5; soft y inside {[10:20]}; }
endclass
class d_t extends c_t;
    constraint c_hard { x > 8'd10; }          // the soft x == 5 cannot hold; soft y in [10:20] still can
endclass
class f_t;                                    // the soft one cannot hold with a 3-variable implication
    rand bit en, a, b;
    constraint c_imp  { en -> (a == 1 && b == 1); en == 1; }
    constraint c_soft { soft a == 0; soft b == 1; }   // a == 0 is dropped (proven by enumeration), b == 1 kept
endclass
class e_t extends c_t;
    constraint c_later { soft y == 8'd30; }   // later = higher priority than y in [10:20]: y == 30
endclass
module t;
    initial begin
        c_t c = new; d_t d = new; e_t e = new; f_t f = new; int ok = 1;
        repeat (100) begin
            if (!c.randomize() || c.x != 5 || !(c.y inside {[10:20]})) ok = 0;
        end
        repeat (20) if (!d.randomize() || !(d.x > 10) || !(d.y inside {[10:20]})) ok = 0;
        repeat (20) if (!e.randomize() || e.y != 30 || e.x != 5) ok = 0;
        repeat (20) if (!f.randomize() || !(f.en && f.a && f.b)) ok = 0;
        if (ok) $display("RESULT ok"); else $display("RESULT bad");
        $finish;
    end
endmodule
