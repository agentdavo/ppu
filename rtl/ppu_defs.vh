// PPU shared definitions. Normative source is model/ppu_model.py; if the two
// disagree, the model is right.

`ifndef PPU_DEFS_VH
`define PPU_DEFS_VH

`define PPU_INT_W        320
`define PPU_INT_H        240
`define PPU_XW            10   // 0..1023 u/v and x coordinates
`define PPU_PIX_DIV        1   // core cycles per pixel

// 640x480@60, VESA DMT, run from a 25.000 MHz clock (59.524 Hz, 0.7% low).
// Core and pixel are the same clock: no clock crossing anywhere. Sync
// polarity for this mode is negative on both; DISP_CFG resets accordingly.
`define PPU_H_ACTIVE     640
`define PPU_H_FRONT       16
`define PPU_H_SYNC        96
`define PPU_H_BACK        48
`define PPU_H_TOTAL      800
`define PPU_V_ACTIVE     480
`define PPU_V_FRONT       10
`define PPU_V_SYNC         2
`define PPU_V_BACK        33
`define PPU_V_TOTAL      525

// Opcodes
`define PPU_OP_SYNC      4'h0
`define PPU_OP_CLIP      4'h1
`define PPU_OP_FILL      4'h2
`define PPU_OP_BLEND     4'h3
`define PPU_OP_BLIT      4'h4
`define PPU_OP_TILE      4'h5
`define PPU_OP_ABLIT     4'h6
`define PPU_OP_ATILE     4'h7
`define PPU_OP_PALW      4'h8
`define PPU_OP_BLITLIST  4'h9
// Second clip window. CLIP bounds the span itself; this one masks pixels
// inside the span, so it can cut a hole rather than only shorten the ends.
`define PPU_OP_WIN       4'hA
`define PPU_OP_PUSH      4'hE
`define PPU_OP_POPJ      4'hF

// Blend modes
`define PPU_BL_OPAQUE    3'd0
`define PPU_BL_ALPHA     3'd1
`define PPU_BL_ADD       3'd2
`define PPU_BL_SUB       3'd3
`define PPU_BL_MUL       3'd4

// Source pixel formats
`define PPU_FMT_ARGB1555 2'd0
`define PPU_FMT_P8       2'd1
`define PPU_FMT_P4       2'd2
`define PPU_FMT_P1       2'd3

// Linear-framebuffer source formats (FB_CTRL.FMT); the subset of the
// kernel's SIMPLEFB_FORMATS this hardware carries.
`define PPU_FB_A1R5G5B5  3'd0   // DRM_FORMAT_ARGB1555 -- native
`define PPU_FB_X1R5G5B5  3'd1   // DRM_FORMAT_XRGB1555 -- identical in hardware
`define PPU_FB_R5G6B5    3'd2   // DRM_FORMAT_RGB565
`define PPU_FB_X8R8G8B8  3'd3   // DRM_FORMAT_XRGB8888 -- 2 beats/px, 8->5 trunc
`define PPU_FB_R5G5B5A1  3'd4   // DRM_FORMAT_RGBA5551

// Reset geometry of the framebuffer engine; a simple-framebuffer devicetree
// node must repeat these numbers.
`define PPU_FB_RST_W     `PPU_INT_W
`define PPU_FB_RST_H     `PPU_INT_H
`define PPU_FB_RST_STRIDE (`PPU_INT_W * 2)

// Fetch stream tags. Streams must not share a cache instance.
`define PPU_STREAM_TEXEL 1'b0
`define PPU_STREAM_INDEX 1'b1

`endif
