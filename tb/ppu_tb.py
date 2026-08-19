# SPDX-License-Identifier: Apache-2.0
"""
PPU RTL vs golden model, scanline by scanline -- signoff gate G12.

Drives ppu_top with the same programs ip/ppu/model/ppu_model.py executes, then
reads the rendered line back out of the scanbuf macros and compares it pixel for
pixel. The model is normative: a mismatch means the RTL is wrong until proven
otherwise.

    python3 ip/ppu/tb/ppu_tb.py

External memory is modelled here in Python rather than in Verilog so that the
bench and the golden model read from literally the same bytes -- there is no
second copy of the test data to drift.
"""

from pathlib import Path
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb_tools.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
import ppu_model as M  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from aps12808 import idle_burst_port  # noqa: E402

CLK_NS = 40  # 25.000 MHz on clk_PAD; core == pixel


# ---------------------------------------------------------------------------
# External memory: one 16-bit beat per request, zero wait states.
# ---------------------------------------------------------------------------

async def mem_server(dut, mem: M.Memory):
    """External async SRAM: one 16-bit beat per request, zero wait states.

    Honours mem_we so the host memory window can be exercised -- that write path
    is the only piece of hardware simpledrm actually needs beyond a framebuffer
    display list."""
    dut.mem_ack.value = 0
    dut.mem_rdata.value = 0
    while True:
        await RisingEdge(dut.clk)
        if dut.mem_req.value == 1:
            addr = int(dut.mem_addr.value) & ~1
            n = len(mem.data)
            if dut.mem_we.value == 1:
                d = int(dut.mem_wdata.value)
                mem.data[addr % n] = d & 0xFF
                mem.data[(addr + 1) % n] = (d >> 8) & 0xFF
            else:
                dut.mem_rdata.value = mem.data[addr % n] | (mem.data[(addr + 1) % n] << 8)
            dut.mem_ack.value = 1
        else:
            dut.mem_ack.value = 0


