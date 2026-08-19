// SPDX-License-Identifier: Apache-2.0
// Tapeout-facing PPU wrapper: native SPINE scan and render/keyhole masters.

module ppu_top_spine #(
    parameter logic [31:0] RENDER_BASE = 32'h0000_0000,
    parameter logic [6:0]  MEM_BASE_HI = RENDER_BASE[31:25]
) (
    input  logic ppu_clk,
    input  logic spine_clk,
    input  logic rst_n,

    input  logic        psel,
    input  logic        penable,
    input  logic        pwrite,
    input  logic [7:0]  paddr,
    input  logic [31:0] pwdata,
    output logic [31:0] prdata,
    output logic        pready,
    output logic        pslverr,

    output spine_b4_pkg::spine_rq_t scan_b0_rq,
    output spine_b4_pkg::spine_rq_t scan_b1_rq,
    output spine_b4_pkg::spine_rq_t scan_b2_rq,
    output spine_b4_pkg::spine_rq_t scan_b3_rq,
    input  logic [3:0]                  scan_b_rq_grant,

    output spine_b4_pkg::spine_rq_t render_b0_rq,
    output spine_b4_pkg::spine_rq_t render_b1_rq,
    output spine_b4_pkg::spine_rq_t render_b2_rq,
    output spine_b4_pkg::spine_rq_t render_b3_rq,
    output spine_b4_pkg::spine_wd_t render_b0_wd,
    output spine_b4_pkg::spine_wd_t render_b1_wd,
    output spine_b4_pkg::spine_wd_t render_b2_wd,
    output spine_b4_pkg::spine_wd_t render_b3_wd,
    input  logic [3:0]                  render_b_rq_grant,

    input  spine_b4_pkg::spine_rs_t b0_rs,
    input  spine_b4_pkg::spine_rs_t b1_rs,
    input  spine_b4_pkg::spine_rs_t b2_rs,
    input  spine_b4_pkg::spine_rs_t b3_rs,

    output logic       hsync,
    output logic       vsync,
    output logic       de,
    output logic [4:0] vid_r,
    output logic [4:0] vid_g,
    output logic [4:0] vid_b,
    output logic       halted,
    output logic       underrun,
    output logic       irq,
    output logic       spine_bus_error
);
    logic        mem_req;
    logic        mem_we;
    logic [18:0] mem_addr;
    logic [15:0] mem_wdata;
    logic        mem_ack;
    logic [15:0] mem_rdata;
    logic        fb_burst_req;
    logic [31:0] fb_burst_addr;
    logic [10:0] fb_burst_len;
    logic        fb_burst_gnt;
    logic        fb_burst_valid;
    logic [31:0] fb_burst_data;
    logic        ppu_irq;
    logic        mem_hgnt_unused;
    logic        mem_oe_unused;
    logic        scan_busy;
    logic        scan_error;
    logic        render_busy;
    logic        render_error;

    ppu_top u_ppu (
        .clk(ppu_clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .halted(halted),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_ack(mem_ack), .mem_rdata(mem_rdata),
        .fb_burst_req(fb_burst_req), .fb_burst_addr(fb_burst_addr),
        .fb_burst_len(fb_burst_len), .fb_burst_gnt(fb_burst_gnt),
        .fb_burst_valid(fb_burst_valid), .fb_burst_data(fb_burst_data),
        .mem_hreq(1'b0), .mem_hgnt(mem_hgnt_unused), .mem_oe(mem_oe_unused),
        .hsync(hsync), .vsync(vsync), .de(de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .underrun(underrun), .irq(ppu_irq)
    );

    ppu_spine_rd #(.MEM_BASE_HI(MEM_BASE_HI)) u_scan (
        .ppu_clk(ppu_clk), .spine_clk(spine_clk), .rst_n(rst_n),
        .burst_req(fb_burst_req), .burst_addr(fb_burst_addr),
        .burst_len(fb_burst_len), .burst_gnt(fb_burst_gnt),
        .burst_valid(fb_burst_valid), .burst_data(fb_burst_data),
        .b0_rq(scan_b0_rq), .b1_rq(scan_b1_rq),
        .b2_rq(scan_b2_rq), .b3_rq(scan_b3_rq),
        .b_rq_grant(scan_b_rq_grant),
        .b0_rs(b0_rs), .b1_rs(b1_rs), .b2_rs(b2_rs), .b3_rs(b3_rs),
        .busy(scan_busy), .bus_error(scan_error)
    );

    ppu_spine_flat #(.RENDER_BASE(RENDER_BASE), .MEM_BASE_HI(MEM_BASE_HI))
    u_render (
        .ppu_clk(ppu_clk), .spine_clk(spine_clk), .rst_n(rst_n),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_ack(mem_ack), .mem_rdata(mem_rdata),
        .b0_rq(render_b0_rq), .b1_rq(render_b1_rq),
        .b2_rq(render_b2_rq), .b3_rq(render_b3_rq),
        .b0_wd(render_b0_wd), .b1_wd(render_b1_wd),
        .b2_wd(render_b2_wd), .b3_wd(render_b3_wd),
        .b_rq_grant(render_b_rq_grant),
        .b0_rs(b0_rs), .b1_rs(b1_rs), .b2_rs(b2_rs), .b3_rs(b3_rs),
        .busy(render_busy), .bus_error(render_error)
    );

    assign pslverr = 1'b0;
    assign spine_bus_error = scan_error || render_error;
    assign irq = ppu_irq || spine_bus_error;

    wire _unused = &{1'b0, scan_busy, render_busy, mem_hgnt_unused,
                     mem_oe_unused, 1'b0};

endmodule
