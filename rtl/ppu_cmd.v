// Display-list command processor: runs one scanline of commands per
// line_start, until SYNC. 16-bit fetch port in, pixel stream out.
// ip/ppu/model/ppu_model.py is normative for field positions.
//
// FILL / BLIT / TILE / ABLIT / ATILE all drive one shared span iterator and
// one unpacker; there are no per-command engines.

`include "ppu_defs.vh"

module ppu_cmd (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,

    input  wire        line_start,
    input  wire        frame_restart,   // reload the program vector for a new frame
    input  wire  [8:0] raster_y,
    output reg         line_done,

    input  wire        pc_load,
    input  wire [18:0] pc_in,

    // 16-bit fetch port
    output reg         fetch_req,
    output reg  [18:0] fetch_addr,
    output reg         fetch_stream,
    input  wire        fetch_ack,
    input  wire [15:0] fetch_data,

    // Pixel stream to the blend / scanbuf path
    output reg         px_valid,
    output reg   [9:0] px_x,
    output reg  [15:0] px_word,       // raw source word, unpacked downstream
    output reg   [1:0] px_fmt,
    output reg   [3:0] px_sub,
    output reg   [2:0] px_poff,
    output reg   [2:0] px_mode,
    output reg   [4:0] px_alpha,
    output reg         px_prio,      // 0 = this pixel yields, see ppu_blend
    output reg         px_direct,     // FILL supplies colour directly

    // Palette write port (PALW)
    output reg         pram_we,
    output reg   [7:0] pram_addr,
    output reg  [15:0] pram_wdata,

    output reg         halted,
    output wire  [3:0] dbg_state
);

    localparam S_IDLE  = 4'd0,  S_IF0  = 4'd1,  S_IF1  = 4'd2,  S_DEC  = 4'd3,
               S_ARG0  = 4'd4,  S_ARG1 = 4'd5,  S_SPAN = 4'd6,  S_IDX0 = 4'd7,
               S_IDX1  = 4'd8,  S_TEX0 = 4'd9,  S_TEX1 = 4'd10, S_AFF  = 4'd11,
               S_NEXT  = 4'd12, S_HALT = 4'd13, S_BLD0 = 4'd14, S_BLD1 = 4'd15;

    reg [3:0] state;
    assign dbg_state = state;

    reg [18:0] pc, pc_base;   // pc doubles as the argument cursor -- see S_ARG1
    reg [15:0] arg_data;      // captured in S_ARG0, consumed in S_ARG1
    reg [31:0] insn, argw;
    reg  [2:0] args_left, arg_idx;

    // Decoded fields are combinational, not registered: insn is stable from
    // S_DEC until the next S_IF0 overwrites it (argument words land in
    // argw/arg_data, never in insn).
    wire  [3:0] opcode   = insn[31:28];
    wire  [9:0] cmd_x    = insn[9:0];
    wire  [9:0] cmd_y    = insn[19:10];
    wire  [2:0] img_poff = insn[22:20];
    wire  [2:0] cmd_size = insn[25:23];
    wire        tile_s   = insn[23];
    // TILE bit 24 selects 16-bit tilemap entries:
    //   index[7:0]  hflip[8]  vflip[9]  poff[12:10]
    // One index fetch per tile instead of one per two, which only became
    // affordable once the index was read once per TILE rather than per pixel.
    wire        tmap_wide = insn[24] && is_tile;
    // BLIT mirroring. Both bits are free in BLIT's encoding, and a BLITLIST
    // descriptor's d0 shares that layout, so sprites on a list flip too.
    // ABLIT already uses bit 26 for its half-texture flag, hence the opcode
    // qualification: flipping applies to plain BLIT only.
    wire        is_blit  = (opcode == `PPU_OP_BLIT);
    wire        cmd_hflip = is_blit && insn[26];
    wire        cmd_vflip = is_blit && insn[27];
    wire        is_tile   = (opcode == `PPU_OP_TILE)  || (opcode == `PPU_OP_ATILE);
    wire        is_affine = (opcode == `PPU_OP_ABLIT) || (opcode == `PPU_OP_ATILE);
    wire [15:0] fill_col  = {1'b1, insn[14:0]};

    // Set-once persistent state: clip window, blend mode/alpha.
    reg  [9:0] clip_start, clip_end;
    // Second window. CLIP shortens the span; this masks pixels WITHIN it, so
    // it can cut a hole (or restrict drawing to a band) without splitting the
    // span into two commands. Disabled out of reset, so it costs nothing until
    // a WIN instruction turns it on.
    reg  [9:0] win_start, win_end;
    reg        win_en, win_out;   // win_out: draw OUTSIDE the window instead
    reg  [2:0] blend_mode;
    reg  [4:0] blend_alpha;
    reg        blend_prio;   // BLEND bit 8 set == yields; reset to normal

    reg [18:0] img_base, tmap_base;

    // BLITLIST walker. Each 8-byte descriptor is (d0, d1); d0 has BLIT's field
    // layout below bit 28, so the walker rebuilds insn as a synthetic BLIT,
    // loads img_base/img_fmt from d1, and reuses the ordinary span machinery.
    reg        bl_active;
    reg  [7:0] bl_count;
    reg [16:0] bl_ptr;      // descriptor pointer in words (byte address >> 2)
    reg  [1:0] bl_word;     // which 16-bit half of the descriptor is in flight
    reg  [1:0] img_fmt, pfs;

    reg  [9:0] span_x, span_end;
    reg  [9:0] cur_u, cur_v;
    reg  [7:0] tile_idx;
    reg        tile_hf, tile_vf;   // per-tile flip, wide entries only
    reg  [2:0] tile_poff;         // per-tile sub-palette, wide entries only

    // Tile-index reuse. A tile spans 8 or 16 consecutive pixels, so the
    // tilemap lookup in S_IDX0/S_IDX1 returns the same byte for all of them --
    // yet it was performed for EVERY pixel, at two states plus a fetch. The
    // index cache absorbed the memory traffic, which is why the stall counters
    // looked healthy while the renderer still missed the line rate.
    //
    // Comparing the generated address is correct for ATILE as well as TILE: it
    // tests the address actually produced rather than assuming a step, so an
    // affine walk that stays inside one tile benefits and one that jumps
    // refetches. Invalidated at every instruction boundary (S_NEXT), so a new
    // TILE with a different tilemap base can never reuse a stale index.
    reg [18:0] idx_addr_q;
    reg        idx_valid;

    // The pixel whose fetch is in flight, one step behind cur_u/span_x. The
    // texel arriving this clock belongs to the request issued last clock, so
    // its x and sub-word index travel WITH the request; the coordinates have
    // already moved on to the next pixel by then.
    reg  [9:0] issue_x;
    reg  [3:0] issue_sub;

    // Affine accumulators, 10.8 fixed point. a is signed 8.8; b is signed
    // 10.6 (translation), shifted left 2 to align fractional widths with a.
    reg signed [15:0] a00, a01, a10, a11, b0, b1;
    reg signed [21:0] acc_u, acc_v;

    // Span start acc = A*(dx0,dy) + b<<2: four products sequenced through one
    // multiplier (setup is per-command, not per-pixel; stepping stays a pair
    // of adds at 1 px/clk). The product is registered (mul_p_r); each
    // accumulate consumes the previous cycle's product.
    reg  [2:0] mul_step;
    reg signed [15:0] mul_a;
    reg signed [11:0] mul_b;
    wire signed [27:0] mul_p = mul_a * mul_b;
    reg signed [27:0] mul_p_r;

    reg signed [11:0] dx0_r, dy_r;

    // 8-deep wrapping stack
    reg [18:0] stack [0:7];
    reg  [2:0] sp;

    // Window test, evaluated for whichever x the pixel about to be emitted
    // carries: span_x for FILL, issue_x for a textured pixel in flight.
    wire win_hit_span = (span_x  >= win_start) && (span_x  <= win_end);
    wire win_hit_iss  = (issue_x >= win_start) && (issue_x <= win_end);
    wire win_ok_span  = !win_en || (win_hit_span ^ win_out);
    wire win_ok_iss   = !win_en || (win_hit_iss  ^ win_out);

    wire [10:0] blit_dim = 11'd8 << cmd_size;
    wire  [5:0] tile_dim = tile_s ? 6'd16 : 6'd8;
    wire [10:0] play_dim = 11'd128 << pfs;

    // A BLITLIST descriptor's y and size are complete once its SECOND half is
    // on the bus: insn[27:16] takes fetch_data[11:0], so cmd_y is
    // {fetch_data[3:0], insn[15:10]} and cmd_size is fetch_data[9:7]. Testing
    // the scanline here, rather than waiting for S_BLD1, lets a sprite that
    // does not touch this line skip its d1 fetch entirely -- half the
    // descriptor traffic. insn[31:16] is still being registered this cycle,
    // hence reading fetch_data directly rather than the decode wires.
    wire  [9:0] bl_y     = {fetch_data[3:0], insn[15:10]};
    wire [10:0] bl_dim   = 11'd8 << fetch_data[9:7];
    wire signed [11:0] bl_dv = $signed({3'b000, raster_y}) - $signed({2'b00, bl_y});
    wire        bl_onscreen = (bl_dv >= 0) && (bl_dv < $signed({1'b0, bl_dim}));

    wire signed [11:0] dv_blit =
        $signed({3'b000, raster_y}) - $signed({2'b00, cmd_y});
    wire blit_hits = (dv_blit >= 0) && (dv_blit < $signed({1'b0, blit_dim}));

    // Effective texture coordinates for this pixel.
    wire [9:0] eff_u = is_affine ? acc_u[17:8] : cur_u;
    wire [9:0] eff_v = is_affine ? acc_v[17:8] : cur_v;

    // ABLIT rejects by texture bounds, and the test must see the FULL
    // accumulator: the [17:8] slice aliases negative/too-large values into
    // range. [21:8] >= blit_dim catches both in one unsigned compare. ATILE
    // is exempt -- it wraps on the playfield instead of rejecting.
    wire aff_u_ok = acc_u[21:8] < {3'b000, blit_dim};
    wire aff_v_ok = acc_v[21:8] < {3'b000, blit_dim};
    wire aff_skip = (opcode == `PPU_OP_ABLIT) && !(aff_u_ok && aff_v_ok);

    // Tile geometry. tsh is log2(tile size): 3 for 8x8, 4 for 16x16.
    wire [2:0] tsh = tile_s ? 3'd4 : 3'd3;
    wire [3:0] tu_r = tile_s ? eff_u[3:0] : {1'b0, eff_u[2:0]};  // u within the tile
    wire [3:0] tv_r = tile_s ? eff_v[3:0] : {1'b0, eff_v[2:0]};  // v within the tile
    wire [3:0] tmask = tile_s ? 4'hF : 4'h7;                     // tdim - 1
    wire [3:0] tu  = tile_hf ? (tmask - tu_r) : tu_r;
    wire [3:0] tv  = tile_vf ? (tmask - tv_r) : tv_r;

    // Byte offset of the texel within its image, before format scaling. A
    // tile index costs tdim*tdim texels, hence the 2*tsh shift into the
    // tileset.
    //
    // Power-of-two multiplies are written as shifts: yosys cannot trace the
    // operand back through a shift to prove it a power of two and builds a
    // real multiplier otherwise. The shift form is bit-identical.
    //
    // Shift amounts self-determine width, so the wider forms prevent wrap:
    // {tsh, 1'b0} is tsh*2 at 4 bits (tsh+tsh wraps for 16x16 tiles), and
    // cmd_size + 4'd3 keeps the sum 4 bits (3'd3 wraps for cmd_size >= 5).
    wire [19:0] tex_off = is_tile
        ? (({12'd0, tile_idx} << {tsh, 1'b0}) + ({16'd0, tv} << tsh) + {16'd0, tu})
        : ({10'd0, eff_v} << (cmd_size + 4'd3)) + {10'd0, eff_u};

    // One adder with a muxed pre-scaled offset: the sharing is done in the
    // source rather than left to the optimiser.
    wire [18:0] tex_scaled =
        (img_fmt == `PPU_FMT_ARGB1555) ? {tex_off[17:0], 1'b0} :
        (img_fmt == `PPU_FMT_P8)       ? tex_off[18:0] :
        (img_fmt == `PPU_FMT_P4)       ? {1'b0, tex_off[18:1]} :
                                         {3'b0, tex_off[18:3]};
    wire [18:0] tex_addr = img_base + tex_scaled;

    // ATILE wraps u/v mod play_dim BEFORE the tilemap lookup. play_dim is a
    // power of two, so the wrap is a mask on the tile row/column only; the
    // intra-tile bits below tsh are untouched. TILE's cur_u/cur_v arrive
    // pre-wrapped from S_SPAN, so the mask is applied unconditionally.
    // play_dim-1 in 10 bits: for play_dim = 1024 the truncation-then-
    // decrement wraps 0 - 1 to 1023, exactly the mask wanted.
    wire [9:0] play_mask = play_dim[9:0] - 10'd1;
    wire [9:0] tile_col = (eff_u & play_mask) >> tsh;
    wire [9:0] tile_row = (eff_v & play_mask) >> tsh;
    // map_w = (128 << pfs) >> tsh is a power of two, so tile_row * map_w is
    // tile_row << (7 + pfs - tsh) -- see the multiplier note above tex_off.
    wire [3:0] map_sh   = 4'd7 + {2'b00, pfs} - {1'b0, tsh};
    wire [18:0] idx_ent = ({9'd0, tile_row} << map_sh) + {9'd0, tile_col};
    wire [18:0] idx_addr = tmap_base + (tmap_wide ? {idx_ent[17:0], 1'b0} : idx_ent);

    // Next pixel's tile coordinates for a non-affine TILE, so S_SPAN can go
    // straight to S_TEX0 when the walk stays inside the current tile and skip
    // the S_IDX0 compare cycle as well as the fetch. Only the tile row/column
    // are compared -- no second address adder on this path. ATILE is excluded:
    // its step is arbitrary, so it always takes the S_IDX0 route, where the
    // address compare still catches the common in-tile case.
    wire [9:0] nxt_tile_u = (span_x + cmd_x) & play_mask;
    wire [9:0] nxt_tile_v = ({1'b0, raster_y} + cmd_y) & play_mask;

    // Same quantities for span_x + 1, so S_TEX1 can retire a pixel AND set up
    // the next one in the same clock instead of returning to S_SPAN. That
    // takes a textured pixel from three states to two -- see the S_TEX1 note.
    // sx1 is one incrementer; the tile forms differ from the above only by
    // that carry, so the synthesised cost is an adder, not a second address
    // generator.
    wire [9:0] sx1  = span_x + 10'd1;
    wire [9:0] t_u1 = (sx1 + cmd_x) & play_mask;
    wire [9:0] b_u1 = sx1 - cmd_x;

    // Mirroring reflects the TEXTURE coordinate, not the screen span: the
    // sprite covers the same pixels and only the source is reversed, which is
    // what lets one stored sprite face both ways.
    wire [9:0] blit_last = blit_dim[9:0] - 10'd1;
    wire [9:0] bu_now  = cmd_hflip ? (blit_last - (span_x - cmd_x)) : (span_x - cmd_x);
    wire [9:0] bu_next = cmd_hflip ? (blit_last - b_u1)             : b_u1;
    wire [9:0] bv_now  = cmd_vflip ? (blit_last - dv_blit[9:0])     : dv_blit[9:0];

    // Does the held tile index belong to the pixel about to be issued? Tested
    // on the generated address, so it is correct for ATILE's arbitrary step
    // as well as TILE's linear one.
    wire idx_hit = idx_valid && (idx_addr == idx_addr_q);

    wire [3:0] tex_sub = (img_fmt == `PPU_FMT_P8) ? {3'd0, tex_off[0]}
                       : (img_fmt == `PPU_FMT_P4) ? {2'd0, tex_off[1:0]}
                       : (img_fmt == `PPU_FMT_P1) ? tex_off[3:0]
                                                  : 4'd0;

    // Operand steering for the four span-start products: product k is
    // selected in cycle k and lands in mul_p_r for use in cycle k+1.
    always @* begin
        case (mul_step[1:0])
        2'd0:    begin mul_a = a00; mul_b = dx0_r; end
        2'd1:    begin mul_a = a01; mul_b = dy_r;  end
        2'd2:    begin mul_a = a10; mul_b = dx0_r; end
        default: begin mul_a = a11; mul_b = dy_r;  end
        endcase
    end

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            pc          <= 19'd0;
            pc_base     <= 19'd0;
            sp          <= 3'd0;
            clip_start  <= 10'd0;
            win_start   <= 10'd0;
            win_end     <= 10'd0;
            win_en      <= 1'b0;
            win_out     <= 1'b0;
            clip_end    <= (`PPU_INT_W - 1);
            blend_mode  <= `PPU_BL_OPAQUE;
            blend_alpha <= 5'd31;
            blend_prio  <= 1'b1;
            halted      <= 1'b0;
            line_done   <= 1'b0;
            px_valid    <= 1'b0;
            fetch_req   <= 1'b0;
            fetch_addr  <= 19'd0;
            fetch_stream<= `PPU_STREAM_INDEX;
            pram_we     <= 1'b0;
            bl_active   <= 1'b0;
            bl_word     <= 2'd0;
            idx_addr_q  <= 19'd0;
            idx_valid   <= 1'b0;
            tile_hf     <= 1'b0;
            tile_vf     <= 1'b0;
            tile_poff   <= 3'd0;
            issue_x     <= 10'd0;
            issue_sub   <= 4'd0;
            for (i = 0; i < 8; i = i + 1) stack[i] <= 19'd0;
        end else if (pc_load) begin
            pc        <= pc_in;
            pc_base   <= pc_in;
            halted    <= 1'b0;
            state     <= S_IDLE;
            fetch_req <= 1'b0;
            px_valid  <= 1'b0;
        end else begin
            px_valid  <= 1'b0;
            pram_we   <= 1'b0;
            line_done <= 1'b0;

            case (state)

            S_IDLE: if (enable && line_start && !halted) begin
                if (frame_restart)
                    pc <= pc_base;
                state <= S_IF0;
            end

            // A 32-bit word is two beats on the 16-bit bus. Each fetch state
            // asserts req on entry and drops it on ack, so req is low for at
            // least one cycle between beats and beat N's ack cannot be
            // latched as beat N+1.
            S_IF0: if (!fetch_req) begin
                fetch_addr   <= pc;
                fetch_stream <= `PPU_STREAM_INDEX;
                fetch_req    <= 1'b1;
            end else if (fetch_ack) begin
                insn[15:0] <= fetch_data;
                fetch_req  <= 1'b0;
                state      <= S_IF1;
            end

            S_IF1: if (!fetch_req) begin
                fetch_addr   <= pc + 19'd2;
                fetch_stream <= `PPU_STREAM_INDEX;
                fetch_req    <= 1'b1;
            end else if (fetch_ack) begin
                insn[31:16] <= fetch_data;
                pc          <= pc + 19'd4;
                fetch_req   <= 1'b0;
                state       <= S_DEC;
            end

            S_DEC: begin
                arg_idx <= 3'd0;

                case (opcode)
                // SYNC presents the buffer and waits -- it does NOT rewind.
                // The display list is a per-frame program: the PC flows on,
                // a per-scanline loop closes itself with PUSH/POPJ, and the
                // vector is reloaded once per frame (frame_restart).
                `PPU_OP_SYNC: begin
                    line_done <= 1'b1;
                    state     <= S_IDLE;
                end

                `PPU_OP_CLIP: begin
                    clip_start <= insn[9:0];
                    clip_end   <= insn[19:10];
                    state      <= S_NEXT;
                end

                `PPU_OP_WIN: begin
                    win_start <= insn[9:0];
                    win_end   <= insn[19:10];
                    win_en    <= insn[20];
                    win_out   <= insn[21];
                    state     <= S_NEXT;
                end

                `PPU_OP_BLEND: begin
                    blend_mode  <= insn[2:0];
                    blend_alpha <= insn[7:3];
                    // Bit 8 SET marks following pixels as yielding, so a
                    // plain BLEND -- bit clear -- keeps the normal level and
                    // behaves exactly as it did before priority existed.
                    blend_prio  <= ~insn[8];
                    state       <= S_NEXT;
                end

                `PPU_OP_PALW: begin
                    pram_we    <= 1'b1;
                    pram_addr  <= insn[23:16];
                    pram_wdata <= insn[15:0];
                    state      <= S_NEXT;
                end

                `PPU_OP_FILL: begin
                    span_x   <= clip_start;
                    span_end <= clip_end;
                    state    <= S_SPAN;
                end

                `PPU_OP_POPJ: begin
                    sp <= sp - 3'd1;
                    if (insn[24:23] == 2'd0
                        || (insn[24:23] == 2'd1 && {1'b0, raster_y} <  insn[9:0])
                        || (insn[24:23] == 2'd2 && {1'b0, raster_y} >= insn[9:0]))
                        pc <= stack[sp - 3'd1];
                    state <= S_NEXT;
                end

                // Argument word counts per opcode.
                `PPU_OP_PUSH:     begin args_left <= 3'd1; state <= S_ARG0; end
                `PPU_OP_BLIT:     begin args_left <= 3'd1; state <= S_ARG0; end
                // BLITLIST carries no argument words: count and pointer live
                // in the instruction itself.
                `PPU_OP_BLITLIST: begin
                    bl_count  <= insn[27:20];
                    bl_ptr    <= insn[16:0];
                    bl_active <= insn[27:20] != 8'd0;
                    bl_word   <= 2'd0;
                    state     <= (insn[27:20] == 8'd0) ? S_NEXT : S_BLD0;
                end
                `PPU_OP_TILE:     begin args_left <= 3'd2; state <= S_ARG0; end
                `PPU_OP_ABLIT:    begin args_left <= 3'd4; state <= S_ARG0; end
                `PPU_OP_ATILE:    begin args_left <= 3'd5; state <= S_ARG0; end

                default: state <= S_HALT;
                endcase
            end

            S_ARG0: if (!fetch_req) begin
                fetch_addr   <= pc;
                fetch_stream <= `PPU_STREAM_INDEX;
                fetch_req    <= 1'b1;
            end else if (fetch_ack) begin
                arg_data  <= fetch_data;
                fetch_req <= 1'b0;
                state     <= S_ARG1;
            end

            S_ARG1: begin
                argw <= {arg_data, argw[31:16]};
                if (pc[1]) begin                     // second half of a 32-bit arg
                    case (arg_idx)
                    // Pointer argument order is the ISA's: TILE is
                    // (tilemap|pfs, tileset|fmt), ATILE is (b, a, a,
                    // tilemap|pfs, tileset|fmt), BLIT/ABLIT one (image|fmt).
                    3'd0: if (opcode == `PPU_OP_PUSH) begin
                              stack[sp] <= {arg_data[2:0], argw[31:16]};
                              sp        <= sp + 3'd1;
                          end else if (is_affine) begin
                              b0 <= argw[31:16];  b1 <= arg_data;
                          end else if (is_tile) begin
                              tmap_base <= {arg_data[2:0], argw[31:18], 2'b00};
                              pfs       <= argw[17:16];
                          end else begin
                              img_base <= {arg_data[2:0], argw[31:18], 2'b00};
                              img_fmt  <= argw[17:16];
                          end
                    3'd1: if (is_affine) begin a00 <= argw[31:16]; a01 <= arg_data; end
                          else begin img_base <= {arg_data[2:0], argw[31:18], 2'b00};
                                     img_fmt  <= argw[17:16]; end
                    3'd2: if (is_affine) begin a10 <= argw[31:16]; a11 <= arg_data; end
                          else begin img_base <= {arg_data[2:0], argw[31:18], 2'b00};
                                     img_fmt  <= argw[17:16]; end
                    3'd3: if (is_tile) begin       // ATILE: tilemap first
                              tmap_base <= {arg_data[2:0], argw[31:18], 2'b00};
                              pfs       <= argw[17:16];
                          end else begin           // ABLIT: its only pointer
                              img_base  <= {arg_data[2:0], argw[31:18], 2'b00};
                              img_fmt   <= argw[17:16];
                          end
                    default: begin img_base <= {arg_data[2:0], argw[31:18], 2'b00};
                                   img_fmt  <= argw[17:16]; end
                    endcase
                    arg_idx <= arg_idx + 3'd1;
                end
                // pc IS the argument cursor: it left S_IF1 pointing at the
                // first argument and steps one beat here, so when the last
                // argument lands it is already the next instruction's address.
                pc <= pc + 19'd2;

                if ((arg_idx + 3'd1 == args_left) && pc[1]) begin
                    fetch_req <= 1'b0;
                    // Span setup. Affine and tile commands cover the whole
                    // clip region; BLIT covers its own square and drops out
                    // if this scanline misses it.
                    span_x   <= is_affine ? clip_start
                              : is_tile   ? clip_start
                              : (cmd_x > clip_start ? cmd_x : clip_start);
                    span_end <= (is_affine || is_tile) ? clip_end
                              : ((cmd_x + blit_dim[9:0] - 10'd1) < clip_end
                                  ? (cmd_x + blit_dim[9:0] - 10'd1) : clip_end);
                    cur_u    <= 10'd0;
                    cur_v    <= 10'd0;
                    mul_step <= 3'd0;
                    dy_r     <= $signed({3'b000, raster_y}) - $signed({2'b00, cmd_y});
                    dx0_r    <= $signed({2'b00, clip_start}) - $signed({2'b00, cmd_x});
                    state    <= (opcode == `PPU_OP_PUSH) ? S_NEXT
                              : (opcode == `PPU_OP_BLIT && !blit_hits) ? S_NEXT
                              : is_affine ? S_AFF : S_SPAN;
                end else begin
                    state <= S_ARG0;
                end
            end

            // Four sequenced multiply-accumulates, one cycle behind the
            // operand steering: cycle 0 only starts the first product,
            // cycles 1..4 fold the registered products in.
            S_AFF: begin
                mul_step <= mul_step + 3'd1;
                mul_p_r  <= mul_p;
                case (mul_step)
                3'd1: begin acc_u <= $signed({{4{b0[15]}}, b0, 2'b00}) + mul_p_r[21:0]; end
                3'd2: begin acc_u <= acc_u + mul_p_r[21:0]; end
                3'd3: begin acc_v <= $signed({{4{b1[15]}}, b1, 2'b00}) + mul_p_r[21:0]; end
                3'd4: begin acc_v <= acc_v + mul_p_r[21:0]; state <= S_SPAN; end
                default: ;
                endcase
            end

            S_SPAN: begin
                if (span_x > span_end) begin
                    state <= S_NEXT;
                end else if (opcode == `PPU_OP_FILL) begin
                    px_valid  <= win_ok_span;
                    px_x      <= span_x;
                    px_word   <= fill_col;
                    px_direct <= 1'b1;
                    px_mode   <= blend_mode;
                    px_alpha  <= blend_alpha;
                    px_prio   <= blend_prio;
                    span_x    <= span_x + 10'd1;
                end else begin
                    // BLIT walks the texture relative to its own origin;
                    // TILE is scroll-relative and wraps on the playfield.
                    if (!is_affine) begin
                        if (is_tile) begin
                            cur_u <= nxt_tile_u;
                            cur_v <= nxt_tile_v;
                        end else begin
                            cur_u <= bu_now;
                            cur_v <= bv_now;
                        end
                    end
                    state <= is_tile ? S_IDX0 : S_TEX0;
                end
            end

            // Tile index fetch, skipped while the address is unchanged --
            // see the idx_addr_q declaration.
            S_IDX0: if (idx_valid && (idx_addr == idx_addr_q)) begin
                state        <= S_TEX0;         // tile_idx still valid
            end else begin
                fetch_addr   <= idx_addr;
                fetch_stream <= `PPU_STREAM_INDEX;
                fetch_req    <= 1'b1;
                idx_addr_q   <= idx_addr;
                idx_valid    <= 1'b1;
                state        <= S_IDX1;
            end

            S_IDX1: if (fetch_ack) begin
                if (tmap_wide) begin
                    tile_idx  <= fetch_data[7:0];
                    tile_hf   <= fetch_data[8];
                    tile_vf   <= fetch_data[9];
                    tile_poff <= fetch_data[12:10];
                end else begin
                    tile_idx  <= idx_addr[0] ? fetch_data[15:8] : fetch_data[7:0];
                    tile_hf   <= 1'b0;
                    tile_vf   <= 1'b0;
                    tile_poff <= img_poff;
                end
                fetch_req <= 1'b0;
                state     <= S_TEX0;
            end

            S_TEX0: if (aff_skip) begin
                // Out-of-range affine sample: no fetch, no pixel; step and
                // continue. The test lives HERE, not in S_SPAN, to keep the
                // compare out of the multiplier cone -- on entry to S_TEX0
                // the accumulators have been stable since the previous
                // S_TEX1 edge.
                //
                // Staying in S_TEX0 rather than going back through S_SPAN
                // halves the cost of a rejected affine sample, from two clocks
                // to one. An affine op walks its whole clipped span every
                // scanline and rejects most of it, so this is the dominant
                // term in ABLIT/ATILE. The accumulators are non-blocking, so
                // next clock aff_skip and tex_addr already see the new sample.
                span_x <= sx1;
                acc_u  <= acc_u + {{6{a00[15]}}, a00};
                acc_v  <= acc_v + {{6{a10[15]}}, a10};
                state  <= (sx1 > span_end) ? S_NEXT : S_TEX0;
            end else begin
                // Issue: request this pixel's texel and step every coordinate
                // on, so cur_u/acc/span_x describe the NEXT pixel while this
                // one is in flight. issue_x/issue_sub carry the in-flight
                // pixel's identity forward to S_TEX1.
                fetch_addr   <= tex_addr;
                fetch_stream <= `PPU_STREAM_TEXEL;
                fetch_req    <= 1'b1;
                issue_x      <= span_x;
                issue_sub    <= tex_sub;
                span_x       <= sx1;
                if (is_affine) begin
                    acc_u <= acc_u + {{6{a00[15]}}, a00};
                    acc_v <= acc_v + {{6{a10[15]}}, a10};
                end else if (is_tile) begin
                    cur_u <= t_u1;
                    cur_v <= nxt_tile_v;
                end else begin
                    cur_u <= bu_next;
                    cur_v <= bv_now;
                end
                state <= S_TEX1;
            end

            // Retire the in-flight pixel and, where nothing gets in the
            // way, issue the next in the SAME clock -- one pixel per clock
            // rather than a request state plus a wait state. This only works
            // because ppu_top no longer re-requests the old address on the
            // ack cycle; that duplicate reply used to be indistinguishable
            // from the next pixel's data.
            //
            // Three cases break the stream, each costing a refill:
            //   * end of span      -- nothing left to issue, drain and finish
            //   * a new tile index -- S_IDX0 must fetch it before the texel
            //   * affine           -- aff_skip is re-tested per sample, and
            //                         that test lives in S_TEX0 to stay out
            //                         of the multiplier cone. An ATILE goes
            //                         via S_IDX0, not straight to S_TEX0:
            //                         an affine step can cross a tile, and
            //                         skipping the index check there renders
            //                         the whole playfield from a stale index.
            S_TEX1: if (fetch_ack) begin
                px_valid  <= win_ok_iss;
                px_x      <= issue_x;
                px_word   <= fetch_data;
                px_fmt    <= img_fmt;
                px_sub    <= issue_sub;
                px_poff   <= is_tile ? tile_poff : img_poff;
                px_direct <= 1'b0;
                px_mode   <= blend_mode;
                px_alpha  <= blend_alpha;
                px_prio   <= blend_prio;

                if (span_x > span_end) begin
                    fetch_req <= 1'b0;
                    state     <= S_NEXT;
                end else if (is_affine) begin
                    fetch_req <= 1'b0;
                    state     <= is_tile ? S_IDX0 : S_TEX0;
                end else if (is_tile && !idx_hit) begin
                    fetch_req <= 1'b0;
                    state     <= S_IDX0;
                end else begin
                    fetch_addr   <= tex_addr;
                    fetch_stream <= `PPU_STREAM_TEXEL;
                    fetch_req    <= 1'b1;
                    issue_x      <= span_x;
                    issue_sub    <= tex_sub;
                    span_x       <= sx1;
                    if (is_tile) begin
                        cur_u <= t_u1;
                        cur_v <= nxt_tile_v;
                    end else begin
                        cur_u <= bu_next;
                        cur_v <= bv_now;
                    end
                    state <= S_TEX1;
                end
            end

            S_NEXT: begin
                fetch_req <= 1'b0;
                idx_valid <= 1'b0;          // new instruction, new tilemap
                if (bl_active && bl_count != 8'd0) begin
                    state <= S_BLD0;            // next descriptor in the list
                end else begin
                    bl_active <= 1'b0;
                    state     <= S_IF0;
                end
            end

            // Descriptor fetch: four 16-bit halves of (d0, d1).
            S_BLD0: if (!fetch_req) begin
                fetch_addr   <= {bl_ptr, 2'b00} + {16'd0, bl_word, 1'b0};
                fetch_stream <= `PPU_STREAM_INDEX;
                fetch_req    <= 1'b1;
            end else if (fetch_ack) begin
                fetch_req <= 1'b0;
                case (bl_word)
                2'd0: insn[15:0]  <= fetch_data;
                // d0 high half, re-badged with the BLIT opcode: the
                // x/y/poff/size fields sit at the same bits as in a BLIT.
                2'd1: insn[31:16] <= {`PPU_OP_BLIT, fetch_data[11:0]};
                2'd2: argw[31:16] <= fetch_data;          // d1 low, stashed
                2'd3: begin                               // d1 high: image ptr
                    img_base <= {fetch_data[2:0], argw[31:18], 2'b00};
                    img_fmt  <= argw[17:16];
                end
                endcase
                if (bl_word == 2'd3) begin
                    bl_word  <= 2'd0;
                    bl_ptr   <= bl_ptr + 17'd2;
                    bl_count <= bl_count - 8'd1;
                    state    <= S_BLD1;
                end else if (bl_word == 2'd1 && !bl_onscreen) begin
                    // Misses this scanline: d1 is only the image pointer and
                    // format, which nothing will read, so retire the
                    // descriptor now and skip its two remaining fetches.
                    bl_word  <= 2'd0;
                    bl_ptr   <= bl_ptr + 17'd2;
                    bl_count <= bl_count - 8'd1;
                    state    <= S_NEXT;
                end else begin
                    bl_word <= bl_word + 2'd1;
                end
            end

            // One settle cycle so the decode wires read the synthetic BLIT;
            // the span setup below matches S_ARG1's BLIT tail.
            S_BLD1: begin
                span_x   <= (cmd_x > clip_start) ? cmd_x : clip_start;
                span_end <= ((cmd_x + blit_dim[9:0] - 10'd1) < clip_end)
                          ? (cmd_x + blit_dim[9:0] - 10'd1) : clip_end;
                cur_u    <= 10'd0;
                cur_v    <= 10'd0;
                state    <= blit_hits ? S_SPAN : S_NEXT;
            end

            S_HALT: halted <= 1'b1;

            default: state <= S_IDLE;
            endcase
        end
    end

endmodule
