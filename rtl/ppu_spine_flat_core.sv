// SPDX-License-Identifier: Apache-2.0
// Blocking 16-bit PPU render/keyhole port -> native SPINE-B4.

module ppu_spine_flat_core #(
    parameter logic [6:0] MEM_BASE_HI = 7'h00
) (
    input  logic clk,
    input  logic rst_n,
    input  logic        cmd_valid,
    output logic        cmd_ready,
    input  logic        cmd_we,
    input  logic [31:0] cmd_addr,
    input  logic [15:0] cmd_wdata,
    input  logic [11:0] cmd_ctx,
    output logic        result_valid,
    output logic [15:0] result_data,
    output logic        result_error,

    output spine_b4_pkg::spine_rq_t b0_rq,
    output spine_b4_pkg::spine_rq_t b1_rq,
    output spine_b4_pkg::spine_rq_t b2_rq,
    output spine_b4_pkg::spine_rq_t b3_rq,
    output spine_b4_pkg::spine_wd_t b0_wd,
    output spine_b4_pkg::spine_wd_t b1_wd,
    output spine_b4_pkg::spine_wd_t b2_wd,
    output spine_b4_pkg::spine_wd_t b3_wd,
    input  logic [3:0]              b_rq_grant,
    input  spine_b4_pkg::spine_rs_t b0_rs,
    input  spine_b4_pkg::spine_rs_t b1_rs,
    input  spine_b4_pkg::spine_rs_t b2_rs,
    input  spine_b4_pkg::spine_rs_t b3_rs,
    output logic fault
);
    import spine_b4_pkg::*;

    typedef enum logic [2:0] {S_IDLE, S_POST_R, S_READ, S_POST_W, S_WRITE} state_t;
    state_t state;
    logic [31:0] active_addr;
    logic [15:0] active_wdata;
    logic [11:0] active_ctx;
    logic [1:0] active_bid;
    logic [2:0] rx_count;
    logic [1:0] critical_word;
    logic       critical_half;
    logic       result_sent;

    logic [1:0] line_valid;
    logic [20:0] line_tag [0:1];
    logic [31:0] line_data [0:1][0:3];
    logic replace_way;
    logic fill_way;

    wire hit0 = line_valid[0] && line_tag[0] == cmd_addr[24:4];
    wire hit1 = line_valid[1] && line_tag[1] == cmd_addr[24:4];
    wire [31:0] hit_word = hit0 ? line_data[0][cmd_addr[3:2]]
                                 : line_data[1][cmd_addr[3:2]];
    wire [15:0] hit_half = cmd_addr[1] ? hit_word[31:16] : hit_word[15:0];
    assign cmd_ready = (state == S_IDLE);

    function automatic spine_rq_t make_rq(
        input logic valid,
        input logic write,
        input logic [31:0] addr,
        input logic [11:0] ctx
    );
        spine_rq_t r;
        logic [31:0] a;
        begin
            r = '0;
            a = write ? {addr[31:2], 2'b00} : {addr[31:4], 4'b0000};
            if (valid) begin
                r.valid = 1'b1;
                r.p.src = SPINE_SRC_PPU_RENDER;
                r.p.tid = 3'd0;
                r.p.ctx = ctx;
                if (write)
                    r.p.cmd = SPINE_CMD_WRITE;
                else
                    r.p.cmd = SPINE_CMD_READ;
                r.p.role = SPINE_ROLE_NC;
                r.p.line = a[24:6];
                r.p.off = a[3:0];
                r.p.space = SPINE_SPACE_PSRAM;
                r.p.beats_m1 = write ? 2'd0 : 2'd3;
                r.p.size = 2'd2;
                r.p.memtype = SPINE_MEM_NORMAL_NC;
                r.p.qos = SPINE_QOS_LAT;
                r.p.posted = 1'b0;
                r.p.par = rq_even_parity(r.p);
            end
            make_rq = r;
        end
    endfunction

    function automatic spine_wd_t make_wd(
        input logic valid,
        input logic [31:0] addr,
        input logic [15:0] wdata
    );
        spine_wd_t w;
        begin
            w = '0;
            if (valid) begin
                w.valid = 1'b1;
                w.p.data = addr[1] ? {wdata, 16'd0} : {16'd0, wdata};
                w.p.strb = addr[1] ? 4'b1100 : 4'b0011;
                w.p.last = 1'b1;
                w.p.par = wd_even_parity(w.p);
            end
            make_wd = w;
        end
    endfunction

    wire post_read = state == S_POST_R;
    wire post_write = state == S_POST_W;
    assign b0_rq = make_rq((post_read || post_write) && active_bid == 2'd0,
                           post_write, active_addr, active_ctx);
    assign b1_rq = make_rq((post_read || post_write) && active_bid == 2'd1,
                           post_write, active_addr, active_ctx);
    assign b2_rq = make_rq((post_read || post_write) && active_bid == 2'd2,
                           post_write, active_addr, active_ctx);
    assign b3_rq = make_rq((post_read || post_write) && active_bid == 2'd3,
                           post_write, active_addr, active_ctx);
    assign b0_wd = make_wd(post_write && active_bid == 2'd0,
                           active_addr, active_wdata);
    assign b1_wd = make_wd(post_write && active_bid == 2'd1,
                           active_addr, active_wdata);
    assign b2_wd = make_wd(post_write && active_bid == 2'd2,
                           active_addr, active_wdata);
    assign b3_wd = make_wd(post_write && active_bid == 2'd3,
                           active_addr, active_wdata);

    task automatic process_response(input spine_rs_t rs);
        logic parity_bad;
        begin
            parity_bad = rs_even_parity(rs.p) != rs.p.par;
            if (rs.valid && (rs.p.src == SPINE_SRC_PPU_RENDER)) begin
                if ((rs.p.tid != 3'd0) || (rs.p.ctx != active_ctx) || parity_bad
                        || (rs.p.status != SPINE_ST_OK)) begin
                    fault <= 1'b1;
                    if (!result_sent) begin
                        result_valid <= 1'b1;
                        result_error <= 1'b1;
                        result_sent <= 1'b1;
                    end
                    state <= S_IDLE;
                    line_valid[fill_way] <= 1'b0;
                end else if (state == S_READ) begin
                    if ((rs.p.kind != SPINE_RS_DATA) || (rx_count >= 3'd4)) begin
                        fault <= 1'b1;
                        result_valid <= !result_sent;
                        result_error <= !result_sent;
                        result_sent <= 1'b1;
                        state <= S_IDLE;
                        line_valid[fill_way] <= 1'b0;
                    end else begin
                        line_data[fill_way][rx_count[1:0]] <= rs.p.data;
                        if (!result_sent && (rx_count[1:0] == critical_word)) begin
                            result_valid <= 1'b1;
                            result_data <= critical_half ? rs.p.data[31:16]
                                                         : rs.p.data[15:0];
                            result_error <= 1'b0;
                            result_sent <= 1'b1;
                        end
                        rx_count <= rx_count + 3'd1;
                        if (rs.p.last != (rx_count == 3'd3)) begin
                            fault <= 1'b1;
                            line_valid[fill_way] <= 1'b0;
                            state <= S_IDLE;
                        end else if (rs.p.last) begin
                            line_valid[fill_way] <= 1'b1;
                            line_tag[fill_way] <= active_addr[24:4];
                            replace_way <= ~fill_way;
                            state <= S_IDLE;
                        end
                    end
                end else if (state == S_WRITE) begin
                    if ((rs.p.kind != SPINE_RS_ACK) || !rs.p.last) begin
                        fault <= 1'b1;
                        result_error <= 1'b1;
                    end else begin
                        result_error <= 1'b0;
                    end
                    result_valid <= 1'b1;
                    result_sent <= 1'b1;
                    state <= S_IDLE;
                end
            end
        end
    endtask

    integer i;
    integer j;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            active_addr <= '0;
            active_wdata <= '0;
            active_ctx <= '0;
            active_bid <= '0;
            rx_count <= '0;
            critical_word <= '0;
            critical_half <= 1'b0;
            result_sent <= 1'b0;
            line_valid <= '0;
            replace_way <= 1'b0;
            fill_way <= 1'b0;
            result_valid <= 1'b0;
            result_data <= '0;
            result_error <= 1'b0;
            fault <= 1'b0;
            for (i = 0; i < 2; i = i + 1) begin
                line_tag[i] <= '0;
                for (j = 0; j < 4; j = j + 1)
                    line_data[i][j] <= '0;
            end
        end else begin
            result_valid <= 1'b0;
            process_response(b0_rs);
            process_response(b1_rs);
            process_response(b2_rs);
            process_response(b3_rs);

            case (state)
                S_IDLE: if (cmd_valid) begin
                    result_sent <= 1'b0;
                    result_error <= 1'b0;
                    active_addr <= cmd_addr;
                    active_wdata <= cmd_wdata;
                    active_ctx <= cmd_ctx;
                    active_bid <= cmd_addr[5:4];
                    critical_word <= cmd_addr[3:2];
                    critical_half <= cmd_addr[1];
                    if ((cmd_addr[31:25] != MEM_BASE_HI) || cmd_addr[0]) begin
                        result_valid <= 1'b1;
                        result_error <= 1'b1;
                        fault <= 1'b1;
                    end else if (!cmd_we && (hit0 || hit1)) begin
                        result_valid <= 1'b1;
                        result_data <= hit_half;
                    end else if (cmd_we) begin
                        if (line_valid[0] && line_tag[0] == cmd_addr[24:4])
                            line_valid[0] <= 1'b0;
                        if (line_valid[1] && line_tag[1] == cmd_addr[24:4])
                            line_valid[1] <= 1'b0;
                        state <= S_POST_W;
                    end else begin
                        fill_way <= replace_way;
                        line_valid[replace_way] <= 1'b0;
                        rx_count <= 3'd0;
                        state <= S_POST_R;
                    end
                end
                S_POST_R: if (b_rq_grant[active_bid]) state <= S_READ;
                S_POST_W: if (b_rq_grant[active_bid]) state <= S_WRITE;
                default: ;
            endcase
        end
    end

endmodule
