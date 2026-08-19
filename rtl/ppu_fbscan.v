// ppu_fbscan -- linear-framebuffer scanout engine (simple-framebuffer
// contract): each active line, read fb_w pixels from fb_base + y*fb_stride,
// convert to internal ARGB1555, fill the scanline buffer. No program, no
// palette, no blend, no cache.
//
// One burst request per line (start address + beat count). The return side
// counts burst_valid beats and nothing else, so device stalls arrive only as
// gaps in the stream; splitting a burst (page/refresh limits) is the memory
// controller's job. A 32-bit beat is one scanbuf word -- two 16 bpp pixels,
// so only 32 bpp still pairs. The line address is computed incrementally:
// frame_restart reloads fb_base, every other line start adds fb_stride.

`include "ppu_defs.vh"

module ppu_fbscan (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,          // ppu_enable && FB_CTRL.FB_EN

    // Line handshake -- identical to ppu_cmd's, so ppu_display's ownership
    // and overrun policy are unchanged by which engine runs.
    input  wire        line_start,
    input  wire        frame_restart,
    input  wire  [8:0] raster_y,
    output reg         line_done,

    // Framebuffer configuration. FB_BASE is a full 32-bit system byte
    // address, 4-byte aligned: one beat is one scanbuf word.
    input  wire [31:0] fb_base,
    input  wire [15:0] fb_stride,
    input  wire  [9:0] fb_w,
    input  wire  [9:0] fb_h,
    input  wire  [2:0] fb_fmt,
    input  wire [10:0] int_w,           // internal line width (CRTC register)

    // External memory burst port. Synchronous to `clk`, the core clock; rate
    // and domain conversion (CDC) lives in the memory controller. Arbitrary
    // delay to the first beat and arbitrary gaps in the stream are fine.
    output reg         burst_req,       // held until burst_gnt
    output wire [31:0] burst_addr,      // start of this line, system address
    output wire [10:0] burst_len,       // beats wanted
    input  wire        burst_gnt,       // request accepted; drop burst_req
    input  wire        burst_valid,     // one data beat this cycle
    input  wire [31:0] burst_data,       // 32 bits: one scanbuf word of 16 bpp

    // Scanbuf write port: whole 32-bit words, two pixels at a time. No
    // read-modify-write and no pairing state, so a sparse beat pattern
    // cannot desynchronise it.
    output reg         sb_wr,
    output reg   [8:0] sb_addr,
    output reg  [31:0] sb_data
);

    localparam S_IDLE = 2'd0, S_FETCH = 2'd1, S_FILL = 2'd2, S_DONE = 2'd3;

    reg  [1:0]  state;
    reg  [31:0] line_addr;      // start of the line currently being fetched
    reg  [10:0] rx;             // pixels assembled this line
    reg  [8:0]  fill_w;         // word index for the blank tail
    reg         blank;          // this line is past the bottom of the framebuffer

    wire        fmt32 = (fb_fmt == `PPU_FB_X8R8G8B8);

    // Pixels fetched this line: fb_w clamped to the buffer width. Anything
    // past it is blanked -- a narrower framebuffer is legal, and stale
    // pixels are worse than black.
    wire [10:0] npx   = blank                        ? 11'd0
                      : ({1'b0, fb_w} > int_w)       ? int_w
                                                     : {1'b0, fb_w};
    // Beats per line: one pixel each at 32 bpp, two at 16 bpp (rounded up).
    wire [10:0] beats = fmt32 ? npx : ((npx + 11'd1) >> 1);

    // At 16 bpp rx steps by two, so with an odd width it steps PAST npx;
    // hence >= there rather than equality.
    wire        last_beat = fmt32 ? (rx == npx - 11'd1)
                                  : (rx + 11'd2 >= npx);

    // Word address of the pixel being assembled, and of the blank tail.
    wire [8:0]  rx_word = rx[10:1];

    // The burst is the line: no running address, no issued-beat counter.
    assign burst_addr = line_addr;
    assign burst_len  = beats;

    // Computed for the line about to start, so the request can be raised on
    // the same edge that latches the geometry.
    wire        blank_n = ({1'b0, raster_y} >= fb_h);
    wire [10:0] npx_n   = blank_n                    ? 11'd0
                        : ({1'b0, fb_w} > int_w)     ? int_w
                                                     : {1'b0, fb_w};

    // Equality tests below are safe: rx and fill_w are stopped by the very
    // test made, so neither steps past its limit. Invariants: rx < npx while
    // in S_FETCH (npx == 0 never enters it); fill_w <= int_w/2 (loaded from
    // rx_word + 1, max 160).

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            line_addr  <= 32'd0;
            burst_req  <= 1'b0;
            rx         <= 11'd0;
            fill_w     <= 9'd0;
            blank      <= 1'b0;
            line_done  <= 1'b0;
            sb_wr      <= 1'b0;
            sb_addr    <= 8'd0;
            sb_data    <= 32'd0;
        end else begin
            line_done <= 1'b0;
            sb_wr     <= 1'b0;

            // A line start restarts the engine even mid-line: ppu_display has
            // already decided via `ready` whether this line may swap (else it
            // latches `underrun`), and a half-fetched line carried across the
            // boundary would tear.
            if (enable && line_start) begin
                line_addr <= frame_restart ? fb_base
                                           : line_addr + {16'd0, fb_stride};
                blank     <= blank_n;
                rx        <= 11'd0;
                fill_w    <= 9'd0;
                // Ask for the whole line on the edge that latches its
                // geometry; a line with nothing to fetch never asks.
                burst_req <= (npx_n != 11'd0);
                state     <= (npx_n != 11'd0) ? S_FETCH : S_FILL;
            end else begin
                case (state)
                    // ------------------------------------------------ fetching
                    S_FETCH: begin
                        // Issue side: one request, held until taken.
                        if (burst_req && burst_gnt)
                            burst_req <= 1'b0;

                        // Return side is driven purely by burst_valid: a late
                        // first beat or a mid-stream gap costs time only.
                        if (burst_valid) begin
                            if (fmt32) begin
                                // One pixel per beat: the even pixel parks in
                                // sb_data[15:0]; nothing commits until sb_wr
                                // pulses.
                                rx <= rx + 11'd1;
                                if (!rx[0]) begin
                                    sb_data[15:0] <= conv32(burst_data);
                                    // An odd width ends on an even rx: commit
                                    // it now with a black partner.
                                    if (last_beat) begin
                                        sb_data[31:16] <= 16'd0;
                                        sb_wr          <= 1'b1;
                                        sb_addr        <= rx_word;
                                    end
                                end else begin
                                    sb_data[31:16] <= conv32(burst_data);
                                    sb_wr          <= 1'b1;
                                    sb_addr        <= rx_word;
                                end
                            end else begin
                                // Two pixels per beat is a whole buffer word:
                                // converted and written in one cycle.
                                rx      <= rx + 11'd2;
                                sb_wr   <= 1'b1;
                                sb_addr <= rx_word;
                                sb_data <= {(rx + 11'd1 >= npx) ? 16'd0
                                                                : conv16(burst_data[31:16]),
                                            conv16(burst_data[15:0])};
                            end

                            if (last_beat) begin
                                fill_w <= rx_word + 9'd1;
                                state  <= S_FILL;
                            end
                        end
                    end

                    // ---------------------------------------------- blank tail
                    // One zero word per cycle out to the buffer width.
                    S_FILL: begin
                        if (fill_w == int_w[10:1]) begin
                            state <= S_DONE;
                        end else begin
                            sb_wr   <= 1'b1;
                            sb_addr <= fill_w;
                            sb_data <= 32'd0;
                            fill_w  <= fill_w + 9'd1;
                        end
                    end

                    S_DONE: begin
                        line_done <= 1'b1;
                        state     <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end

            if (!enable) begin
                state     <= S_IDLE;
                burst_req <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------- conversion
    // Alpha is forced opaque in every format. r5g6b5 drops green's LSB;
    // x8r8g8b8 truncates each channel 8 -> 5; r5g5b5a1 carries alpha in the
    // LOW bit.
    function [15:0] conv16;
        input [15:0] d;
        begin
            case (fb_fmt)
                `PPU_FB_R5G6B5:   conv16 = {1'b1, d[15:11], d[10:6], d[4:0]};
                `PPU_FB_R5G5B5A1: conv16 = {1'b1, d[15:11], d[10:6], d[5:1]};
                // a1r5g5b5, x1r5g5b5, and the reserved codes
                default:          conv16 = {1'b1, d[14:0]};
            endcase
        end
    endfunction

    // x8r8g8b8, little-endian: byte 0 = B, 1 = G, 2 = R, 3 = ignored X.
    function [15:0] conv32;
        input [31:0] d;
        begin
            conv32 = {1'b1, d[23:19], d[15:11], d[7:3]};
        end
    endfunction

endmodule
