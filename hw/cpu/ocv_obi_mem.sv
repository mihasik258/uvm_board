/// ocv_obi_mem - an OBI slave (the core's instruction or data port) -> one port of ocv_cpu_ram, and the
/// device windows (gen/cpu_wrap.py `device`): an access with `dev` high goes to the processor instead.
///
/// RAM: a request is granted after a random wait of 0..lat_gnt clocks, its response comes after 0..lat_rsp
/// more (pipelined, in request order: a queue of up to 4); lat_gnt = lat_rsp = 0: granted at once, answered
/// the next clock. The waits come from a generator seeded by lat_seed (the same seed, the same waits: the
/// run repeats exactly). The RAM port carries the byte address; the wrapper's RAM regions say whether one
/// holds it (ram_hit): if none and not a device window, writes are dropped and reads return 0.
/// Device: a write is posted - sent as a request record, answered like a RAM access (the core does not wait
/// for the processor); a read is sent as a request record and granted only when the processor's answer is
/// there (`dresp_ready` meanwhile: the hub holds the core's clock, so the core never sees how long the
/// answer took). One device read at a time.
/// Protocol check: while a request waits for its grant, req stays high and addr, we, be (and wdata of a
/// write) do not change (OBI 1.x) - else `proto_err` for one clock.
module ocv_obi_mem #(
    parameter logic [31:0] SALT = 32'h0      // makes the waits of two ports differ
) (
    input  logic          clk,
    input  logic          rst_n,
    // OBI slave
    input  logic          req,
    output logic          gnt,
    output logic          rvalid,
    input  logic [31:0]   addr,
    input  logic          we,
    input  logic [3:0]    be,
    input  logic [31:0]   wdata,
    output logic [31:0]   rdata,
    // RAM port
    output logic          ram_en,
    output logic [3:0]    ram_we,
    output logic [31:0]   ram_addr,      // byte address
    output logic [31:0]   ram_wdata,
    input  logic [31:0]   ram_rdata,
    input  logic          ram_hit,       // a RAM region holds ram_addr
    // device windows
    input  logic          dev,           // addr is in a device window
    output logic          dreq_valid,    // a device access (one clock): ...
    output logic [31:0]   dreq_addr,     // ... its address, write or read, byte enables, data
    output logic          dreq_we,
    output logic [3:0]    dreq_be,
    output logic [31:0]   dreq_wdata,
    output logic          dresp_ready,   // waiting for the answer to a device read
    input  logic          dresp_valid,
    input  logic [31:0]   dresp_rdata,
    // latency (held while the core runs) and the protocol check
    input  logic [31:0]   lat_seed,
    input  logic [7:0]    lat_gnt,
    input  logic [7:0]    lat_rsp,
    output logic          proto_err
);
    typedef enum logic [1:0] {D_IDLE, D_WAIT} dstate_e;
    dstate_e     d_q;
    logic        in_range, ram_q, dev_rd_q;
    logic [31:0] drdata_q;
    assign in_range = ram_hit;

    // the waits: xorshift32, one step per clock
    logic [31:0] rnd_q, r1, r2, rnd_n;
    assign r1    = rnd_q ^ (rnd_q << 13);
    assign r2    = r1 ^ (r1 >> 17);
    assign rnd_n = r2 ^ (r2 << 5);
    function automatic logic [7:0] draw(input logic [31:0] r, input logic [7:0] max);
        return max == 0 ? 8'd0 : 8'(r[15:0] % (16'(max) + 16'd1));
    endfunction

    // grant: after the wait (a device read: when its answer is there)
    logic       armed_q, full, gnt_ok;
    logic [7:0] gw_q;
    assign gnt_ok      = lat_gnt == 0 ? 1'b1 : (armed_q && gw_q == 0);
    assign gnt         = req && gnt_ok && !full && (!dev || we || (d_q == D_WAIT && dresp_valid));
    assign dreq_valid  = req && dev && ((we && gnt) || (!we && d_q == D_IDLE && gnt_ok && !full));
    assign dresp_ready = d_q == D_WAIT;
    assign dreq_addr   = addr;
    assign dreq_we     = we;
    assign dreq_be     = be;
    assign dreq_wdata  = wdata;
    assign ram_en      = req && gnt && !dev;
    assign ram_we      = (req && gnt && !dev && we && in_range) ? be : 4'b0;
    assign ram_addr    = addr;
    assign ram_wdata   = wdata;

    // responses: the clock after the grant the data is known (RAM read, or the device's answer); it then
    // waits 0..lat_rsp clocks in a queue of 4, in order
    logic        got_q, pop, bypass;
    logic [31:0] data_now;
    logic [7:0]  rw;
    logic [31:0] q_data [4];
    logic [7:0]  q_wait [4];
    logic [2:0]  q_n;
    assign data_now = dev_rd_q ? drdata_q : (ram_q ? ram_rdata : 32'h0);
    assign rw       = draw(rnd_q, lat_rsp);
    assign bypass   = got_q && q_n == 0 && rw == 0;   // nothing waiting, no delay: at once (as without latency)
    assign pop      = q_n != 0 && q_wait[0] == 0;
    assign rvalid   = bypass || pop;
    assign rdata    = pop ? q_data[0] : data_now;
    assign full     = q_n + 3'(got_q) >= 3'd4;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            d_q <= D_IDLE; ram_q <= 1'b0; dev_rd_q <= 1'b0; drdata_q <= '0; got_q <= 1'b0;
            armed_q <= 1'b0; gw_q <= '0; q_n <= '0;
            rnd_q <= (lat_seed ^ SALT) == 0 ? 32'h1 : lat_seed ^ SALT;
            for (int i = 0; i < 4; i++) begin q_data[i] <= '0; q_wait[i] <= '0; end
        end else begin
            rnd_q    <= rnd_n;
            got_q    <= req && gnt;
            ram_q    <= in_range && !dev;
            dev_rd_q <= req && gnt && dev && !we;
            // the grant's wait
            if (req && gnt)                armed_q <= 1'b0;
            else if (req && !armed_q)      begin armed_q <= 1'b1; gw_q <= draw(rnd_q, lat_gnt); end
            else if (armed_q && gw_q != 0) gw_q <= gw_q - 8'd1;
            // a device read
            unique case (d_q)
                D_IDLE: if (dreq_valid && !we) d_q <= D_WAIT;
                D_WAIT: if (dresp_valid) begin d_q <= D_IDLE; drdata_q <= dresp_rdata; end
                default: d_q <= D_IDLE;
            endcase
            // the response queue: count down, pop the head, push the new one
            begin
                logic [31:0] nd [4];
                logic [7:0]  nw [4];
                logic [2:0]  n;
                n = q_n;
                for (int i = 0; i < 4; i++) begin nd[i] = q_data[i]; nw[i] = q_wait[i] == 0 ? 8'd0 : q_wait[i] - 8'd1; end
                if (pop) begin
                    for (int i = 0; i < 3; i++) begin nd[i] = nd[i + 1]; nw[i] = nw[i + 1]; end
                    n = n - 3'd1;
                end
                if (got_q && !bypass) begin
                    nd[n[1:0]] = data_now;
                    nw[n[1:0]] = rw == 0 ? 8'd0 : rw - 8'd1;
                    n = n + 3'd1;
                end
                for (int i = 0; i < 4; i++) begin q_data[i] <= nd[i]; q_wait[i] <= nw[i]; end
                q_n <= n;
            end
        end
    end

    // protocol: a waiting request keeps req and its address and data
    logic        wait_q;
    logic [68:0] held_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin wait_q <= 1'b0; held_q <= '0; end
        else begin
            wait_q <= req && !gnt;
            held_q <= {we, be, addr, wdata};
        end
    end
    assign proto_err = rst_n && wait_q && (!req || {we, be, addr} != held_q[68:32] || (we && wdata != held_q[31:0]));
endmodule : ocv_obi_mem
