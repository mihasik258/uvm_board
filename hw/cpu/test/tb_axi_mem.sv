// tb_axi_mem.sv - ocv_axi_mem on its own: a random AXI4 master (FIXED/INCR/WRAP bursts, narrow beats,
// random strobes and handshake delays) against a byte shadow of the memory; a device window answers
// reads with a function of the address and logs writes, both checked against what the master did.
//   hw/cpu/test/axi_mem.sh [DW] [transactions] [seed]
module tb_axi_mem;
    parameter int unsigned DW = 64;
    localparam int unsigned NB = DW / 8;
    localparam int unsigned LB = $clog2(NB);
    localparam int unsigned AW = 10;                       // RAM: 1K words at 0
    localparam logic [31:0] DEV = 32'h0001_0000;          // device window: 4 KiB
    int unsigned N = 3000, seed = 1;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic [3:0] awid, bid, arid, rid;
    logic [31:0] awaddr, araddr;
    logic [7:0] awlen, arlen;
    logic [2:0] awsize, arsize;
    logic [1:0] awburst, arburst, bresp, rresp;
    logic awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
    logic [DW-1:0] wdata, rdata;
    logic [NB-1:0] wstrb;
    logic ram_en, ram_hit, dev, dreq_valid, dreq_we, dresp_ready, dresp_valid, proto_err;
    logic [3:0] ram_we, dreq_be;
    logic [31:0] ram_addr, ram_wdata, ram_rdata, dreq_addr, dreq_wdata, dresp_rdata;
    logic [7:0] lat_gnt = 0, lat_rsp = 0;

    ocv_axi_mem #(.WRITE_EN(1'b1), .IDW(4), .DW(DW)) dut (.*, .lat_seed(32'h1234));

    // the RAM: one registered read
    logic [31:0] ram [1 << AW];
    assign ram_hit = ram_addr < (32'd4 << AW);
    assign dev     = dreq_addr >= DEV && dreq_addr < DEV + 32'h1000;
    always_ff @(posedge clk) if (ram_en) begin
        for (int i = 0; i < 4; i++) if (ram_we[i]) ram[ram_addr[AW+1:2]][8*i +: 8] <= ram_wdata[8*i +: 8];
        ram_rdata <= ram[ram_addr[AW+1:2]];
    end
    function automatic logic [31:0] dev_val(input logic [31:0] a);
        return a * 32'h9E3779B1 ^ 32'h5A5A0000;
    endfunction

    // the device: reads answered after a random wait, writes logged
    typedef struct { logic [31:0] addr; logic [3:0] be; logic [31:0] data; logic we; } dacc_t;
    dacc_t dlog[$], dexp[$];
    logic [31:0] dpend_addr;
    int dwait;
    initial begin dresp_valid = 0; dresp_rdata = 0; end
    always @(posedge clk) begin
        if (dreq_valid) dlog.push_back('{dreq_addr, dreq_be, dreq_we ? dreq_wdata & {{8{dreq_be[3]}}, {8{dreq_be[2]}}, {8{dreq_be[1]}}, {8{dreq_be[0]}}} : 32'h0, dreq_we});
        if (dreq_valid && !dreq_we) begin dpend_addr = dreq_addr; dwait = $urandom_range(0, 3); end
        dresp_valid <= 1'b0;
        if (dresp_ready && !dresp_valid) begin
            if (dwait == 0) begin dresp_valid <= 1'b1; dresp_rdata <= dev_val(dpend_addr); end
            else dwait--;
        end
    end

    // the master's shadow
    byte unsigned shadow [int unsigned];
    function automatic byte unsigned sh(input int unsigned a);
        return shadow.exists(a) ? shadow[a] : 8'h00;
    endfunction

    int errors = 0, beats = 0, devs = 0;
    always @(posedge clk) if (proto_err) begin $display("ERROR: proto_err"); errors++; end

    // the bytes of beat b of a burst (A3.4.1), as [lo, hi) and the lane of lo
    function automatic void beat_bytes(input logic [31:0] a0, input int sz, input int len, input int burst,
                                       input int b, output logic [31:0] lo, output logic [31:0] hi);
        logic [31:0] inc, al, a, wb, base;
        inc = 32'd1 << sz; al = a0 & ~(inc - 1);
        if (burst == 0) a = a0;
        else if (burst == 1) a = b == 0 ? a0 : al + inc * b;
        else begin wb = inc * (len + 1); base = a0 & ~(wb - 1); a = base | ((al + inc * b) & (wb - 1)); end
        lo = a; hi = (a & ~(inc - 1)) + inc;
    endfunction

    task automatic idle(input int maxw); repeat ($urandom_range(0, maxw)) @(posedge clk); endtask

    // a handshake: valid set at the falling edge; ready looked at before the rising edge that takes it
