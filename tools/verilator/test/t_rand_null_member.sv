// t_rand_null_member.sv - randomize() of an object whose rand class handle is null (IEEE 1800-2023
// 18.5.9: not randomized, not an error), while a global constraint reaches into another rand member
// (and that member's enum field: its range constraint must skip the null one too)
typedef enum bit [1:0] { K0, K1, K2 } kind_e;   // 3 of 4 codes: the solver restricts it to these

class sub_c;
    rand bit [3:0] x;
    rand kind_e    k;
    constraint c_x { x < 5; k != K1; }
endclass

class top_c;
    rand sub_c a;           // created
    rand sub_c b;           // left null (as a handle a later phase creates)
    rand bit [3:0] y;
    constraint c_y { y > 2; a.x != y; }
    function new(); a = new; endfunction
endclass

module t;
    initial begin
        top_c o = new;
        int ok = 1;
        repeat (50) begin
            if (!o.randomize()) ok = 0;
            if (!(o.a.x < 5 && o.y > 2 && o.a.x != o.y && o.a.k inside {K0, K2}) || o.b != null) ok = 0;
        end
        if (ok) $display("RESULT ok"); else $display("RESULT bad");
        $finish;
    end
endmodule
