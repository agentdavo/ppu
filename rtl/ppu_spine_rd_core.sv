// SPDX-License-Identifier: Apache-2.0
// Native whole-line PPU reads -> four SPINE-B4 request ports.
// Runs entirely in the 50 MHz SPINE domain.  Clock crossing is in
// ppu_spine_rd.sv.

module ppu_spine_rd_core #(
    parameter logic [6:0] MEM_BASE_HI = 7'h00
) (
    input  logic clk,
    input  logic rst_n,

    input  logic        cmd_valid,
    input  logic [31:0] cmd_addr,
    input  logic [10:0] cmd_len,
    input  logic [3:0]  cmd_epoch,
    output logic        cmd_accept,

    output spine_b4_pkg::spine_rq_t b0_rq,
    output spine_b4_pkg::spine_rq_t b1_rq,
    output spine_b4_pkg::spine_rq_t b2_rq,
    output spine_b4_pkg::spine_rq_t b3_rq,
    input  logic [3:0]              b_rq_grant,
    input  spine_b4_pkg::spine_rs_t b0_rs,
    input  spine_b4_pkg::spine_rs_t b1_rs,
    input  spine_b4_pkg::spine_rs_t b2_rs,
    input  spine_b4_pkg::spine_rs_t b3_rs,

    output logic        out_valid,
    input  logic        out_ready,
    output logic [3:0]  out_epoch,
    output logic [31:0] out_data,

    output logic        busy,
    output logic        fault
);
    import spine_b4_pkg::*;

    logic [31:0] issue_addr;
    logic [10:0] issue_left;
    logic [7:0]  issue_seq;
    logic [7:0]  retire_seq;
    logic [3:0]  current_epoch;

    logic [7:0] slot_valid;
    logic [7:0] slot_live;
    logic [7:0] slot_complete;
    logic [7:0] slot_error;
    logic [3:0] slot_epoch [0:7];
    logic [7:0] slot_seq [0:7];
    logic [31:0] slot_addr [0:7];
    logic [2:0] slot_beats [0:7];
    logic [2:0] slot_rx [0:7];
    logic [31:0] slot_data [0:7][0:3];

    logic [3:0] post_valid;
    logic [2:0] post_tid [0:3];

    logic       drain_active;
    logic [2:0] drain_tid;
    logic [2:0] drain_beat;

    logic       free_found;
    logic [2:0] free_tid;
    integer fi;
    always_comb begin
        free_found = 1'b0;
        free_tid = 3'd0;
        for (fi = 0; fi < 8; fi = fi + 1) begin
            if (!free_found && !slot_valid[fi]) begin
                free_found = 1'b1;
                free_tid = fi[2:0];
            end
        end
    end

    wire [2:0] words_to_boundary = 3'd4 - {1'b0, issue_addr[3:2]};
    wire [2:0] next_beats = (issue_left < words_to_boundary)
                          ? issue_left[2:0] : words_to_boundary;
    wire [1:0] issue_bid = issue_addr[5:4];

    logic retire_found;
    logic [2:0] retire_tid;
    integer ri;
    always_comb begin
        retire_found = 1'b0;
        retire_tid = 3'd0;
        for (ri = 0; ri < 8; ri = ri + 1) begin
            if (!retire_found && slot_valid[ri] && slot_complete[ri]
                    && (slot_epoch[ri] == current_epoch)
                    && (slot_seq[ri] == retire_seq)) begin
                retire_found = 1'b1;
                retire_tid = ri[2:0];
            end
        end
    end

    function automatic spine_rq_t make_rq(
        input logic valid,
        input logic [2:0] tid,
        input logic [31:0] addr,
        input logic [2:0] beats,
        input logic [11:0] ctx
    );
        spine_rq_t r;
        begin
            r = '0;
            if (valid) begin
                r.valid      = 1'b1;
                r.p.src      = SPINE_SRC_PPU_SCAN;
                r.p.tid      = tid;
                r.p.ctx      = ctx;
                r.p.cmd      = SPINE_CMD_READ;
                r.p.role     = SPINE_ROLE_SCAN;
                r.p.line     = addr[24:6];
                r.p.off      = addr[3:0];
                r.p.space    = SPINE_SPACE_PSRAM;
                r.p.beats_m1 = beats[1:0] - 2'd1;
                r.p.size     = 2'd2;
                r.p.memtype  = SPINE_MEM_NORMAL_NC;
                r.p.qos      = SPINE_QOS_ISO;
                r.p.posted   = 1'b0;
                r.p.par      = rq_even_parity(r.p);
            end
            make_rq = r;
        end
    endfunction

    assign b0_rq = make_rq(post_valid[0], post_tid[0],
                            slot_addr[post_tid[0]], slot_beats[post_tid[0]],
                            {slot_epoch[post_tid[0]], slot_seq[post_tid[0]]});
    assign b1_rq = make_rq(post_valid[1], post_tid[1],
                            slot_addr[post_tid[1]], slot_beats[post_tid[1]],
                            {slot_epoch[post_tid[1]], slot_seq[post_tid[1]]});
    assign b2_rq = make_rq(post_valid[2], post_tid[2],
                            slot_addr[post_tid[2]], slot_beats[post_tid[2]],
                            {slot_epoch[post_tid[2]], slot_seq[post_tid[2]]});
    assign b3_rq = make_rq(post_valid[3], post_tid[3],
                            slot_addr[post_tid[3]], slot_beats[post_tid[3]],
                            {slot_epoch[post_tid[3]], slot_seq[post_tid[3]]});

    assign out_valid = drain_active;
    assign out_epoch = slot_epoch[drain_tid];
    assign out_data = slot_data[drain_tid][drain_beat[1:0]];
    assign busy = (issue_left != 0) || (slot_valid != 0) ||
                  (post_valid != 0) || drain_active;
    // A new line command is always accepted and deliberately supersedes an
    // older epoch.  Combinational accept makes the toggle-mailbox handshake
    // one edge wide; a registered echo would cause the held valid to apply a
    // command twice.
    assign cmd_accept = cmd_valid;

    integer i;
    integer j;
    task automatic process_response(input spine_rs_t rs);
        logic [2:0] t;
        begin
            if (rs.valid && (rs.p.src == SPINE_SRC_PPU_SCAN)) begin
                t = rs.p.tid;
                if (!slot_valid[t] || !slot_live[t]
                        || (rs.p.ctx != {slot_epoch[t], slot_seq[t]})
                        || (rs_even_parity(rs.p) != rs.p.par)) begin
                    fault <= 1'b1;
                end else if (rs.p.status != SPINE_ST_OK) begin
                    slot_error[t] <= 1'b1;
                    slot_complete[t] <= 1'b1;
                    fault <= 1'b1;
                end else if (rs.p.kind != SPINE_RS_DATA
                        || slot_rx[t] >= slot_beats[t]) begin
                    slot_error[t] <= 1'b1;
                    slot_complete[t] <= 1'b1;
                    fault <= 1'b1;
                end else begin
                    slot_data[t][slot_rx[t][1:0]] <= rs.p.data;
                    slot_rx[t] <= slot_rx[t] + 3'd1;
                    if (rs.p.last != (slot_rx[t] + 3'd1 == slot_beats[t])) begin
                        slot_error[t] <= 1'b1;
                        slot_complete[t] <= 1'b1;
                        fault <= 1'b1;
                    end else if (rs.p.last) begin
                        slot_complete[t] <= 1'b1;
                    end
                end
            end
        end
    endtask

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_addr <= '0;
            issue_left <= '0;
            issue_seq <= '0;
            retire_seq <= '0;
            current_epoch <= '0;
            slot_valid <= '0;
            slot_live <= '0;
            slot_complete <= '0;
            slot_error <= '0;
            post_valid <= '0;
            drain_active <= 1'b0;
            drain_tid <= '0;
            drain_beat <= '0;
            fault <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                slot_epoch[i] <= '0;
                slot_seq[i] <= '0;
                slot_addr[i] <= '0;
                slot_beats[i] <= '0;
                slot_rx[i] <= '0;
                for (j = 0; j < 4; j = j + 1)
                    slot_data[i][j] <= '0;
            end
            for (i = 0; i < 4; i = i + 1)
                post_tid[i] <= '0;
        end else begin
            // Responses land directly in their TID record.  Different B buses
            // may write different records in the same cycle.
            process_response(b0_rs);
            process_response(b1_rs);
            process_response(b2_rs);
            process_response(b3_rs);

            // Retire one completed packet in line order.  Error packets
            // consume sequence state but deliberately emit no pixel data.
            if (!drain_active && retire_found) begin
                if (slot_error[retire_tid]) begin
                    slot_valid[retire_tid] <= 1'b0;
                    slot_live[retire_tid] <= 1'b0;
                    slot_complete[retire_tid] <= 1'b0;
                    retire_seq <= retire_seq + 8'd1;
                end else begin
                    drain_active <= 1'b1;
                    drain_tid <= retire_tid;
                    drain_beat <= 3'd0;
                end
            end else if (drain_active && out_ready) begin
                if (drain_beat + 3'd1 == slot_beats[drain_tid]) begin
                    slot_valid[drain_tid] <= 1'b0;
                    slot_live[drain_tid] <= 1'b0;
                    slot_complete[drain_tid] <= 1'b0;
                    drain_active <= 1'b0;
                    retire_seq <= retire_seq + 8'd1;
                end else begin
                    drain_beat <= drain_beat + 3'd1;
                end
            end

            // Completed packets from superseded epochs are discarded as soon
            // as their terminal response arrives.
            for (i = 0; i < 8; i = i + 1) begin
                if (slot_valid[i] && slot_complete[i]
                        && (slot_epoch[i] != current_epoch)
                        && !(drain_active && drain_tid == i[2:0])) begin
                    slot_valid[i] <= 1'b0;
                    slot_live[i] <= 1'b0;
                    slot_complete[i] <= 1'b0;
                end
            end

            // Registered grants finish posting.  The descriptor remains in
            // its TID record until a terminal response retires it.
            for (i = 0; i < 4; i = i + 1) begin
                if (post_valid[i] && b_rq_grant[i]) begin
                    post_valid[i] <= 1'b0;
                    slot_live[post_tid[i]] <= 1'b1;
                end
            end

            if (cmd_valid) begin
                current_epoch <= cmd_epoch;
                retire_seq <= 8'd0;
                issue_seq <= 8'd0;
                if ((cmd_addr[31:25] != MEM_BASE_HI) || (cmd_addr[1:0] != 0)) begin
                    issue_addr <= '0;
                    issue_left <= '0;
                    fault <= 1'b1;
                end else begin
                    issue_addr <= cmd_addr;
                    issue_left <= cmd_len;
                end

                // A request granted on this exact edge is accepted and must
                // drain stale; ungranted old posts can be cancelled locally.
                for (i = 0; i < 4; i = i + 1) begin
                    if (post_valid[i]) begin
                        if (b_rq_grant[i])
                            slot_live[post_tid[i]] <= 1'b1;
                        else
                            slot_valid[post_tid[i]] <= 1'b0;
                        post_valid[i] <= 1'b0;
                    end
                end
                drain_active <= 1'b0;
            end else if ((issue_left != 0) && free_found
                    && !post_valid[issue_bid]) begin
                slot_valid[free_tid] <= 1'b1;
                slot_live[free_tid] <= 1'b0;
                slot_complete[free_tid] <= 1'b0;
                slot_error[free_tid] <= 1'b0;
                slot_epoch[free_tid] <= current_epoch;
                slot_seq[free_tid] <= issue_seq;
                slot_addr[free_tid] <= issue_addr;
                slot_beats[free_tid] <= next_beats;
                slot_rx[free_tid] <= 3'd0;
                post_valid[issue_bid] <= 1'b1;
                post_tid[issue_bid] <= free_tid;
                issue_addr <= issue_addr + {27'd0, next_beats, 2'b00};
                issue_left <= issue_left - next_beats;
                issue_seq <= issue_seq + 8'd1;
            end
        end
    end

endmodule
