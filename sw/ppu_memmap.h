// SPDX-License-Identifier: Apache-2.0
//
// ppu_memmap.h -- register map for the PPU (pixel processing unit) macro.
//
// Offsets, reset values and bit positions here are transcribed from the RTL
// register file (rtl/ppu_csr.v); the instruction encodings and pixel formats
// come from rtl/ppu_defs.vh, whose normative source is model/ppu_model.py.
// If this header and the hardware disagree, the hardware is right.
//
// This file describes the PPU block only. It deliberately carries no SoC slot
// map, no system RAM layout and no board-specific framebuffer geometry --
// define PPU0_BASE for your integration before including it.
//
#pragma once

#if defined(PPU_FREESTANDING)
/* Minimal types for -nostdinc freestanding builds (e.g. transputer-tcc). */
typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long      uintptr_t;
typedef int                int32_t;
#else
#include <stdint.h>
#endif

/* ------------------------------------------------------------------------
 * Base address
 *
 * The CSR file occupies 4 KiB of APB3 space. The address below is only the
 * default used by the reference SoC integration; override it to match your
 * own address decode.
 * --------------------------------------------------------------------- */
#ifndef PPU0_BASE
#define PPU0_BASE            0x10001000u
#endif

/* ------------------------------------------------------------------------
 * Register offsets (byte offsets from PPU0_BASE; all accesses are 32-bit)
 * --------------------------------------------------------------------- */
#define PPU_CTRL             0x00u  /* RW  control                          */
#define PPU_STATUS           0x04u  /* RO  status                           */
#define PPU_PC               0x08u  /* RW  display-list program counter     */
#define PPU_IRQ_EN           0x0Cu  /* RW  interrupt enables                */
#define PPU_IRQ_ST           0x10u  /* W1C latched interrupt status         */
#define PPU_DISP_CFG         0x14u  /* RW  display output configuration     */
#define PPU_PRAM_ADDR        0x18u  /* RW  palette RAM index                */
#define PPU_PRAM_DATA        0x1Cu  /* RW  palette RAM data window          */
#define PPU_BUS_STAT         0x20u  /* RW  fetch instrumentation (W clears) */
#define PPU_MEM_ADDR         0x24u  /* RW  host keyhole address             */
#define PPU_MEM_DATA         0x28u  /* RW  host keyhole data window         */
#define PPU_FB_CTRL          0x2Cu  /* RW  framebuffer engine control       */
#define PPU_FB_BASE          0x30u  /* RW  framebuffer physical base        */
#define PPU_FB_STRIDE        0x34u  /* RW  framebuffer line stride (bytes)  */
#define PPU_FB_SIZE          0x38u  /* RW  framebuffer active geometry      */
#define PPU_CRT_H1           0x3Cu  /* RW  CRTC horizontal total / active   */
#define PPU_CRT_H2           0x40u  /* RW  CRTC hsync start / end           */
#define PPU_CRT_H3           0x44u  /* RW  CRTC horizontal blank boundary   */
#define PPU_CRT_V1           0x48u  /* RW  CRTC vertical total / active     */
#define PPU_CRT_V2           0x4Cu  /* RW  CRTC vsync start / end           */
#define PPU_CRT_LN           0x50u  /* RW  CRTC line prep / render limit    */
#define PPU_CRT_MD           0x54u  /* RW  CRTC mode and internal width     */
#define PPU_FRAME            0x58u  /* RO  frame counter, flip pending      */

/* ------------------------------------------------------------------------
 * CTRL (0x00) -- reset 0x0000_0000
 * SOFT_RST is self-clearing; it reads back as 0.
 * --------------------------------------------------------------------- */
#define PPU_CTRL_ENABLE      (1u << 0)
#define PPU_CTRL_SOFT_RST    (1u << 1)
#define PPU_CTRL_HALT_HSYNC  (1u << 2)
#define PPU_CTRL_HALT_VSYNC  (1u << 3)

/* Legacy spelling kept for firmware written against the pre-split header. */
#define PPU_ENABLE           PPU_CTRL_ENABLE

