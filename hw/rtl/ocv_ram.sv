/// OCV record buffer - simple dual-port RAM: one write port with per-byte enables, one
/// read port, one clock, one-cycle registered read. Plain inference (no vendor macro), so the
/// same source maps to block RAM with byte-write enables on 7-series, UltraScale+ and Versal (and,
/// with OCV_URAM_BITS, large buffers to UltraRAM).
module ocv_ram #(
    parameter int unsigned W  = 128,   // multiple of 8
    parameter int unsigned AW = 13
) (
    input  logic           clk,
    input  logic [W/8-1:0] we,
    input  logic [AW-1:0]  waddr,
    input  logic [W-1:0]   wdata,
    input  logic           re,
    input  logic [AW-1:0]  raddr,
    output logic [W-1:0]   rdata
);
    // OCV_URAM_BITS (a platform with UltraRAM, e.g. Versal): a buffer of at least that many bits is
    // put there - large record buffers would take most of the block RAM otherwise
`ifdef OCV_URAM_BITS
    localparam bit ULTRA = W * (64'd1 << AW) >= 64'(`OCV_URAM_BITS);
`else
    localparam bit ULTRA = 1'b0;
`endif
    if (ULTRA) begin : g_uram
        (* ram_style = "ultra" *) logic [W-1:0] mem [0:(1<<AW)-1];
        always_ff @(posedge clk)
            for (int i = 0; i < W/8; i++)
                if (we[i]) mem[waddr][8*i +: 8] <= wdata[8*i +: 8];
        always_ff @(posedge clk)
            if (re) rdata <= mem[raddr];
    end else begin : g_bram
        (* ram_style = "block" *) logic [W-1:0] mem [0:(1<<AW)-1];
        always_ff @(posedge clk) begin
            for (int i = 0; i < W/8; i++)
                if (we[i]) mem[waddr][8*i +: 8] <= wdata[8*i +: 8];
            if (re) rdata <= mem[raddr];
        end
    end

endmodule : ocv_ram
