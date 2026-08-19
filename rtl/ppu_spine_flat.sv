// SPDX-License-Identifier: Apache-2.0
// Dual-clock wrapper for the blocking 16-bit PPU render/keyhole port.

module ppu_spine_flat #(
    parameter logic [31:0] RENDER_BASE = 32'h0000_0000,
    parameter logic [6:0]  MEM_BASE_HI = RENDER_BASE[31:25]
) (
    input  logic ppu_clk,
    input  logic spine_clk,
    input  logic rst_n,

    input  logic        mem_req,
    input  logic        mem_we,
    input  logic [18:0] mem_addr,
    input  logic [15:0] mem_wdata,
    output logic        mem_ack,
    output logic [15:0] mem_rdata,

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

    output logic busy,
    output logic bus_error
);
    // One request is enough: ppu_top's flat port is blocking.  Bundled data
    // remains stable until the response toggle returns.
    logic        req_we_hold;
    logic [18:0] req_addr_hold;
    logic [15:0] req_wdata_hold;
    logic [11:0] req_ctx_hold;
    logic [11:0] req_sequence;
    logic        req_toggle;
    logic        ppu_pending;

    logic        rsp_toggle;
    logic [15:0] rsp_data_hold;
    logic        rsp_error_hold;
    (* async_reg = "true" *) logic rsp_ppu_1, rsp_ppu_2;
    logic rsp_seen;

    always_ff @(posedge ppu_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_we_hold <= 1'b0;
            req_addr_hold <= '0;
            req_wdata_hold <= '0;
            req_ctx_hold <= '0;
            req_sequence <= '0;
            req_toggle <= 1'b0;
            ppu_pending <= 1'b0;
            rsp_ppu_1 <= 1'b0;
            rsp_ppu_2 <= 1'b0;
            rsp_seen <= 1'b0;
            mem_ack <= 1'b0;
            mem_rdata <= '0;
        end else begin
            rsp_ppu_1 <= rsp_toggle;
            rsp_ppu_2 <= rsp_ppu_1;
            mem_ack <= 1'b0;

            if (mem_req && !ppu_pending) begin
                req_we_hold <= mem_we;
                req_addr_hold <= mem_addr;
                req_wdata_hold <= mem_wdata;
                req_ctx_hold <= req_sequence;
                req_sequence <= req_sequence + 12'd1;
                req_toggle <= ~req_toggle;
                ppu_pending <= 1'b1;
            end

            if (rsp_ppu_2 != rsp_seen) begin
                rsp_seen <= rsp_ppu_2;
                mem_rdata <= rsp_data_hold;
                mem_ack <= 1'b1;
                ppu_pending <= 1'b0;
            end
        end
    end

    (* async_reg = "true" *) logic req_spine_1, req_spine_2;
    logic req_seen;
    logic core_cmd_valid;
    logic core_cmd_ready;
    logic core_result_valid;
    logic [15:0] core_result_data;
    logic core_result_error;
    logic core_fault;

    always_ff @(posedge spine_clk or negedge rst_n) begin
        if (!rst_n) begin
            req_spine_1 <= 1'b0;
            req_spine_2 <= 1'b0;
            req_seen <= 1'b0;
            core_cmd_valid <= 1'b0;
            rsp_toggle <= 1'b0;
            rsp_data_hold <= '0;
            rsp_error_hold <= 1'b0;
        end else begin
            req_spine_1 <= req_toggle;
            req_spine_2 <= req_spine_1;

            if (!core_cmd_valid && (req_spine_2 != req_seen))
                core_cmd_valid <= 1'b1;
            if (core_cmd_valid && core_cmd_ready) begin
                core_cmd_valid <= 1'b0;
                req_seen <= req_spine_2;
            end

            if (core_result_valid) begin
                rsp_data_hold <= core_result_data;
                rsp_error_hold <= core_result_error;
                rsp_toggle <= ~rsp_toggle;
            end
        end
    end

    ppu_spine_flat_core #(.MEM_BASE_HI(MEM_BASE_HI)) u_core (
        .clk(spine_clk), .rst_n(rst_n),
        .cmd_valid(core_cmd_valid), .cmd_ready(core_cmd_ready),
        .cmd_we(req_we_hold),
        .cmd_addr(RENDER_BASE + {13'd0, req_addr_hold}),
        .cmd_wdata(req_wdata_hold), .cmd_ctx(req_ctx_hold),
        .result_valid(core_result_valid), .result_data(core_result_data),
        .result_error(core_result_error),
        .b0_rq(b0_rq), .b1_rq(b1_rq), .b2_rq(b2_rq), .b3_rq(b3_rq),
        .b0_wd(b0_wd), .b1_wd(b1_wd), .b2_wd(b2_wd), .b3_wd(b3_wd),
        .b_rq_grant(b_rq_grant),
        .b0_rs(b0_rs), .b1_rs(b1_rs), .b2_rs(b2_rs), .b3_rs(b3_rs),
        .fault(core_fault)
    );

    (* async_reg = "true" *) logic fault_ppu_1, fault_ppu_2;
    always_ff @(posedge ppu_clk or negedge rst_n) begin
        if (!rst_n) begin
            fault_ppu_1 <= 1'b0;
            fault_ppu_2 <= 1'b0;
        end else begin
            fault_ppu_1 <= core_fault || rsp_error_hold;
            fault_ppu_2 <= fault_ppu_1;
        end
    end

    assign busy = ppu_pending;
    assign bus_error = fault_ppu_2;

endmodule
