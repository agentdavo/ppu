`timescale 1ns/1ps

module ppu_spine_flat_core_tb;
    import spine_b4_pkg::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    initial begin
        #5000;
        $fatal(1, "PPU flat SPINE core test timed out");
    end

    logic cmd_valid, cmd_ready, cmd_we;
    logic [31:0] cmd_addr;
    logic [15:0] cmd_wdata;
    logic [11:0] cmd_ctx;
    logic result_valid, result_error, fault;
    logic [15:0] result_data;
    spine_rq_t b0_rq, b1_rq, b2_rq, b3_rq;
    spine_wd_t b0_wd, b1_wd, b2_wd, b3_wd;
    logic [3:0] b_rq_grant;
    spine_rs_t b0_rs, b1_rs, b2_rs, b3_rs;

    integer result_count;
    logic [15:0] last_result;
    logic last_error;
    always @(posedge clk) begin
        if (result_valid) begin
            result_count <= result_count + 1;
            last_result <= result_data;
            last_error <= result_error;
        end
    end

    ppu_spine_flat_core dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we),
        .cmd_addr(cmd_addr), .cmd_wdata(cmd_wdata), .cmd_ctx(cmd_ctx),
        .result_valid(result_valid), .result_data(result_data),
        .result_error(result_error),
        .b0_rq(b0_rq), .b1_rq(b1_rq), .b2_rq(b2_rq), .b3_rq(b3_rq),
        .b0_wd(b0_wd), .b1_wd(b1_wd), .b2_wd(b2_wd), .b3_wd(b3_wd),
        .b_rq_grant(b_rq_grant),
        .b0_rs(b0_rs), .b1_rs(b1_rs), .b2_rs(b2_rs), .b3_rs(b3_rs),
        .fault(fault)
    );

    task automatic command(
        input logic we,
        input logic [31:0] addr,
        input logic [15:0] data,
        input logic [11:0] ctx
    );
        begin
            while (!cmd_ready) @(negedge clk);
            cmd_we = we;
            cmd_addr = addr;
            cmd_wdata = data;
            cmd_ctx = ctx;
            cmd_valid = 1'b1;
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task automatic grant_b2;
        begin
            while (!b2_rq.valid) @(negedge clk);
            b_rq_grant = 4'b0100;
            @(negedge clk);
            b_rq_grant = '0;
        end
    endtask

    task automatic send_b2(
        input logic [31:0] data,
        input logic last,
        input spine_rs_kind_e kind,
        input logic [11:0] ctx
    );
        begin
            b2_rs = '0;
            b2_rs.valid = 1'b1;
            b2_rs.p.src = SPINE_SRC_PPU_RENDER;
            b2_rs.p.tid = 3'd0;
            b2_rs.p.ctx = ctx;
            b2_rs.p.data = data;
            b2_rs.p.last = last;
            b2_rs.p.kind = kind;
            b2_rs.p.status = SPINE_ST_OK;
            b2_rs.p.par = rs_even_parity(b2_rs.p);
            @(negedge clk);
            b2_rs = '0;
        end
    endtask

    initial begin
        cmd_valid = 1'b0;
        cmd_we = 1'b0;
        cmd_addr = '0;
        cmd_wdata = '0;
        cmd_ctx = '0;
        b_rq_grant = '0;
        b0_rs = '0; b1_rs = '0; b2_rs = '0; b3_rs = '0;
        result_count = 0;
        last_result = '0;
        last_error = 1'b0;

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        // Address 0x26 is B2, word 1, upper 16-bit half.  The result must be
        // forwarded on the critical beat before the rest of the line arrives.
        command(1'b0, 32'h0000_0026, 16'd0, 12'h123);
        while (!b2_rq.valid) @(negedge clk);
        if (b2_rq.p.cmd != SPINE_CMD_READ || b2_rq.p.beats_m1 != 2'd3
                || b2_rq.p.ctx != 12'h123 || b2_rq.p.off != 4'd0)
            $fatal(1, "bad line-fill request");
        grant_b2();
        send_b2(32'h1111_0000, 1'b0, SPINE_RS_DATA, 12'h123);
        send_b2(32'h2222_3333, 1'b0, SPINE_RS_DATA, 12'h123);
        @(negedge clk);
        if (result_count != 1 || last_result != 16'h2222 || last_error)
            $fatal(1, "critical-half forwarding failed");
        send_b2(32'h5555_4444, 1'b0, SPINE_RS_DATA, 12'h123);
        send_b2(32'h7777_6666, 1'b1, SPINE_RS_DATA, 12'h123);

        // The same address now hits the two-line local record with no bus RQ.
        command(1'b0, 32'h0000_0026, 16'd0, 12'h124);
        @(negedge clk);
        if (result_count != 2 || last_result != 16'h2222 || b2_rq.valid)
            $fatal(1, "line-record hit failed");

        // A halfword write is eager: RQ and WD are valid together, with only
        // upper byte lanes selected.  It invalidates the matching read record.
        command(1'b1, 32'h0000_0026, 16'habcd, 12'h125);
        while (!b2_rq.valid) @(negedge clk);
        if (!b2_wd.valid || b2_wd.p.data != 32'habcd_0000
                || b2_wd.p.strb != 4'b1100 || b2_rq.p.ctx != 12'h125)
            $fatal(1, "eager halfword write malformed");
        grant_b2();
        send_b2(32'd0, 1'b1, SPINE_RS_ACK, 12'h125);
        @(negedge clk);
        if (result_count != 3 || last_error)
            $fatal(1, "write completion failed");

        command(1'b0, 32'h0000_0026, 16'd0, 12'h126);
        while (!b2_rq.valid) @(negedge clk);
        if (b2_rq.p.ctx != 12'h126)
            $fatal(1, "write did not invalidate read record");

        if (fault) $fatal(1, "unexpected adapter fault");
        $display("PPU flat SPINE core passed: refill, critical forward, hit, eager write");
        $finish;
    end
endmodule