def read_scanbuf(dut, bank: int) -> list[int]:
    """Read a rendered line straight out of the SRAM macro arrays.

    Reaches into the foundry model's `mem` array rather than scanning the line
    out through the display port, so a failure points at the render path instead
    of at display timing."""
    bank_h = dut.u_scanbuf.bank1 if bank else dut.u_scanbuf.bank0
    lanes = [_lane_sram(bank_h, i).mem for i in range(4)]
    out = []
    for word in range(M.INTERNAL_W // 2):
        b = [int(lanes[i][word].value) for i in range(4)]
        out.append(b[0] | (b[1] << 8))          # even pixel
        out.append(b[2] | (b[3] << 8))          # odd pixel
    return out


def _lane_sram(parent, lane):
    """The SRAM macro inside generate scope `lane[N]`.

    On RTL the path is parent.lane[N].u_sram. On the gate-level netlist yosys
    collapses the generate scope into one escaped instance name that cocotb
    cannot address at all, so scripts/synth_gl.sh renames those instances to
    plain `gl_lane_N_u_sram`. Try the RTL shape first, then the GL shape.
    """
    for get in (lambda: parent.lane[lane].u_sram,
                lambda: getattr(parent, f"gl_lane_{lane}_u_sram")):
        try:
            h = get()
            h.mem  # not the macro model unless this resolves
            return h
        except (AttributeError, IndexError):
            continue
    raise AttributeError(f"no SRAM at lane[{lane}] under {parent._path}")


async def clear_scanbufs(dut):
    """Zero both scanbuf banks between scenes.

    SRAM has no reset, so a fresh PPU() in the model starts from zeroed buffers
    while the RTL would otherwise carry the previous scene's residue. Real
    hardware powers up indeterminate and is expected to FILL every line; this
    just puts both sides on the same footing so a mismatch means a real bug.
    """
    for bank in (dut.u_scanbuf.bank0, dut.u_scanbuf.bank1):
        for lane in range(4):
            m = _lane_sram(bank, lane).mem
            for w in range(M.INTERNAL_W // 2):
                m[w].value = 0
    await Timer(1, unit="ns")


async def load_pram(dut, pram: list[int]):
    """Preload the palette by poking the macro arrays. PALW is exercised
    separately; this just gets a known palette in place cheaply."""
    lo = _lane_sram(dut.u_pram, 0).mem
    hi = _lane_sram(dut.u_pram, 1).mem
    for i, v in enumerate(pram):
        lo[i].value = v & 0xFF
        hi[i].value = (v >> 8) & 0xFF
    await Timer(1, unit="ns")


# APB register offsets -- ip/ppu/README.md section 9.
R_CTRL, R_STATUS, R_PC, R_IRQ_EN = 0x00, 0x04, 0x08, 0x0C
R_IRQ_ST, R_DISP, R_PRAM_A, R_PRAM_D = 0x10, 0x14, 0x18, 0x1C
R_BUSST, R_MEM_A, R_MEM_D = 0x20, 0x24, 0x28
R_FB_CTL, R_FB_BASE, R_FB_STRIDE, R_FB_SIZE = 0x2C, 0x30, 0x34, 0x38
R_FRAME = 0x58


async def apb_write(dut, addr: int, data: int):
    dut.psel.value, dut.pwrite.value = 1, 1
    dut.paddr.value, dut.pwdata.value = addr, data
    dut.penable.value = 0
    await RisingEdge(dut.clk)
    dut.penable.value = 1
    await RisingEdge(dut.clk)
    while int(dut.pready.value) == 0:
        await RisingEdge(dut.clk)
    dut.psel.value, dut.penable.value, dut.pwrite.value = 0, 0, 0


async def apb_read(dut, addr: int) -> int:
    dut.psel.value, dut.pwrite.value = 1, 0
    dut.paddr.value = addr
    dut.penable.value = 0
    await RisingEdge(dut.clk)
    dut.penable.value = 1
    await RisingEdge(dut.clk)
    while int(dut.pready.value) == 0:      # PRAM reads insert one wait state
        await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    val = int(dut.prdata.value)
    dut.psel.value, dut.penable.value = 0, 0
    return val


async def setup(dut, mem: M.Memory, pram: list[int], prog: int):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(mem_server(dut, mem))

    dut.rst_n.value = 0
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = 0
    dut.pwdata.value = 0
    # The bus-release request must be DRIVEN, not left floating. An undriven
    # input is X, `if (!mem_hreq)` takes the else branch on X, and the arbiter
    # hands the external bus to a host that does not exist -- after which
    # nothing fetches and every scene times out. Real silicon ties it low if the
    # board has no second master; a bench has to say so explicitly.
    dut.mem_hreq.value = 0
    idle_burst_port(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    await clear_scanbufs(dut)
    await load_pram(dut, pram)

    # DISP_CFG resets to 0xF -- both output paths on, both syncs active high --
    # so a chip that is never configured still produces correct VESA DMT video.
    await apb_write(dut, R_PC, prog)       # write also pulses pc_load
    await apb_write(dut, R_CTRL, 0x1)      # ENABLE
    await RisingEdge(dut.clk)


async def render_line(dut, timeout=6000) -> tuple[int, list[int]]:
    """Wait for one internal line to be rendered; return (render_y, pixels).

    The y being rendered is read from the DUT rather than assumed, because the
    display controller decides it: render_y restarts at prep_frame and only
    advances when the buffer handshake succeeds. Assuming 0,1,2... silently
    compares the wrong lines the moment an overrun or a mid-frame start shifts
    the sequence -- which is what happened when the handshake landed.
    """
    # The display controller now gates the render start behind the buffer
    # handshake, so wait on render_start rather than the raw line tick.
    while dut.u_display.render_start.value != 1:
        await RisingEdge(dut.clk)
        timeout -= 1
        if timeout <= 0:
            raise TimeoutError("no render_start")
    # buf_sel is sampled AFTER the swap has taken effect. Reading it while
    # line_start is still asserted gets the previous line's buffer, because the
    # swap lands on that same clock edge.
    y = int(dut.u_display.render_y.value)
    await RisingEdge(dut.clk)
    bank = int(dut.u_scanbuf.buf_sel.value)
    while dut.line_done.value != 1:
        await RisingEdge(dut.clk)
        timeout -= 1
        if timeout <= 0:
            raise TimeoutError("no line_done -- command processor stalled")
    await FallingEdge(dut.clk)
    return y, read_scanbuf(dut, bank)


def compare(name, y, got, want, limit=6):
    bad = [(x, g, w) for x, (g, w) in enumerate(zip(got, want)) if g != w]
    if bad:
        detail = ", ".join(f"x={x} rtl={g:#06x} model={w:#06x}" for x, g, w in bad[:limit])
        raise AssertionError(
            f"{name}: line {y} differs in {len(bad)}/{len(want)} pixels: {detail}")


# ---------------------------------------------------------------------------
# Scenes. Each builds identical state for the RTL and the model.
# ---------------------------------------------------------------------------

def scene_fill():
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog = 0x8000
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(31, 0, 12) + M.sync() + M.loop_to(prog), mem, prog)
    return "fill", mem, ppu, prog


def scene_clip():
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog = 0x8000
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(0, 0, 0)
               + M.clip(37, 208) + M.fill(31, 31, 0) + M.sync() + M.loop_to(prog), mem, prog)
    return "clip", mem, ppu, prog


def scene_blend_modes():
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog = 0x8000
    words = M.clip(0, M.INTERNAL_W - 1) + M.fill(8, 16, 24)
    for i, mode in enumerate((M.MODE_ALPHA, M.MODE_ADD, M.MODE_SUB, M.MODE_MUL)):
        words += M.blend(mode, 7 + i * 6) + M.clip(i * 100, i * 100 + 99) + M.fill(30, 5, 20)
    words += M.sync() + M.loop_to(prog)
    M.assemble(words, mem, prog)
    return "blend_modes", mem, ppu, prog


def scene_blit_direct():
    mem = M.Memory()
    ppu = M.PPU(mem)
    sprite, prog = 0x3000, 0x8000
    for v in range(32):
        for u in range(32):
            opaque = ((u ^ v) & 7) != 0
            mem.write32(sprite + (v * 32 + u) * 2,
                        M.pack1555(1, u, v, (u + v) & 31) if opaque else 0)
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(1, 2, 3)
               + M.blit(40, 4, 2, sprite, M.FMT_ARGB1555) + M.sync() + M.loop_to(prog), mem, prog)
    return "blit_argb1555", mem, ppu, prog


