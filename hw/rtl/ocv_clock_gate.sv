/// OCV DUT clock gate - freezes the DUT while a lossless monitor's buffer is full.
///
/// gclk = clk while en, held low otherwise; en is sampled while clk is low so gclk never
/// glitches. The DUT and the OCV endpoints stay synchronous: gclk edges are a subset of clk
/// edges, and every endpoint counts a transfer only in cycles where the DUT clock ticks (en).
/// With OCV_USE_BUFGCE the Xilinx global clock buffer with enable is used instead of the
/// behavioural latch-and-gate (the platform layer decides). On UltraScale and Versal the
/// platform also names the family for the primitive's SIM_DEVICE (Versal DRC requires it):
/// OCV_BUFGCE_SIM_DEVICE=VERSAL_AI_EDGE, ULTRASCALE_PLUS, ...; 7-series leaves it undefined.
`define OCV_STR(x) `"x`"
module ocv_clock_gate (
    input  logic clk,
    input  logic en,
    output logic gclk
);
`ifdef OCV_USE_BUFGCE
`ifdef OCV_BUFGCE_SIM_DEVICE
    BUFGCE #(.SIM_DEVICE(`OCV_STR(`OCV_BUFGCE_SIM_DEVICE))) i_bufgce (.I(clk), .CE(en), .O(gclk));
`else
    BUFGCE i_bufgce (.I(clk), .CE(en), .O(gclk));
`endif
`else
    logic en_l;
    always_latch if (!clk) en_l = en;
    assign gclk = clk & en_l;
`endif
endmodule : ocv_clock_gate
