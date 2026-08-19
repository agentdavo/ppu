// Blend unit: one ARGB1555 pixel per cycle, combinational.
// One signed 6x6 multiplier per channel covers all modes; the modes need
// three different products but never in the same cycle.

`include "ppu_defs.vh"

module ppu_blend (
    input  wire [15:0] src,        // ARGB1555 from palette / unpacker
    input  wire [15:0] dst,        // ARGB1555 currently in the scanbuf
    input  wire  [2:0] mode,
    input  wire  [4:0] alpha,      // per-command opacity
    input  wire        prio,       // 1 = normal, 0 = yields to a priority-1 pixel
    output wire [15:0] blended,
    output wire        wr_en       // low when the pixel is transparent
);

    wire       src_a = src[15];
    wire [4:0] src_r = src[14:10], src_g = src[9:5], src_b = src[4:0];
    wire [4:0] dst_r = dst[14:10], dst_g = dst[9:5], dst_b = dst[4:0];

    // A clear per-pixel A bit suppresses the write in every mode, so the
    // scanbuf can skip the read-modify-write entirely.
    //
    // Bit 15 of a STORED pixel carries its priority. Scanout reads only
    // [14:0], so the bit costs nothing, and it has always been 1 for a written
    // pixel -- which is the normal level, so ordinary content is unaffected.
    // A source marked prio=0 yields: it will not overwrite a pixel already at
    // priority 1. That is the one ordering painter's order cannot express, a
    // span drawn later that must sit behind something drawn earlier.
    assign wr_en = src_a && !(dst[15] && !prio);

    wire opaque = (mode == `PPU_BL_OPAQUE) || (mode > `PPU_BL_MUL);

    wire [4:0] out_r, out_g, out_b;
    ppu_blend_ch ch_r (.src(src_r), .dst(dst_r), .mode(mode), .alpha(alpha), .out(out_r));
    ppu_blend_ch ch_g (.src(src_g), .dst(dst_g), .mode(mode), .alpha(alpha), .out(out_g));
    ppu_blend_ch ch_b (.src(src_b), .dst(dst_b), .mode(mode), .alpha(alpha), .out(out_b));

    assign blended = opaque ? {prio, src[14:0]} : {prio, out_r, out_g, out_b};

endmodule


module ppu_blend_ch (
    input  wire [4:0] src,
    input  wire [4:0] dst,
    input  wire [2:0] mode,
    input  wire [4:0] alpha,
    output reg  [4:0] out
);

    wire is_alpha = (mode == `PPU_BL_ALPHA);
    wire is_mul   = (mode == `PPU_BL_MUL);

    // Shared multiplier: alpha uses a*(src-dst) (B signed), add/sub a*src,
    // mul src*dst. alpha form equals (src*a + dst*(32-a))>>5 exactly.
    wire signed [6:0] mul_a = is_mul ? $signed({2'b00, src}) : $signed({2'b00, alpha});
    wire signed [6:0] mul_b = is_alpha ? ($signed({2'b00, src}) - $signed({2'b00, dst}))
                            : is_mul   ? $signed({2'b00, dst})
                                       : $signed({2'b00, src});
    wire signed [13:0] prod = mul_a * mul_b;

    wire signed [8:0] shifted = prod[13:5];              // arithmetic >>> 5
    wire signed [6:0] sum_add = $signed({2'b00, dst}) + $signed(shifted[6:0]);
    wire signed [6:0] sum_sub = $signed({2'b00, dst}) - $signed(shifted[6:0]);

    // x/31 by shift-add so 31*31 -> 31, not the 30 a plain >>5 would give.
    wire [10:0] mul_num = prod[10:0] + {5'd0, prod[10:5]} + 11'd16;

    always @* begin
        case (mode)
            `PPU_BL_ALPHA: out = sum_add[4:0];           // 0..31, cannot overflow
            `PPU_BL_ADD:   out = sum_add[6] ? 5'd0  : (|sum_add[5:5] ? 5'd31 : sum_add[4:0]);
            `PPU_BL_SUB:   out = sum_sub[6] ? 5'd0  : (|sum_sub[5:5] ? 5'd31 : sum_sub[4:0]);
            `PPU_BL_MUL:   out = mul_num[9:5];
            default:       out = src;
        endcase
    end

endmodule
