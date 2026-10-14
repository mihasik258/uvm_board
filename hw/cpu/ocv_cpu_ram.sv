/// ocv_cpu_ram - the RAM of a processor core under OCV (gen/cpu_wrap.py): 2**AW 32-bit words, two
/// ports (A, B) for the core's bus adapters, one-clock registered read, byte write enables.
///
/// While `load` is high port A belongs to the program loader (the OCV source channel `program`): one
/// word per accepted record.
module ocv_cpu_ram #(
    parameter int unsigned AW   = 14,
    parameter bit          URAM = 1'b0      // UltraRAM (large memories) instead of block RAM
) (
    input  logic          clk,
    // loader (while load)
    input  logic          load,
    input  logic          ld_valid,
    input  logic [AW-1:0] ld_addr,
    input  logic [31:0]   ld_data,
    // port A
    input  logic          a_en,
    input  logic [3:0]    a_we,
    input  logic [AW-1:0] a_addr,
    input  logic [31:0]   a_wdata,
    output logic [31:0]   a_rdata,
    // port B
    input  logic          b_en,
    input  logic [3:0]    b_we,
    input  logic [AW-1:0] b_addr,
    input  logic [31:0]   b_wdata,
    output logic [31:0]   b_rdata
);
    logic          pa_en;
    logic [3:0]    pa_we;
    logic [AW-1:0] pa_addr;
    logic [31:0]   pa_wdata;
    assign pa_en    = load ? ld_valid : a_en;
    assign pa_we    = load ? {4{ld_valid}} : a_we;
    assign pa_addr  = load ? ld_addr : a_addr;
    assign pa_wdata = load ? ld_data : a_wdata;

    if (URAM) begin : g_uram
        // UltraRAM takes only the "no change" write mode (UG901): a write does not read - the bus
        // adapters do not use the data of a write
        (* ram_style = "ultra" *) logic [31:0] ram [0:(1<<AW)-1];
        always_ff @(posedge clk) if (pa_en) begin
            for (int i = 0; i < 4; i++) if (pa_we[i]) ram[pa_addr][8*i +: 8] <= pa_wdata[8*i +: 8];
            if (pa_we == 4'b0) a_rdata <= ram[pa_addr];
        end
        always_ff @(posedge clk) if (b_en) begin
            for (int i = 0; i < 4; i++) if (b_we[i]) ram[b_addr][8*i +: 8] <= b_wdata[8*i +: 8];
            if (b_we == 4'b0) b_rdata <= ram[b_addr];
        end
    end else begin : g_bram
        (* ram_style = "block" *) logic [31:0] ram [0:(1<<AW)-1];
        always_ff @(posedge clk) if (pa_en) begin
            for (int i = 0; i < 4; i++) if (pa_we[i]) ram[pa_addr][8*i +: 8] <= pa_wdata[8*i +: 8];
            a_rdata <= ram[pa_addr];
        end
        always_ff @(posedge clk) if (b_en) begin
            for (int i = 0; i < 4; i++) if (b_we[i]) ram[b_addr][8*i +: 8] <= b_wdata[8*i +: 8];
            b_rdata <= ram[b_addr];
        end
    end
endmodule : ocv_cpu_ram