`define HS(rdy) #1; while (!(rdy)) begin @(negedge clk); #1; end @(posedge clk); #1;
    task automatic one(input bit we, input bit todev);
        int sz, len, burst;
        logic [DW-1:0] rd;
        logic rl;
        logic [31:0] a0, lo, hi;
        sz = $urandom_range(0, LB);
        burst = $urandom_range(0, 2);
        len = burst == 2 ? (2 << $urandom_range(0, 2)) - 1 : $urandom_range(0, 7);
        a0 = (todev ? DEV + ($urandom_range(0, 255) << 2) : $urandom_range(0, (4 << AW) - 256)) & ~32'h0;
        a0 = a0 + $urandom_range(0, NB - 1);
        if (burst == 2) a0 = a0 & ~((32'd1 << sz) - 1);           // WRAP: aligned
        if (todev) begin burst = 1; len = 0; a0 = a0 & ~((32'd1 << sz) - 1); end   // one beat, aligned
        if (we) begin
            idle(2);
            @(negedge clk); awvalid = 1; awaddr = a0; awlen = len; awsize = sz; awburst = burst; awid = 4'(beats);
            `HS(awready)
            awvalid = 0;
            for (int b = 0; b <= len; b++) begin
                logic [DW-1:0] d; logic [NB-1:0] s;
                beat_bytes(a0, sz, len, burst, b, lo, hi);
                d = {$urandom, $urandom}; s = '0;
                for (logic [31:0] x = lo; x < hi; x++) if ($urandom_range(0, 3) != 0) s[x % NB] = 1'b1;
                for (logic [31:0] x = lo; x < hi; x++)
                    if (s[x % NB]) begin
                        if (!todev) shadow[x] = d[8 * (x % NB) +: 8];
                    end
                if (todev)
                    for (int k = 0; k < NB / 4; k++)
                        if (s[4*k +: 4] != 0)
                            dexp.push_back('{((lo & ~(NB - 1)) + 4 * k), s[4*k +: 4], d[32*k +: 32] & {{8{s[4*k+3]}}, {8{s[4*k+2]}}, {8{s[4*k+1]}}, {8{s[4*k]}}}, 1'b1});
                idle(2);
                @(negedge clk); wvalid = 1; wdata = d; wstrb = s; wlast = b == len;
                `HS(wready)
                wvalid = 0;
                beats++;
            end
            idle(2);
            @(negedge clk); bready = 1;
            `HS(bvalid)
            bready = 0;
        end else begin
            idle(2);
            @(negedge clk); arvalid = 1; araddr = a0; arlen = len; arsize = sz; arburst = burst; arid = 4'(beats);
            `HS(arready)
            arvalid = 0;
            for (int b = 0; b <= len; b++) begin
                beat_bytes(a0, sz, len, burst, b, lo, hi);
                if (todev) begin
                    // the words the beat covers, in order
                    for (logic [31:0] w = lo & ~32'd3; w < hi; w += 4)
                        dexp.push_back('{w, sz == 0 ? 4'b0001 << lo[1:0] : sz == 1 ? (lo[1] ? 4'b1100 : 4'b0011) : 4'b1111, 32'h0, 1'b0});
                end
                idle(2);
                @(negedge clk); rready = 1;
                #1; while (!rvalid) begin @(negedge clk); #1; end
                rd = rdata; rl = rlast;                       // as the edge takes them
                @(posedge clk); #1;
                rready = 0;
                if (rl !== (b == len)) begin $display("ERROR: rlast %0d at beat %0d of %0d", rl, b, len); errors++; end
                for (logic [31:0] x = lo; x < hi; x++) begin
                    byte unsigned want = todev ? 8'(dev_val(x & ~32'd3) >> (8 * (x % 4))) : sh(x);
                    if (rd[8 * (x % NB) +: 8] !== want) begin
                        if (errors < 10) $display("ERROR: read %s 0x%08x size %0d burst %0d len %0d beat %0d: byte 0x%08x = %02x, want %02x",
                                                  todev ? "dev" : "ram", a0, sz, burst, len, b, x, rd[8 * (x % NB) +: 8], want);
                        errors++;
                    end
                end
                beats++;
            end
        end
        if (todev) devs++;
    endtask

    initial begin
        void'($value$plusargs("n=%d", N));
        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        for (int i = 0; i < (1 << AW); i++) ram[i] = 0;
        repeat (3) @(posedge clk);
        rst_n <= 1;
        for (int t = 0; t < N; t++) begin
            if (t == N / 2) begin lat_gnt <= 3; lat_rsp <= 4; end   // the second half with random waits
            one($urandom_range(0, 1), $urandom_range(0, 7) == 0);
        end
        repeat (5) @(posedge clk);
        if (dlog.size() != dexp.size()) begin
            $display("ERROR: device saw %0d accesses, master made %0d", dlog.size(), dexp.size()); errors++;
        end else
            foreach (dexp[i])
                if (dlog[i].addr != dexp[i].addr || dlog[i].be != dexp[i].be || dlog[i].we != dexp[i].we ||
                    (dexp[i].we && dlog[i].data != dexp[i].data)) begin
                    if (errors < 10) $display("ERROR: device access %0d: %s 0x%08x be %b data %08x, want %s 0x%08x be %b data %08x",
                        i, dlog[i].we ? "W" : "R", dlog[i].addr, dlog[i].be, dlog[i].data,
                        dexp[i].we ? "W" : "R", dexp[i].addr, dexp[i].be, dexp[i].data);
                    errors++;
                end
        if (errors) $display("tb_axi_mem DW=%0d: FAIL, %0d errors (%0d transactions, %0d beats)", DW, errors, N, beats);
        else $display("tb_axi_mem DW=%0d: PASS (%0d transactions, %0d beats, %0d device accesses)", DW, N, beats, dlog.size());
        $finish;
    end
endmodule
