// Double-buffered scanline store on single-port sram512x8 macros.
// 512 words x 32 b per buffer (2 px/word), four x8 macros per bank.
//
// Render cadence: read word n on edge k, blend against Q during k+1, write
// the pair back on edge k+1 -- one port access per cycle at 1 px/clk.
// WEN is bit-level, so committing a single pixel of a pair is free.

`include "ppu_defs.vh"

module ppu_scanbuf (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        swap,            // buffer roles exchange on internal line start

    // Render side
    input  wire        rd_req,          // even phase: fetch the word for this pair
    input  wire        wr_req,          // odd phase: commit the blended pair
    input  wire  [8:0] word_addr,
    input  wire [31:0] wr_data,
    input  wire  [1:0] wr_mask,         // which pixel(s) of the pair to commit
    output wire [31:0] rd_data,

    // Display side
    input  wire        disp_req,
    input  wire  [8:0] disp_addr,
    output wire [31:0] disp_data
);

    reg buf_sel;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      buf_sel <= 1'b0;
        else if (swap)   buf_sel <= ~buf_sel;
    end

    // Per-pixel write enables, expanded to the macros' bit-level WEN.
    wire [31:0] wen_n = ~{{16{wr_mask[1]}}, {16{wr_mask[0]}}};

    wire [31:0] q0, q1;
    assign rd_data   = buf_sel ? q1 : q0;
    assign disp_data = buf_sel ? q0 : q1;

    // Exactly one agent addresses a given buffer in a given line. CEN stays
    // deasserted when idle: the macro requires CEN activity to operate, and a
    // permanently-low CEN burns power on every edge.
    wire acc = rd_req || wr_req;

    ppu_scanbuf_bank bank0 (
        .clk(clk),
        .en   (buf_sel ? disp_req : acc),
        .we   (!buf_sel && wr_req),
        .addr (buf_sel ? disp_addr : word_addr),
        .wdata(wr_data),
        .wen_n(wen_n),
        .rdata(q0)
    );

    ppu_scanbuf_bank bank1 (
        .clk(clk),
        .en   (buf_sel ? acc : disp_req),
        .we   (buf_sel && wr_req),
        .addr (buf_sel ? word_addr : disp_addr),
        .wdata(wr_data),
        .wen_n(wen_n),
        .rdata(q1)
    );


endmodule


// One 32-bit buffer from four x8 macros in parallel; nothing wider exists.
module ppu_scanbuf_bank (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire  [8:0] addr,
    input  wire [31:0] wdata,
    input  wire [31:0] wen_n,
    output wire [31:0] rdata
);

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : lane
            gf180mcu_fd_ip_sram__sram512x8m8wm1 u_sram (
                .CLK (clk),
                .CEN (~en),                       // all enables active LOW
                .GWEN(~we),
                .WEN (wen_n[i*8 +: 8]),
                .A   (addr),
                .D   (wdata[i*8 +: 8]),
                .Q   (rdata[i*8 +: 8])
            );
        end
    endgenerate

endmodule
