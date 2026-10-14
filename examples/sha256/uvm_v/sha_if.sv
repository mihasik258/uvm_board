// sha_if.sv - the pins of the SHA-256 core: blocks in (valid/ready), digests out (valid).
interface sha_if (input logic clk);
    logic         rst_n;
    logic         in_valid, in_ready;
    logic [511:0] in_block;
    logic         in_init;
    logic         out_valid;
    logic [255:0] out_digest;
endinterface
