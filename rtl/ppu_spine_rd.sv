// SPDX-License-Identifier: Apache-2.0
// Dual-clock wrapper around ppu_spine_rd_core.

module ppu_spine_rd #(
    parameter logic [6:0] MEM_BASE_HI = 7'h00
) (
    input  logic ppu_clk,
    input  logic spine_clk,
    input  logic rst_n,

    input  logic        burst_req,
    input  logic [31:0] burst_addr,
    input  logic [10:0] burst_len,
    output logic        burst_gnt,
    output logic        burst_valid,
    output logic [31:0] burst_data,

    output spine_b4_pkg::spine_rq_t b0_rq,
    output spine_b4_pkg::spine_rq_t b1_rq,
    output spine_b4_pkg::spine_rq_t b2_rq,
    output spine_b4_pkg::spine_rq_t b3_rq,
    input  logic [3:0]              b_rq_grant,
    input  spine_b4_pkg::spine_rs_t b0_rs,
    input  spine_b4_pkg::spine_rs_t b1_rs,
    input  spine_b4_pkg::spine_rs_t b2_rs,
    input  spine_b4_pkg::spine_rs_t b3_rs,

    output logic busy,
    output logic bus_error
);
    // Bundled-data toggle mailbox, PPU -> SPINE.  Payload is held until the
    // synchronized acknowledgement returns.
    logic [31:0] req_addr_hold;
    logic [10:0] req_len_hold;
    logic [3:0]  req_epoch_hold;
    logic [3:0]  active_epoch;
    logic        req_toggle;
    logic        req_busy;
    logic        ack_toggle;
    (* async_reg = "true" *) logic ack_ppu_1, ack_ppu_2;

    always_ff @(posedge ppu_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_addr_hold <= '0;
            req_len_hold <= '0;
            req_epoch_hold <= '0;
            active_epoch <= '0;
            req_toggle <= 1'b0;
            req_busy <= 1'b0;
            ack_ppu_1 <= 1'b0;
            ack_ppu_2 <= 1'b0;
            burst_gnt <= 1'b0;
        end else begin
            ack_ppu_1 <= ack_toggle;
            ack_ppu_2 <= ack_ppu_1;
            burst_gnt <= 1'b0;

            if (burst_req && !req_busy) begin
                req_addr_hold <= burst_addr;
                req_len_hold <= burst_len;
                req_epoch_hold <= active_epoch + 4'd1;
                active_epoch <= active_epoch + 4'd1;
                req_toggle <= ~req_toggle;
                req_busy <= 1'b1;
            end
            if (req_busy && (ack_ppu_2 == req_toggle)) begin
                req_busy <= 1'b0;
                burst_gnt <= 1'b1;
            end
        end
    end

    (* async_reg = "true" *) logic req_spine_1, req_spine_2;
    logic req_seen;
    logic core_cmd_valid;
    logic core_cmd_accept;
    always_ff @(posedge spine_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_spine_1 <= 1'b0;
            req_spine_2 <= 1'b0;
            req_seen <= 1'b0;
            ack_toggle <= 1'b0;
            core_cmd_valid <= 1'b0;
        end else begin
            req_spine_1 <= req_toggle;
            req_spine_2 <= req_spine_1;
            if (!core_cmd_valid && (req_spine_2 != req_seen))
                core_cmd_valid <= 1'b1;
            if (core_cmd_valid && core_cmd_accept) begin
                core_cmd_valid <= 1'b0;
                req_seen <= req_spine_2;
                ack_toggle <= req_spine_2;
            end
        end
    end

    logic core_out_valid;
    logic core_out_ready;
    logic [3:0] core_out_epoch;
    logic [31:0] core_out_data;
    logic core_busy;
    logic core_fault;

    ppu_spine_rd_core #(.MEM_BASE_HI(MEM_BASE_HI)) u_core (
        .clk(spine_clk), .rst_n(rst_n),
        .cmd_valid(core_cmd_valid), .cmd_addr(req_addr_hold),
        .cmd_len(req_len_hold), .cmd_epoch(req_epoch_hold),
        .cmd_accept(core_cmd_accept),
        .b0_rq(b0_rq), .b1_rq(b1_rq), .b2_rq(b2_rq), .b3_rq(b3_rq),
        .b_rq_grant(b_rq_grant),
        .b0_rs(b0_rs), .b1_rs(b1_rs), .b2_rs(b2_rs), .b3_rs(b3_rs),
        .out_valid(core_out_valid), .out_ready(core_out_ready),
        .out_epoch(core_out_epoch), .out_data(core_out_data),
        .busy(core_busy), .fault(core_fault)
    );

    logic fifo_full;
    logic fifo_empty;
    logic [35:0] fifo_rdata;
    assign core_out_ready = !fifo_full;

    async_fifo_gray #(.WIDTH(36), .ADDR_BITS(5)) u_return_fifo (
        .wr_clk(spine_clk), .wr_rst_n(rst_n),
        .wr_en(core_out_valid && core_out_ready),
        .wr_data({core_out_epoch, core_out_data}), .wr_full(fifo_full),
        .rd_clk(ppu_clk), .rd_rst_n(rst_n),
        .rd_en(!fifo_empty), .rd_data(fifo_rdata), .rd_empty(fifo_empty)
    );

    // Stale epochs are popped silently.  Current words are consumed on the
    // cycle burst_valid is asserted; ppu_fbscan never backpressures.
    assign burst_valid = !fifo_empty && (fifo_rdata[35:32] == active_epoch);
    assign burst_data = fifo_rdata[31:0];

    (* async_reg = "true" *) logic fault_ppu_1, fault_ppu_2;
    (* async_reg = "true" *) logic busy_ppu_1, busy_ppu_2;
    always_ff @(posedge ppu_clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_ppu_1 <= 1'b0;
            fault_ppu_2 <= 1'b0;
            busy_ppu_1 <= 1'b0;
            busy_ppu_2 <= 1'b0;
        end else begin
            fault_ppu_1 <= core_fault;
            fault_ppu_2 <= fault_ppu_1;
            busy_ppu_1 <= core_busy || req_busy;
            busy_ppu_2 <= busy_ppu_1;
        end
    end
    assign bus_error = fault_ppu_2;
    assign busy = busy_ppu_2;

endmodule
