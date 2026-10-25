// otbn_if.sv - the pins of the OTBN+KMAC DUT (examples/otbn/otbn_kmac_ocv.sv): its bus, one valid/ready request and
// one response per access.
interface otbn_if (input logic clk);
    logic rst_n;
    // bus (source): an access, or a wait for OTBN to be idle
    logic req_valid, req_ready;
    logic req_we, req_wait;
    logic [31:0] req_addr;
    logic [31:0] req_wdata;
    logic [3:0] req_be;
    // rsp (monitor): the access's response
    logic rsp_valid;
    logic [31:0] rsp_rdata;
    logic rsp_err;
endinterface
