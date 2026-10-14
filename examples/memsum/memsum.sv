/// memsum - demo IP for reactive verification: a small bus master.
///
/// Takes a command (addr, len), reads len words from memory one request at a time - addr, addr+4,
/// ... - and returns a checksum of them. Memory is outside the IP: each read is a request
/// (m_req_*) and the data comes back as a response (s_rsp_*). In verification the responses come
/// from the reference model on the PS, computed from each request as it appears.
///
/// The result also reports how many of its own clock cycles the IP spent waiting for responses
/// (r_wait): whatever the memory latency, it is at least one per word; it is exactly one per word
/// when the answer is there as soon as it is asked for.
///
/// Checksum: sum = rotl(sum, 1) + data, so the order of the words matters.
module memsum (
    input  logic        clk,
    input  logic        rst_n,
    // command
    input  logic        s_cmd_valid,
    output logic        s_cmd_ready,
    input  logic [31:0] s_cmd_addr,
    input  logic [15:0] s_cmd_len,
    // memory read request
    output logic        m_req_valid,
    input  logic        m_req_ready,
    output logic [31:0] m_req_addr,
    // memory read response
    input  logic        s_rsp_valid,
    output logic        s_rsp_ready,
    input  logic [31:0] s_rsp_data,
    // result
    output logic        m_res_valid,
    input  logic        m_res_ready,
    output logic [31:0] m_res_sum,
    output logic [31:0] m_res_addr,
    output logic [15:0] m_res_len,
    output logic [31:0] m_res_wait
);
    typedef enum logic [1:0] {IDLE, REQ, WAIT, RES} st_e;
    st_e         st_q;
    logic [31:0] addr_q, sum_q, wait_q;
    logic [15:0] len_q, i_q;

    assign s_cmd_ready = (st_q == IDLE);
    assign m_req_valid = (st_q == REQ);
    assign m_req_addr  = addr_q + {14'b0, i_q, 2'b00};
    assign s_rsp_ready = (st_q == WAIT);
    assign m_res_valid = (st_q == RES);
    assign m_res_sum   = sum_q;
    assign m_res_addr  = addr_q;
    assign m_res_len   = len_q;
    assign m_res_wait  = wait_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            st_q <= IDLE;
            addr_q <= '0; sum_q <= '0; wait_q <= '0; len_q <= '0; i_q <= '0;
        end else begin
            unique case (st_q)
                IDLE: if (s_cmd_valid) begin
                          addr_q <= s_cmd_addr;
                          len_q  <= s_cmd_len;
                          i_q    <= '0;
                          sum_q  <= '0;
                          wait_q <= 32'd0;
                          st_q   <= (s_cmd_len == 0) ? RES : REQ;
                      end
                REQ:  if (m_req_ready) st_q <= WAIT;
                WAIT: begin
                          wait_q <= wait_q + 1'b1;
                          if (s_rsp_valid) begin
                              sum_q <= {sum_q[30:0], sum_q[31]} + s_rsp_data;
                              i_q   <= i_q + 1'b1;
                              st_q  <= (i_q + 1'b1 == len_q) ? RES : REQ;
                          end
                      end
                RES:  if (m_res_ready) st_q <= IDLE;
                default: st_q <= IDLE;
            endcase
        end
    end
endmodule : memsum
