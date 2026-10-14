// t_fast_random.sv - checks OCV's in-process constraint solver (ocv_fast_random.cpp) against the
// constraints themselves: every randomize() result is checked in SystemVerilog, value counts show
// the distribution. Run with OCV_FAST_RANDOM=0 for the SMT-solver reference.
class item;
    rand bit signed [15:0] a, b;
    rand bit        [7:0]  len;
    rand bit        [3:0]  kind;
    rand bit        [31:0] addr;
    rand bit               en;
    rand bit        [63:0] wide;
    constraint c_len  { len inside {[1:16], 64, 128}; }
    constraint c_kind { kind != 0; kind < 12; }
    constraint c_ab   { a >= -100; a <= 100; b > a; b - a < 50; }   // relation: rejection
    constraint c_addr { addr[1:0] == 0; addr < 32'h1000; }
    constraint c_en   { en -> (len > 8); }                           // implication over two vars
    constraint c_wide { wide > 64'hFFFF_FFFF_0000_0000; }
endclass

module t;
    int n_ok, n_bad;
    int len_hist[256];
    int a_neg, kind_hist[16];
    initial begin
        item it = new;
        int N = 20000;
        void'($value$plusargs("N=%d", N));
        repeat (N) begin
            if (!it.randomize() with { kind dist { 1 := 8, [2:11] :/ 2 }; }) begin
                $display("FAIL randomize"); $finish;
            end
            if (!((it.len inside {[1:16], 64, 128}) && it.kind != 0 && it.kind < 12 &&
                  it.a >= -100 && it.a <= 100 && it.b > it.a && it.b - it.a < 50 &&
                  it.addr[1:0] == 0 && it.addr < 32'h1000 && (!it.en || it.len > 8) &&
                  it.wide > 64'hFFFF_FFFF_0000_0000)) begin
                n_bad++;
                if (n_bad < 5) $display("BAD len=%0d kind=%0d a=%0d b=%0d addr=%h en=%0d", it.len, it.kind, it.a, it.b, it.addr, it.en);
            end else n_ok++;
            len_hist[it.len]++; kind_hist[it.kind]++;
            if (it.a < 0) a_neg++;
        end
        // rand_mode(0): kind keeps its value and the rest still solves around it
        it.kind = 5; it.kind.rand_mode(0);
        repeat (100) begin
            void'(it.randomize());
            if (it.kind != 5) n_bad++;
        end
        $display("RESULT ok=%0d bad=%0d", n_ok, n_bad);
        // (len, en) solutions: len 1..8 with en=0 only, the other 10 values with en=0 or 1 -> 28
        $display("len: 3: %0d (uniform over the solutions: %0d), 64: %0d, 128: %0d (%0d)",
                 len_hist[3], N / 28, len_hist[64], len_hist[128], N * 2 / 28);
        // inline `with` dist: Verilator 5.052 drops the weights before any solver (class-level
        // dist keeps them), so kind is uniform over 1..11 here
        $display("kind: 1: %0d, 5: %0d (%0d each); a<0: %0d of %0d", kind_hist[1], kind_hist[5], N / 11, a_neg, N);
        $finish;
    end
endmodule