def _paletted_sprite(mem, ppu, base, fmt):
    """32x32 sprite in a sub-byte format, plus a palette with index 0 transparent."""
    for i in range(256):
        ppu.pram[i] = M.pack1555(1, i & 0x1F, (i >> 1) & 0x1F, (i >> 2) & 0x1F)
    ppu.pram[0] = 0
    bits = M.FMT_BITS[fmt]
    per_byte = 8 // bits
    for v in range(32):
        for u in range(0, 32, per_byte):
            byte = 0
            for k in range(per_byte):
                val = ((u + k) * 3 + v * 5) & ((1 << bits) - 1)
                byte |= val << (k * bits)
            mem.data[base + (v * 32 + u) // per_byte] = byte


def _scene_blit_paletted(fmt, label):
    def build():
        mem = M.Memory()
        ppu = M.PPU(mem)
        sprite, prog = 0x3000, 0x8000
        _paletted_sprite(mem, ppu, sprite, fmt)
        M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(3, 6, 9)
                   + M.blit(24, 2, 2, sprite, fmt, poff=2) + M.sync() + M.loop_to(prog), mem, prog)
        return label, mem, ppu, prog
    return build


def scene_tile():
    mem = M.Memory()
    ppu = M.PPU(mem)
    tileset, tilemap, prog = 0x1000, 0x2000, 0x8000
    for i in range(256):
        ppu.pram[i] = M.pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    for t in range(4):
        for v in range(16):
            for u in range(16):
                mem.data[tileset + t * 256 + v * 16 + u] = (u ^ v) + t * 16
    for i in range(32 * 32):
        mem.data[tilemap + i] = i % 4
    M.assemble(M.clip(0, M.INTERNAL_W - 1)
               + M.tile(0, 0, 1, tilemap, 2, tileset, M.FMT_P8) + M.sync() + M.loop_to(prog), mem, prog)
    return "tile_p8", mem, ppu, prog


