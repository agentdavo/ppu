// Programmable CRTC. Bare compare-point registers, no adders: firmware does
// the arithmetic. Reset values are the 640x480@60 constants.
//
// Counter units are display pixels in SDR mode (cfg_dblx=1) and pixel PAIRS
// in pair-counting mode (cfg_dblx=0), where the external transmitter samples
// both clock edges and firmware programs H values divided by two.

`include "ppu_defs.vh"

// Everything advances on pix_en, so the block is unchanged by the core
// running at a multiple of the pixel rate.
module ppu_timing (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        pix_en,        // one core cycle in PPU_PIX_DIV

    input  wire [10:0] cfg_h_last,    // htotal - 1
    input  wire [10:0] cfg_h_act,     // active width  (hc < act)
    input  wire [10:0] cfg_h_bnd,     // act - 1: internal-line boundary column
    input  wire [10:0] cfg_hs_s,      // hsync window [start, end)
    input  wire [10:0] cfg_hs_e,
    input  wire  [9:0] cfg_v_last,    // vtotal - 1
    input  wire  [9:0] cfg_v_act,
    input  wire  [9:0] cfg_vs_s,
    input  wire  [9:0] cfg_vs_e,
    input  wire  [9:0] cfg_prep,      // vc at which prep_frame fires
    input  wire  [9:0] cfg_line_lim,  // line_start fires while vc < this
    input  wire        cfg_dblx,      // 1: int_x = hc/2   0: int_x = hc (pair mode)
    input  wire        cfg_dbly,      // 1: line boundaries on odd vc (line doubling)

    output reg         hsync,         // emitted active-high; pad inverts per mode
    output reg         vsync,
    output reg         active,        // inside the visible region
    // Combinational, one cycle ahead of registered `active`: the scanbuf read
    // must be enabled in the cycle its address is presented.
    output wire        active_raw,
    output wire [10:0] h_count,
    output wire  [9:0] v_count,

    output wire  [9:0] int_x,         // internal column being displayed
    output wire  [8:0] int_y,         // internal line being displayed
    output reg         line_start,    // one cycle at each internal line boundary
    output reg         prep_frame,    // last boundary before display line 0
    output reg         frame_start
);

    reg [10:0] hc;
    reg  [9:0] vc;

    assign h_count = hc;
    assign v_count = vc;
    assign int_x   = cfg_dblx ? {1'b0, hc[9:1]} : hc[9:0];
    assign int_y   = cfg_dbly ? {1'b0, vc[9:1]} : vc[8:0];

    assign active_raw = (hc < cfg_h_act) && (vc < cfg_v_act);

    wire h_last = (hc == cfg_h_last);
    wire v_last = (vc == cfg_v_last);

    // Boundaries are computed here and registered, so the pulse lands one
    // pixel later -- in the front porch, where no scanbuf read is in flight.
    // Computing at h_last instead would assert during hc==0, one pixel inside
    // the visible region, and cost the first pixel of every line.
    wire boundary_col = (hc == cfg_h_bnd);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hc <= 11'd0;
            vc <= 10'd0;
        end else if (enable && pix_en) begin
            hc <= h_last ? 11'd0 : hc + 11'd1;
            if (h_last)
                vc <= v_last ? 10'd0 : vc + 10'd1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hsync       <= 1'b0;
            vsync       <= 1'b0;
            active      <= 1'b0;
            line_start  <= 1'b0;
            prep_frame  <= 1'b0;
            frame_start <= 1'b0;
        end else if (pix_en) begin
            hsync  <= (hc >= cfg_hs_s) && (hc < cfg_hs_e);
            vsync  <= (vc >= cfg_vs_s) && (vc < cfg_vs_e);
            active <= (hc < cfg_h_act) && (vc < cfg_v_act);

            // A boundary presents the buffer filled during the PREVIOUS
            // interval, so the render counter must restart at the TOP of
            // vblank: prep_frame fires at the end of the last active pair,
            // line 0 renders across vblank, and the boundary at the end of
            // the frame swaps it in for display line 0. Line boundaries land
            // entering an EVEN vc (i.e. in the blanking of an odd one) when
            // line-doubling, or every line otherwise.
            prep_frame  <= boundary_col && (vc == cfg_prep);
            line_start  <= boundary_col && (((vc[0] || !cfg_dbly) && (vc < cfg_line_lim))
                                            || (vc == cfg_v_last));
            frame_start <= boundary_col && v_last;
        end
    end

endmodule