/* ------------------------------------------------------------------------
 * STATUS (0x04) -- read-only
 * UNDERRUN is sticky; clear it by writing UNDERRUN back to IRQ_ST.
 * --------------------------------------------------------------------- */
#define PPU_ST_HALTED        (1u << 0)
#define PPU_ST_UNDERRUN      (1u << 1)
#define PPU_ST_BUSY          (1u << 2)
#define PPU_ST_FB_ACTIVE     (1u << 3)
#define PPU_ST_RENDER_Y_SHIFT  9
#define PPU_ST_RENDER_Y_MASK   0x1FFu   /* bits [17:9] */
#define PPU_ST_RENDER_Y(s)   (((s) >> PPU_ST_RENDER_Y_SHIFT) & PPU_ST_RENDER_Y_MASK)

/* ------------------------------------------------------------------------
 * IRQ_EN (0x0C) / IRQ_ST (0x10) -- reset 0x0000_0000, both 4 bits
 *
 * Sources latch on the rising edge, so write-1-to-clear works while the
 * source is still asserted. Writing bit 0 to IRQ_ST also clears the sticky
 * STATUS.UNDERRUN flag. Bit 3 is unimplemented. The interrupt line is the OR
 * of IRQ_ST & IRQ_EN.
 * --------------------------------------------------------------------- */
#define PPU_IRQ_UNDERRUN     (1u << 0)
#define PPU_IRQ_VBLANK       (1u << 1)
#define PPU_IRQ_HALT         (1u << 2)
#define PPU_IRQ_ALL          (PPU_IRQ_UNDERRUN | PPU_IRQ_VBLANK | PPU_IRQ_HALT)

/* ------------------------------------------------------------------------
 * DISP_CFG (0x14) -- reset 0x0000_0003
 *
 * Reset is 640x480@60 VESA DMT polarity: both syncs active low, output on.
 * Bit 1 is stored and reads back but drives nothing (register-map compat).
 * A polarity bit set means active low.
 * --------------------------------------------------------------------- */
#define PPU_DISP_VID_EN      (1u << 0)
#define PPU_DISP_RESERVED1   (1u << 1)
#define PPU_DISP_HSYNC_POL   (1u << 2)
#define PPU_DISP_VSYNC_POL   (1u << 3)
#define PPU_DISP_CFG_RESET   0x00000003u

/* ------------------------------------------------------------------------
 * Palette RAM (0x18 / 0x1C)
 *
 * 256 entries of ARGB1555. Write PRAM_ADDR, then read or write PRAM_DATA.
 * Reads cost one APB wait state; every CSR access steals a cycle from the
 * per-pixel lookup, so avoid touching these during active rendering.
 * --------------------------------------------------------------------- */
#define PPU_PRAM_ENTRIES     256u

/* ------------------------------------------------------------------------
 * BUS_STAT (0x20) -- render-fetch instrumentation
 *
 * Both counters saturate at 0xFFFF; any write zeroes both.
 * --------------------------------------------------------------------- */
#define PPU_BUS_FETCH(v)     ((v) & 0xFFFFu)          /* answered beats  */
#define PPU_BUS_STALL(v)     (((v) >> 16) & 0xFFFFu)  /* stalled cycles  */

/* ------------------------------------------------------------------------
 * Host keyhole (0x24 / 0x28)
 *
 * Bring-up path into external memory: set MEM_ADDR once (19-bit, byte
 * address), then stream 16-bit MEM_DATA accesses. The address auto-increments
 * by 2 per transfer. Accesses stall the APB bus until the memory arbiter
 * acknowledges.
 * --------------------------------------------------------------------- */
#define PPU_MEM_ADDR_MASK    0x0007FFFFu  /* 19 bits */
#define PPU_MEM_ADDR_STEP    2u