def scene_parallax():
    """Two independently scrolled indexed playfields on one scanline.

    The capability a 16-bit console gets from having several hardware
    background layers. Here it is two TILE ops in one display list, and it
    only became affordable once a tiled pixel came down to ~1.9 core clocks;
    tb/ppu_throughput_probe.py's `parallax` scene gates the timing. THIS scene
    gates the pixels, which timing cannot: the foreground tileset is mostly
    palette index 0 -- the hard transparency -- so the background must show
    through the gaps, and both layers must land at their own scroll offsets.
    Nothing else in this suite draws one span over another.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    ts_bg, tm_bg, ts_fg, tm_fg, prog = 0x1000, 0x2000, 0x3000, 0x4000, 0x8000
    for i in range(256):
        ppu.pram[i] = M.pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    ppu.pram[0] = 0                                     # index 0 transparent
    for t in range(4):
        for v in range(16):
            for u in range(16):
                mem.data[ts_bg + t * 256 + v * 16 + u] = 1 + ((u ^ v) + t * 16) % 200
                solid = (u < 6 and v < 6) or (u > 9 and v > 9)
                mem.data[ts_fg + t * 256 + v * 16 + u] = (100 + t * 8) if solid else 0
    for i in range(32 * 32):
        mem.data[tm_bg + i] = i % 4
        mem.data[tm_fg + i] = (i * 3 + i // 32) % 4
    M.assemble(M.clip(0, M.INTERNAL_W - 1)
               + M.tile(0, 0, 1, tm_bg, 2, ts_bg, M.FMT_P8)
               + M.tile(37, 11, 1, tm_fg, 2, ts_fg, M.FMT_P8)
               + M.sync() + M.loop_to(prog), mem, prog)
    return "parallax", mem, ppu, prog


def scene_flip():
    """The same sprite drawn four ways: unflipped, H, V, and both.

    Flipping is what lets one stored sprite face either direction, so the
    thing that must hold is that the mirrored copies are the SOURCE reflected
    while the screen span stays put. The sprite is deliberately asymmetric in
    both axes -- a corner marker plus a diagonal -- because a symmetric one
    would pass this test with the flip logic removed entirely.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    img, prog = 0x3000, 0x8000
    for v in range(16):
        for u in range(16):
            if u < 3 and v < 3:
                c = M.pack1555(1, 31, 31, 0)        # corner marker
            elif u == v:
                c = M.pack1555(1, 31, 0, 0)         # diagonal
            elif u > 12:
                c = M.pack1555(1, 0, 0, 31)         # right-edge stripe
            elif v > 13:
                c = M.pack1555(1, 0, 31, 0)         # bottom stripe
            else:
                c = M.pack1555(1, u, v, 8)
            off = img + (v * 16 + u) * 2
            mem.data[off] = c & 0xFF
            mem.data[off + 1] = c >> 8
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(1, 1, 1)
               + M.blit(10, 0, 1, img, M.FMT_ARGB1555)
               + M.blit(40, 0, 1, img, M.FMT_ARGB1555, hflip=True)
               + M.blit(70, 0, 1, img, M.FMT_ARGB1555, vflip=True)
               + M.blit(100, 0, 1, img, M.FMT_ARGB1555, hflip=True, vflip=True)
               + M.sync() + M.loop_to(prog), mem, prog)
    return "flip", mem, ppu, prog


def scene_priority():
    """A sprite drawn BEFORE a playfield that must still appear in front of it.

    Painter's order cannot express this: whatever is emitted last wins. The
    playfield is emitted with BLEND's yield bit set, so it draws everywhere the
    sprite is not and leaves the sprite's pixels alone. Both halves matter --
    the playfield must actually cover the rest of the line, or a broken
    implementation that simply dropped the span would pass.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    tileset, tilemap, img, prog = 0x1000, 0x2000, 0x3000, 0x8000
    for i in range(256):
        ppu.pram[i] = M.pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    for t in range(4):
        for v in range(16):
            for u in range(16):
                mem.data[tileset + t * 256 + v * 16 + u] = 1 + ((u ^ v) + t * 16) % 200
    for i in range(32 * 32):
        mem.data[tilemap + i] = i % 4
    for v in range(16):
        for u in range(16):
            c = M.pack1555(1, 31, u * 2, v * 2)
            off = img + (v * 16 + u) * 2
            mem.data[off] = c & 0xFF
            mem.data[off + 1] = c >> 8
    M.assemble(M.clip(0, M.INTERNAL_W - 1)
               + M.blit(24, 0, 1, img, M.FMT_ARGB1555)      # sprite first
               + M.blend(M.MODE_OPAQUE, behind=True)         # playfield yields
               + M.tile(0, 0, 1, tilemap, 2, tileset, M.FMT_P8)
               + M.blend(M.MODE_OPAQUE)                      # restore
               + M.sync() + M.loop_to(prog), mem, prog)
    return "priority", mem, ppu, prog


def scene_window():
    """The second window, in both senses, over a full-width FILL and a sprite.

    CLIP can only shorten a span from its ends. WIN masks pixels *within* it,
    so `out=1` cuts a hole in the middle of an otherwise unbroken span -- the
    thing CLIP cannot do without splitting the draw into two commands. Both
    senses are exercised, because an implementation that ignored `out` would
    pass a test of only one.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    img, prog = 0x3000, 0x8000
    for v in range(16):
        for u in range(16):
            c = M.pack1555(1, 31, u * 2, v * 2)
            off = img + (v * 16 + u) * 2
            mem.data[off] = c & 0xFF
            mem.data[off + 1] = c >> 8
    M.assemble(M.clip(0, M.INTERNAL_W - 1)
               + M.win(60, 200, en=1, out=1) + M.fill(6, 2, 9)   # hole in the middle
               + M.win(80, 180, en=1, out=0) + M.fill(0, 12, 4)  # band only
               + M.win(100, 140, en=1, out=0)
               + M.blit(96, 0, 1, img, M.FMT_ARGB1555)           # sprite cropped by it
               + M.win(0, 0, en=0)                               # masking off again
               + M.blit(220, 0, 1, img, M.FMT_ARGB1555)          # unmasked
               + M.sync() + M.loop_to(prog), mem, prog)
    return "window", mem, ppu, prog


