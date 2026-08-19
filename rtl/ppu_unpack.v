// Source-format unpacker: one 16-bit bus word plus a sub-index -> one pixel.
// Single shared instance for every format and command.
// Sub-byte formats are little-endian within the byte: the least-significant
// field is the first pixel displayed.

`include "ppu_defs.vh"

module ppu_unpack (
    input  wire [15:0] word,        // raw bus word
    input  wire  [1:0] fmt,
    input  wire  [3:0] sub,         // which pixel within the word
    input  wire  [2:0] poff,        // palette offset, in 32-entry banks
    output reg   [7:0] pal_index,
    output wire [15:0] direct,      // valid when fmt == ARGB1555
    output wire        is_direct
);

    assign direct    = word;
    assign is_direct = (fmt == `PPU_FMT_ARGB1555);

    reg [7:0] raw;
    always @* begin
        case (fmt)
            `PPU_FMT_P8:  raw = sub[0] ? word[15:8] : word[7:0];
            `PPU_FMT_P4:  case (sub[1:0])
                              2'd0: raw = {4'd0, word[3:0]};
                              2'd1: raw = {4'd0, word[7:4]};
                              2'd2: raw = {4'd0, word[11:8]};
                              default: raw = {4'd0, word[15:12]};
                          endcase
            `PPU_FMT_P1:  raw = {7'd0, word[sub]};
            default:      raw = 8'd0;
        endcase
        // poff << 5, wrapping on overflow: eight 32-entry sub-palettes.
        pal_index = raw + {poff, 5'd0};
    end

endmodule