/* ------------------------------------------------------------------------
 * Framebuffer engine (0x2C .. 0x38)
 *
 * FB_CTRL resets to 0 (engine off). Geometry resets to 320x240 with a
 * 640-byte stride in A1R5G5B5 -- a simple-framebuffer devicetree node must
 * repeat whatever values firmware programs here.
 *
 * FB_BASE is a full 32-bit system physical address; its low two bits and the
 * low two bits of FB_STRIDE are forced to zero, because one burst beat is one
 * 32-bit line-buffer word. FB_BASE is shadowed and latched at the frame
 * boundary, which is what makes a page flip tear-free.
 * --------------------------------------------------------------------- */
#define PPU_FB_EN            (1u << 0)
#define PPU_FB_FMT_SHIFT     1
#define PPU_FB_FMT_MASK      0x7u
#define PPU_FB_FMT(f)        (((uint32_t)(f) & PPU_FB_FMT_MASK) << PPU_FB_FMT_SHIFT)
#define PPU_FB_FMT_OF(v)     (((v) >> PPU_FB_FMT_SHIFT) & PPU_FB_FMT_MASK)

/* FB_CTRL.FMT encodings -- the subset of the kernel's SIMPLEFB_FORMATS this
 * hardware carries. */
#define PPU_FB_FMT_A1R5G5B5  0u  /* DRM_FORMAT_ARGB1555 -- native          */
#define PPU_FB_FMT_X1R5G5B5  1u  /* DRM_FORMAT_XRGB1555 -- same in HW      */
#define PPU_FB_FMT_R5G6B5    2u  /* DRM_FORMAT_RGB565                      */
#define PPU_FB_FMT_X8R8G8B8  3u  /* DRM_FORMAT_XRGB8888 -- 2 beats/px, 8->5 */
#define PPU_FB_FMT_R5G5B5A1  4u  /* DRM_FORMAT_RGBA5551                    */

/* FB_SIZE: [9:0] active width, [25:16] active height. */
#define PPU_FB_SIZE_ENC(w, h) ((((uint32_t)(h) & 0x3FFu) << 16) | ((uint32_t)(w) & 0x3FFu))
#define PPU_FB_SIZE_W(v)      ((v) & 0x3FFu)
#define PPU_FB_SIZE_H(v)      (((v) >> 16) & 0x3FFu)

/* Reset geometry. */
#define PPU_FB_RST_W         320u
#define PPU_FB_RST_H         240u
#define PPU_FB_RST_STRIDE    640u
#define PPU_FB_STRIDE_RESET  0x00000280u
#define PPU_FB_SIZE_RESET    0x00F00140u

/* ------------------------------------------------------------------------
 * Programmable CRTC (0x3C .. 0x54)
 *
 * These are bare timing comparators, computed by firmware. They reset to the
 * exact 640x480@60 VESA DMT constants for a 25 MHz core clock (59.524 Hz),
 * so unprogrammed hardware behaves as the fixed-function design.
 *
 * In pair-counting mode (CRT_MD.DBLX = 0) each core clock carries one
 * internal pixel and an external DDR-sampling transmitter emits two. Note
 * that this macro is signed off at 25 MHz; faster modes need a re-harden.
 * --------------------------------------------------------------------- */
#define PPU_CRT_H1_ENC(h_last, h_act) \
	((((uint32_t)(h_act) & 0x7FFu) << 16) | ((uint32_t)(h_last) & 0x7FFu))
#define PPU_CRT_H2_ENC(hs_s, hs_e) \
	((((uint32_t)(hs_e) & 0x7FFu) << 16) | ((uint32_t)(hs_s) & 0x7FFu))
#define PPU_CRT_H3_ENC(h_bnd)         ((uint32_t)(h_bnd) & 0x7FFu)
#define PPU_CRT_V1_ENC(v_last, v_act) \
	((((uint32_t)(v_act) & 0x3FFu) << 16) | ((uint32_t)(v_last) & 0x3FFu))
#define PPU_CRT_V2_ENC(vs_s, vs_e) \
	((((uint32_t)(vs_e) & 0x3FFu) << 16) | ((uint32_t)(vs_s) & 0x3FFu))
#define PPU_CRT_LN_ENC(prep, line_lim) \
	((((uint32_t)(line_lim) & 0x3FFu) << 16) | ((uint32_t)(prep) & 0x3FFu))