def scene_tilemap_wide():
    """16-bit tilemap entries: per-tile flip and per-tile sub-palette.

    A one-byte entry carries only the tile index, so mirrored level geometry
    costs a mirrored tile in the tileset and the whole playfield shares one
    sub-palette. The wide entry spends a second byte on hflip, vflip and poff.

    Every tile here differs from its neighbours in at least one of those three
    fields, and the tile art is asymmetric in both axes, so a decoder that
    ignored any field -- or applied a flip to the wrong axis -- would diverge
    from the model immediately.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    tileset, tilemap, prog = 0x1000, 0x4000, 0x8000
    for i in range(256):
        ppu.pram[i] = M.pack1555(1, (i * 7) & 0x1F, (i * 3) & 0x1F, (i * 11) & 0x1F)
    # Four 16x16 P4 tiles, asymmetric in both axes.
    for t in range(4):
        for v in range(16):
            for u in range(16):
                if u < 4 and v < 4:
                    e = 1 + t
                elif u > 11:
                    e = 9
                elif v > 12:
                    e = 12
                else:
                    e = 2 + ((u + 2 * v + t) % 6)
                off = tileset + t * 128 + (v * 16 + u) // 2
                if u & 1:
                    mem.data[off] = (mem.data[off] & 0x0F) | (e << 4)
                else:
                    mem.data[off] = (mem.data[off] & 0xF0) | e
    # Wide entries: index, hflip, vflip and sub-palette all vary tile to tile.
    for row in range(32):
        for col in range(32):
            ent = ((col + row) % 4) | ((col & 1) << 8) | ((row & 1) << 9) \
                  | (((col >> 1) & 0x7) << 10)
            a = tilemap + (row * 32 + col) * 2
            mem.data[a] = ent & 0xFF
            mem.data[a + 1] = ent >> 8
    M.assemble(M.clip(0, M.INTERNAL_W - 1)
               + M.tile(0, 0, 1, tilemap, 2, tileset, M.FMT_P4, wide=True)
               + M.sync() + M.loop_to(prog), mem, prog)
    return "tilemap_wide", mem, ppu, prog


def scene_palw():
    """PALW writes the palette from the command stream, then a P8 blit reads it."""
    mem = M.Memory()
    ppu = M.PPU(mem)
    sprite, prog = 0x3000, 0x8000
    _paletted_sprite(mem, ppu, sprite, M.FMT_P8)
    words = M.clip(0, M.INTERNAL_W - 1) + M.fill(0, 0, 0)
    for i in range(1, 8):
        words += M.palw(i, M.pack1555(1, 31 - i * 3, i * 4, 20))
    words += M.blit(10, 0, 2, sprite, M.FMT_P8) + M.sync() + M.loop_to(prog)
    M.assemble(words, mem, prog)
    # The model must see the same PALW effect, so start from the same palette.
    return "palw", mem, ppu, prog


def scene_subroutine():
    """PUSH/POPJ: a per-scanline subroutine called from the main list.

    The RETURN ADDRESS is pushed before the target, because POPJ is a jump and
    not a call -- see the note in ppu_model.demo_scene(). Written the other way
    round the subroutine's POPJ pops an empty stack, jumps to 0, and every line
    after the first draws nothing; this scene passed anyway because its content
    does not depend on y, which is exactly how that stayed hidden.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog, subr = 0x8000, 0x9000
    M.assemble(M.clip(50, 150) + M.fill(31, 0, 0) + [(M.OP_POPJ << 28)], mem, subr)
    head = M.clip(0, M.INTERNAL_W - 1) + M.fill(2, 4, 6)
    call = M.push(0) + M.push(subr) + M.popj()
    call[1] = prog + 4 * (len(head) + len(call))          # return address
    M.assemble(head + call
               + M.clip(0, M.INTERNAL_W - 1) + M.sync() + M.loop_to(prog), mem, prog)
    return "subroutine", mem, ppu, prog


