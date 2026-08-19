// SPDX-License-Identifier: Apache-2.0

module ppu_spine_rd_core_tb;
  import spine_b4_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #10 clk = ~clk;

  logic cmd_valid;
  logic [31:0] cmd_addr;
  logic [10:0] cmd_len;
  logic [3:0] cmd_epoch;
  logic cmd_accept;
  spine_rq_t b0_rq, b1_rq, b2_rq, b3_rq;
  logic [3:0] grants;
  spine_rs_t b0_rs, b1_rs, b2_rs, b3_rs;
  logic out_valid, out_ready;
  logic [3:0] out_epoch;
  logic [31:0] out_data;
  logic busy, fault;

  ppu_spine_rd_core dut (
    .clk(clk), .rst_n(rst_n),
    .cmd_valid(cmd_valid), .cmd_addr(cmd_addr), .cmd_len(cmd_len),
    .cmd_epoch(cmd_epoch), .cmd_accept(cmd_accept),
    .b0_rq(b0_rq), .b1_rq(b1_rq), .b2_rq(b2_rq), .b3_rq(b3_rq),
    .b_rq_grant(grants),
    .b0_rs(b0_rs), .b1_rs(b1_rs), .b2_rs(b2_rs), .b3_rs(b3_rs),
    .out_valid(out_valid), .out_ready(out_ready),
    .out_epoch(out_epoch), .out_data(out_data), .busy(busy), .fault(fault)
  );

  assign grants = {b3_rq.valid, b2_rq.valid, b1_rq.valid, b0_rq.valid};

  logic [2:0] req_tid [0:7];
  logic [11:0] req_ctx [0:7];
  logic [31:0] req_addr [0:7];
  logic [2:0] req_beats [0:7];
  logic [1:0] req_bus [0:7];
  integer req_count = 0;
  integer rx_count = 0;

  task automatic capture_req(input spine_rq_t r, input logic [1:0] bid);
    begin
      if (r.valid) begin
        req_tid[req_count] = r.p.tid;
        req_ctx[req_count] = r.p.ctx;
        req_addr[req_count] = {7'h00, r.p.line, bid, r.p.off};
        req_beats[req_count] = {1'b0, r.p.beats_m1} + 3'd1;
        req_bus[req_count] = bid;
        req_count = req_count + 1;
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      capture_req(b0_rq, 2'd0);
      capture_req(b1_rq, 2'd1);
      capture_req(b2_rq, 2'd2);
      capture_req(b3_rq, 2'd3);
      if (out_valid && out_ready) begin
        if (out_epoch != 4'd1)
          $fatal(1, "wrong output epoch %0d", out_epoch);
        if (out_data != rx_count)
          $fatal(1, "out[%0d]=%08x", rx_count, out_data);
        rx_count = rx_count + 1;
      end
    end
  end

  function automatic spine_rs_t make_rs(
    input integer n,
    input integer beat
  );
    spine_rs_t r;
    begin
      r = '0;
      r.valid = 1'b1;
      r.p.src = SPINE_SRC_PPU_SCAN;
      r.p.tid = req_tid[n];
      r.p.ctx = req_ctx[n];
      r.p.data = (req_addr[n] >> 2) + beat;
      r.p.last = (beat + 1 == req_beats[n]);
      r.p.kind = SPINE_RS_DATA;
      r.p.status = SPINE_ST_OK;
      r.p.par = rs_even_parity(r.p);
      make_rs = r;
    end
  endfunction

  task automatic send_packet(input integer n);
    integer beat;
    begin
      for (beat = 0; beat < req_beats[n]; beat = beat + 1) begin
        @(negedge clk);
        case (req_bus[n])
          2'd0: b0_rs = make_rs(n, beat);
          2'd1: b1_rs = make_rs(n, beat);
          2'd2: b2_rs = make_rs(n, beat);
          2'd3: b3_rs = make_rs(n, beat);
        endcase
        @(negedge clk);
        b0_rs = '0; b1_rs = '0; b2_rs = '0; b3_rs = '0;
      end
    end
  endtask

  initial begin
    cmd_valid = 1'b0;
    cmd_addr = '0;
    cmd_len = '0;
    cmd_epoch = '0;
    b0_rs = '0; b1_rs = '0; b2_rs = '0; b3_rs = '0;
    out_ready = 1'b1;

    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(negedge clk);
    cmd_addr = 32'h0000_0000;
    cmd_len = 11'd10;
    cmd_epoch = 4'd1;
    cmd_valid = 1'b1;
    @(negedge clk);
    cmd_valid = 1'b0;

    wait (req_count == 3);
    if (req_beats[0] != 4 || req_beats[1] != 4 || req_beats[2] != 2)
      $fatal(1, "bad packet lengths %0d %0d %0d",
             req_beats[0], req_beats[1], req_beats[2]);

    // Deliberately complete packets in reverse order.  Output must remain
    // the original monotonically increasing line stream.
    send_packet(2);
    send_packet(1);
    send_packet(0);

    wait (rx_count == 10);
    repeat (3) @(posedge clk);
    if (fault) $fatal(1, "unexpected SPINE fault");
    $display("PPU SPINE core passed: %0d packets, %0d ordered beats",
             req_count, rx_count);
    $finish;
  end

  initial begin
    #20000;
    $fatal(1, "timeout");
  end
endmodule
