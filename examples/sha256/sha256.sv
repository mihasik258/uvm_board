// sha256.sv - SHA-256 compression core (FIPS 180-4), one round per clock: a 512-bit block in
// (valid/ready), its chained digest out (valid) 64 clocks later. 'init' starts a new message (the
// chaining value is the standard IV), otherwise the block continues the previous message.
module sha256 (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         in_valid,
    output logic         in_ready,
    input  logic [511:0] in_block,      // W0 = in_block[511:480] (big-endian words)
    input  logic         in_init,
    output logic         out_valid,
    output logic [255:0] out_digest     // H0 = out_digest[255:224]
);
    localparam logic [31:0] K [64] = '{
        32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5, 32'h3956c25b, 32'h59f111f1, 32'h923f82a4, 32'hab1c5ed5,
        32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3, 32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174,
        32'he49b69c1, 32'hefbe4786, 32'h0fc19dc6, 32'h240ca1cc, 32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
        32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7, 32'hc6e00bf3, 32'hd5a79147, 32'h06ca6351, 32'h14292967,
        32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13, 32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85,
        32'ha2bfe8a1, 32'ha81a664b, 32'hc24b8b70, 32'hc76c51a3, 32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
        32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5, 32'h391c0cb3, 32'h4ed8aa4a, 32'h5b9cca4f, 32'h682e6ff3,
        32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208, 32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2};
    localparam logic [255:0] IV = {32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
                                   32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

    function automatic logic [31:0] rotr(input logic [31:0] x, input int n); return (x >> n) | (x << (32 - n)); endfunction

    logic [31:0] H [8], a, b, c, d, e, f, g, h, W [16];
    logic [5:0]  t;
    logic        busy;

    assign in_ready = ~busy;

    logic [31:0] s0, s1, S0, S1, ch, maj, t1, t2, wn;
    always_comb begin
        S1  = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        ch  = (e & f) ^ (~e & g);
        t1  = h + S1 + ch + K[t] + W[0];
        S0  = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        maj = (a & b) ^ (a & c) ^ (b & c);
        t2  = S0 + maj;
        s0  = rotr(W[1], 7) ^ rotr(W[1], 18) ^ (W[1] >> 3);
        s1  = rotr(W[14], 17) ^ rotr(W[14], 19) ^ (W[14] >> 10);
        wn  = s1 + W[9] + s0 + W[0];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy      <= 1'b0;
            out_valid <= 1'b0;
            for (int i = 0; i < 8; i++) H[i] <= IV[255 - 32*i -: 32];
        end else begin
            out_valid <= 1'b0;
            if (!busy) begin
                if (in_valid) begin
                    logic [31:0] base [8];
                    for (int i = 0; i < 8; i++) base[i] = in_init ? IV[255 - 32*i -: 32] : H[i];
                    for (int i = 0; i < 8; i++) H[i] <= base[i];
                    {a, b, c, d, e, f, g, h} <= {base[0], base[1], base[2], base[3], base[4], base[5], base[6], base[7]};
                    for (int i = 0; i < 16; i++) W[i] <= in_block[511 - 32*i -: 32];
                    t    <= '0;
                    busy <= 1'b1;
                end
            end else begin
                {a, b, c, d, e, f, g, h} <= {t1 + t2, a, b, c, d + t1, e, f, g};
                for (int i = 0; i < 15; i++) W[i] <= W[i + 1];
                W[15] <= wn;
                t <= t + 6'd1;
                if (t == 6'd63) begin
                    logic [31:0] n [8];
                    n[0] = H[0] + t1 + t2; n[1] = H[1] + a; n[2] = H[2] + b; n[3] = H[3] + c;
                    n[4] = H[4] + d + t1;  n[5] = H[5] + e; n[6] = H[6] + f; n[7] = H[7] + g;
                    for (int i = 0; i < 8; i++) H[i] <= n[i];
                    out_digest <= {n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7]};
                    out_valid  <= 1'b1;
                    busy       <= 1'b0;
                end
            end
        end
    end
endmodule