def scene_ablit():
    """ABLIT: the S_AFF setup sequence and per-pixel affine stepping have never
    been exercised by ANY bench until this scene -- the shared multiplier, the
    signed-b centred rotation (README section 8), the is_affine decode. A 30-deg
    rotation with the negative-u translation that unsigned b could not encode.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog, sprite = 0x8000, 0x3000
    for v in range(32):
        for u in range(32):
            inside = (u - 16) ** 2 + (v - 16) ** 2 < 200
            mem.write32(sprite + (v * 32 + u) * 2,
                        M.pack1555(1, 31, u, v) if inside else 0)
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(2, 2, 8)
               + M.ablit(140, 30, 2, sprite, M.FMT_ARGB1555,
                         a=(310, 179, -179, 310), b=(-932, 500))
               + M.sync() + M.loop_to(prog), mem, prog)
    return "ablit", mem, ppu, prog


def scene_atile():
    """ATILE: affine playfield with WRAP. The rotation plus a negative-u
    translation walks the sample point off every playfield edge, so u and v
    must re-enter modulo play_dim -- the wrap the tile_col/tile_row mask in
    ppu_cmd.v exists for. Never exercised by any bench before this scene."""
    mem = M.Memory()
    ppu = M.PPU(mem)
    tileset, tilemap, prog = 0x1000, 0x2000, 0x8000
    for i in range(256):
        ppu.pram[i] = M.pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    for t in range(4):                       # four distinct 8x8 P8 tiles
        for v in range(8):
            for u in range(8):
                mem.data[tileset + t * 64 + v * 8 + u] = (u ^ v) + t * 16
    for i in range(16 * 16):                 # 128/8 = 16x16 tile map
        mem.data[tilemap + i] = i % 4
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(1, 2, 3)
               + M.atile(0, 0, 0, tilemap, 0, tileset, M.FMT_P8,
                         a=(222, 128, -128, 222), b=(-500, 300))
               + M.sync() + M.loop_to(prog), mem, prog)
    return "atile_p8", mem, ppu, prog


def scene_blitlist():
    """BLITLIST: one instruction, four descriptors walked from memory. The
    descriptors place 8x8 ARGB1555 sprites at spread-out x positions, one of
    them at y=3 so the per-descriptor blit_hits test skips it on early lines,
    and one hanging off the right clip edge. First bench ever to execute the
    walker rather than just decode the opcode."""
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog, desc = 0x8000, 0xA000
    sprites = []
    for s in range(4):
        base = 0x3000 + s * 0x100
        sprites.append(base)
        for v in range(8):
            for u in range(8):
                c = M.pack1555(1, 4 + s * 6, u * 4, v * 4)
                off = base + (v * 8 + u) * 2
                mem.data[off] = c & 0xFF
                mem.data[off + 1] = c >> 8
    places = [(10, 0), (30, 3), (50, 0), (316, 1)]      # (x, y) per descriptor
    for i, ((x, y), img) in enumerate(zip(places, sprites)):
        mem.write32(desc + i * 8,     x | (y << 10))     # size=0, poff=0
        mem.write32(desc + i * 8 + 4, (img & ~3) | M.FMT_ARGB1555)
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(3, 3, 3)
               + [(M.OP_BLITLIST << 28) | (4 << 20) | (desc >> 2)]
               + M.sync() + M.loop_to(prog), mem, prog)
    return "blitlist", mem, ppu, prog


SCENES = [scene_fill, scene_clip, scene_blend_modes, scene_blit_direct,
          _scene_blit_paletted(M.FMT_P8, "blit_p8"),
          _scene_blit_paletted(M.FMT_P4, "blit_p4"),
          _scene_blit_paletted(M.FMT_P1, "blit_p1"),
          scene_tile, scene_parallax, scene_flip, scene_priority, scene_window, scene_tilemap_wide, scene_palw, scene_subroutine, scene_ablit, scene_atile,
          scene_blitlist]


# Empty since the last two tracked bugs were fixed (README section 15): ablit
# (missing affine texture-bounds check -- the accumulator slice aliased) and
# tile_p8 (TILE's pointer args loaded swapped, plus a 3-bit `tsh + tsh` wrap
# that zeroed the tile-index shift for 16x16 tiles). The scanbuf-pairing
# theory an earlier version of this comment carried was wrong. The set stays
# so a future known failure can be tracked rather than hidden.
EXPECTED_FAIL = set()


@cocotb.test()
async def test_scenes(dut):
    """Every scene, several lines each, RTL against model."""
    failures, passes, xfails = [], [], []
    for build in SCENES:
        name, mem, ppu, prog = build()
        pram = list(ppu.pram)
        await setup(dut, mem, pram, prog)

        err = None
        for _ in range(6):
            y, got = await render_line(dut)
            want = ppu._render_line(prog, y)
            try:
                compare(name, y, got, want)
            except AssertionError as exc:
                err = str(exc)
                break

        if err is None:
            passes.append(name)
            dut._log.info(f"PASS  {name}")
        elif name in EXPECTED_FAIL:
            xfails.append(name)
            dut._log.warning(f"XFAIL {name}: {err}")
        else:
            failures.append(err)
            dut._log.error(f"FAIL  {name}: {err}")

    stat = await apb_read(dut, R_BUSST)
    assert (stat & 0xFFFF) != 0, "BUS_STAT fetch counter stayed zero across ten scenes"
    dut._log.info(f"BUS_STAT: {stat >> 16} stall / {stat & 0xFFFF} fetch cycles (gate G4)")
    dut._log.info(f"SUMMARY {len(passes)} passed, {len(xfails)} expected-fail, "
                  f"{len(failures)} failed  |  passing: {', '.join(passes)}")
    if failures:
        raise AssertionError(f"{len(failures)} scene(s) failed")


def main():
    ppu_dir = Path(__file__).resolve().parents[1]

    build_dir = os.environ.get("PPU_BUILD_DIR", "sim_build")
    if os.environ.get("PPU_GL", "0") == "1":
        # Gate-level render scenes (gate G6): the mapped netlist plus the PDK's
        # functional cell models. Requires scripts/synth_gl.sh first (hierarchy
        # kept, SRAM instances renamed to gl_lane_N_u_sram -- see _lane_sram).
        pdk_sc = (ppu_dir.parents[1] / "gf180mcu" / "ciel" / "gf180mcu" /
                  "versions" / "f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7" /
                  "gf180mcuD" / "libs.ref" / "gf180mcu_fd_sc_mcu7t5v0" / "verilog")
        sources = [ppu_dir / "reports" / "ppu_synth_gl.v",
                   pdk_sc / "primitives.v",
                   pdk_sc / "gf180mcu_fd_sc_mcu7t5v0.v",
                   ppu_dir / "tb" / "sram_behavioural.v"]
        build_dir = "sim_build_gl"
    else:
        sources = [ppu_dir / "rtl" / f for f in (
            "ppu_blend.v", "ppu_timing.v", "ppu_cache.v", "ppu_unpack.v",
            "ppu_cmd.v", "ppu_scanbuf.v", "ppu_fbscan.v", "ppu_display.v",
            "ppu_csr.v", "ppu_top.v")]
        # Behavioural SRAM, not the foundry model -- see tb/sram_behavioural.v
        # for why the foundry one cannot be used in a zero-delay RTL simulation.
        sources.append(ppu_dir / "tb" / "sram_behavioural.v")

    runner = get_runner("icarus")
    runner.build(verilog_sources=sources, hdl_toplevel="ppu_top",
                 includes=[ppu_dir / "rtl"],
                 build_args=["-g2005", "-DFUNCTIONAL", "-DUNIT_DELAY=#0"],
                 always=True, build_dir=build_dir)
    runner.test(hdl_toplevel="ppu_top", test_module="ppu_tb",
                build_dir=build_dir)


if __name__ == "__main__":
    main()
