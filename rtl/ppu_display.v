// Display controller: owns scanline buffer handover and drives the digital
// RGB555 output.
//
// Two buffers, one ownership bit. At each internal line boundary:
//   render finished -> swap, advance render_y, start the next line
//   render overran  -> no swap; the display repeats the line it has, the
//                      renderer gets another full line time, `underrun`
//                      latches (sticky, raises IRQ)
// Repeating degrades under load but never tears and never shows a
// half-rendered buffer.
//
// The renderer runs one internal line AHEAD of scanout: a boundary presents
// the buffer filled during the previous interval. prep_frame fires at the
// end of the last active pair so line 0 renders across vblank -- see
// ppu_timing.v.

`include "ppu_defs.vh"

module ppu_display (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        pix_en,

    // From the timing generator
    input  wire        line_tick,      // internal line boundary
    input  wire        prep_frame,     // last line boundary before display line 0
    input  wire  [9:0] int_x,
    input  wire  [8:0] int_y,
    input  wire        active,
    input  wire        active_raw,
    input  wire        hsync_raw,
    input  wire        vsync_raw,

    // Render side handshake
    output reg         render_start,
    output reg         frame_restart,
    output reg   [8:0] render_y,
    input  wire        render_done,

    // Scanbuf
    output wire        buf_swap,
    output wire        disp_req,
    output wire  [8:0] disp_addr,
    input  wire [31:0] disp_data,

    // Configuration (DISP_CFG)
    input  wire        cfg_hsync_pol,  // 1 = active high
    input  wire        cfg_vsync_pol,
    input  wire        cfg_dig_en,
    output wire        busy_o,

    // Digital RGB555 output
    output reg         hsync,
    output reg         vsync,
    output reg         de,
    output reg   [4:0] vid_r,
    output reg   [4:0] vid_g,
    output reg   [4:0] vid_b,

    // Status
    output reg         underrun,       // sticky; cleared via CSR
    input  wire        underrun_clr,
    output wire        irq
);

    assign disp_addr = int_x[9:1];
    // Which core cycle of the pixel period issues the scanbuf read. At
    // PIX_DIV=2 the read goes on the non-pix_en half so the macro's one-cycle
    // latency lands on the latch half. At PIX_DIV=1 there is only one cycle,
    // so the read must go on THAT cycle.
    wire disp_phase = (`PPU_PIX_DIV == 1) ? 1'b1 : ~pix_en;
    assign disp_req  = active_raw && disp_phase;

    // ---------------------------------------------------------------- handshake
    reg busy;               // a render is outstanding for the current render_y
    assign busy_o = busy;
    reg swap_r;

    assign buf_swap = swap_r;
    assign irq      = underrun;

    // line_tick/prep_frame hold for a whole pixel period; pix_en turns them
    // back into single-cycle events. Without it the handshake fires twice per
    // line and render_y advances twice.
    wire boundary = (line_tick || prep_frame) && pix_en;
    wire ready    = !busy || render_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy         <= 1'b0;
            swap_r       <= 1'b0;
            render_start <= 1'b0;
            frame_restart<= 1'b0;
            render_y     <= 9'd0;
            underrun     <= 1'b0;
        end else begin
            swap_r       <= 1'b0;
            render_start <= 1'b0;
            frame_restart<= 1'b0;

            if (render_done)
                busy <= 1'b0;

            if (underrun_clr)
                underrun <= 1'b0;

            if (enable && boundary) begin
                if (ready) begin
                    swap_r       <= 1'b1;
                    render_start <= 1'b1;
                    frame_restart<= prep_frame;
                    busy         <= 1'b1;
                    // prep_frame rezeroes every frame; between frames the
                    // 9-bit counter's natural wrap is the only bound, since a
                    // fixed wrap point would fire mid-frame in the taller
                    // internal modes the CRTC allows.
                    render_y <= prep_frame ? 9'd0 : render_y + 9'd1;
                end else begin
                    // Overrun: keep the buffer, repeat the displayed line.
                    underrun <= 1'b1;
                end
            end
        end
    end

    // ----------------------------------------------------------------- scanout
    // The scanbuf is synchronous: the half-select must use int_x[0] DELAYED
    // one cycle to match Q, or every pair comes out swapped.
    reg x0_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        x0_d <= 1'b0;
        else if (disp_phase) x0_d <= int_x[0]; // captured with the read address
    end

    wire [15:0] px = x0_d ? disp_data[31:16] : disp_data[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {hsync, vsync, de}          <= 3'b000;
            {vid_r, vid_g, vid_b}       <= 15'd0;
        end else if (pix_en) begin
            hsync <= cfg_hsync_pol ? hsync_raw : ~hsync_raw;
            vsync <= cfg_vsync_pol ? vsync_raw : ~vsync_raw;
            de    <= active;

            // 5 bits per gun; the external sink replicates to 8 if needed.
            vid_r <= (active && cfg_dig_en) ? px[14:10] : 5'd0;
            vid_g <= (active && cfg_dig_en) ? px[9:5]   : 5'd0;
            vid_b <= (active && cfg_dig_en) ? px[4:0]   : 5'd0;
        end
    end

endmodule