#define PPU_CRT_MD_ENC(int_w, dblx, dbly) \
	((((uint32_t)(int_w) & 0x7FFu) << 16) | ((dbly) ? 2u : 0u) | ((dblx) ? 1u : 0u))

#define PPU_CRT_MD_DBLX      (1u << 0)  /* horizontal pixel doubling */
#define PPU_CRT_MD_DBLY      (1u << 1)  /* vertical line doubling    */

/* Reset values: 640x480@60, DMT, from a 25.000 MHz clock. */
#define PPU_CRT_H1_RESET     0x0280031Fu  /* h_last 799, h_act 640  */
#define PPU_CRT_H2_RESET     0x02F00290u  /* hs_s   656, hs_e  752  */
#define PPU_CRT_H3_RESET     0x0000027Fu  /* h_bnd  639             */
#define PPU_CRT_V1_RESET     0x01E0020Cu  /* v_last 524, v_act 480  */
#define PPU_CRT_V2_RESET     0x01EC01EAu  /* vs_s   490, vs_e  492  */
#define PPU_CRT_LN_RESET     0x01DD01DDu  /* prep   477, limit 477  */
#define PPU_CRT_MD_RESET     0x01400003u  /* int_w  320, both doubled */

/* ------------------------------------------------------------------------
 * FRAME (0x58) -- read-only
 * --------------------------------------------------------------------- */
#define PPU_FRAME_CNT(v)     ((v) & 0xFFFFu)
#define PPU_FRAME_FLIP_PEND  (1u << 16)

/* ------------------------------------------------------------------------
 * Display-list instruction encodings (2D command mode)
 *
 * Coordinate math uses a signed 8.8 matrix A and signed 10.6 offsets b:
 * u = A*(s - s0) + b.
 * --------------------------------------------------------------------- */
#define PPU_OP_SYNC          0x0u
#define PPU_OP_CLIP          0x1u
#define PPU_OP_FILL          0x2u
#define PPU_OP_BLEND         0x3u
#define PPU_OP_BLIT          0x4u
#define PPU_OP_TILE          0x5u
#define PPU_OP_ABLIT         0x6u
#define PPU_OP_ATILE         0x7u
#define PPU_OP_PALW          0x8u
#define PPU_OP_BLITLIST      0x9u
#define PPU_OP_PUSH          0xEu
#define PPU_OP_POPJ          0xFu

/* BLEND modes (5-bit global alpha accompanies the mode). */
#define PPU_BL_OPAQUE        0u
#define PPU_BL_ALPHA         1u
#define PPU_BL_ADD           2u
#define PPU_BL_SUB           3u
#define PPU_BL_MUL           4u

/* Source pixel formats for BLIT/TILE. */
#define PPU_FMT_ARGB1555     0u
#define PPU_FMT_P8           1u
#define PPU_FMT_P4           2u
#define PPU_FMT_P1           3u

/* ------------------------------------------------------------------------
 * Accessors
 *
 * `ppu` is a pointer to the CSR window, e.g.
 *     volatile uint32_t *ppu = (volatile uint32_t *)PPU0_BASE;
 *
 * Page flip: complete all stores to the back buffer, then (with a store
 * fence if your bus needs one) write FB_BASE. The new base is latched at the
 * next frame boundary; poll ppu_flip_pending() or take the vblank interrupt
 * to know it landed.
 * --------------------------------------------------------------------- */
static inline void ppu_wr(volatile uint32_t *ppu, uint32_t off, uint32_t v)
{
	ppu[off / 4u] = v;
}

static inline uint32_t ppu_rd(volatile uint32_t *ppu, uint32_t off)
{
	return ppu[off / 4u];
}

static inline int ppu_flip_pending(volatile uint32_t *ppu)
{
	return (int)((ppu_rd(ppu, PPU_FRAME) >> 16) & 1u);
}

static inline uint32_t ppu_frame_count(volatile uint32_t *ppu)
{
	return ppu_rd(ppu, PPU_FRAME) & 0xFFFFu;
}
