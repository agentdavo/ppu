// SoC wrapper: APB3 slave for registers (PSLVERR tied low -- no erroring
// registers), full AXI4 read-only master for framebuffer scanout (AR+R only;
// Lite has no bursts and is unusable on the pixel path).
//
// The bare ppu_top keeps the native burst port and remains the verification
// target; this wrapper adds only the adapters.

module ppu_top_axi (
    input  wire        clk,           // one clock: core, pixel, ACLK, PCLK
    input  wire        rst_n,

    // APB3 slave
    input  wire        psel,
    input  wire        penable,
    input  wire        pwrite,
    input  wire  [7:0] paddr,
    input  wire [31:0] pwdata,
    output wire [31:0] prdata,
    output wire        pready,
    output wire        pslverr,

    // AXI4 read-only master -- framebuffer scanout
    output wire        m_arvalid,
    output wire [31:0] m_araddr,
    output wire  [7:0] m_arlen,
    output wire  [2:0] m_arsize,
    output wire  [1:0] m_arburst,
    input  wire        m_arready,
    input  wire        m_rvalid,
    input  wire [31:0] m_rdata,
    input  wire        m_rlast,
    output wire        m_rready,

    // Flat port -- render path + keyhole
    output wire        mem_req,
    output wire        mem_we,
    output wire [18:0] mem_addr,
    output wire [15:0] mem_wdata,
    input  wire        mem_ack,
    input  wire [15:0] mem_rdata,
    input  wire        mem_hreq,
    output wire        mem_hgnt,
    output wire        mem_oe,

    // Video out -- digital RGB555
    output wire        hsync, vsync, de,
    output wire  [4:0] vid_r, vid_g, vid_b,

    output wire        halted,
    output wire        underrun,
    output wire        irq
);

    assign pslverr = 1'b0;

    wire        fbb_req, fbb_gnt, fbb_valid;
    wire [31:0] fbb_addr, fbb_data;
    wire [10:0] fbb_len;

    ppu_top u_ppu (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
        .pwdata(pwdata), .prdata(prdata), .pready(pready), .halted(halted),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_ack(mem_ack), .mem_rdata(mem_rdata),
        .fb_burst_req(fbb_req), .fb_burst_addr(fbb_addr),
        .fb_burst_len(fbb_len), .fb_burst_gnt(fbb_gnt),
        .fb_burst_valid(fbb_valid), .fb_burst_data(fbb_data),
        .mem_hreq(mem_hreq), .mem_hgnt(mem_hgnt), .mem_oe(mem_oe),
        .hsync(hsync), .vsync(vsync), .de(de),
        .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b),
        .underrun(underrun), .irq(irq)
    );

    ppu_axi_rd u_axi (
        .clk(clk), .rst_n(rst_n),
        .burst_req(fbb_req), .burst_addr(fbb_addr), .burst_len(fbb_len),
        .burst_gnt(fbb_gnt), .burst_valid(fbb_valid), .burst_data(fbb_data),
        .arvalid(m_arvalid), .araddr(m_araddr), .arlen(m_arlen),
        .arsize(m_arsize), .arburst(m_arburst), .arready(m_arready),
        .rvalid(m_rvalid), .rdata(m_rdata), .rlast(m_rlast), .rready(m_rready)
    );

endmodule
