#!/usr/bin/env python3
"""
PPU golden reference model -- the normative definition of PPU behaviour.

This is what the RTL is checked against for signoff gate G5. Where this file and
ip/ppu/README.md disagree about a bit position, THIS FILE WINS and the README is
the document with the bug.

    python3 ip/ppu/model/ppu_model.py --selftest
    python3 ip/ppu/model/ppu_model.py --demo out.ppm

WHY A GOLDEN MODEL BEFORE RTL
-----------------------------
"Frame-accurate RTL vs golden-model comparison" is only a gate if the golden
model exists and is itself pinned down. Blend arithmetic in particular has no
single obvious definition -- 5-bit channels do not divide evenly -- so the exact
integer form is chosen HERE, in a place where it can be reasoned about, rather
than emerging from whatever the first RTL author happened to type.

ENCODING PROVENANCE
-------------------
The instruction set is derived from RISCBoy PPU2 (Luke Wren). Opcode numbers and
field meanings follow it. Exact field POSITIONS for TILE/ATILE are defined here
because the source document's bit diagram is ambiguous about them, and poff is
widened from 2 to 3 bits so that eight 32-entry sub-palettes are addressable
rather than four. Licence review of the derivation is gate G9.
"""

from __future__ import annotations

import argparse
import sys

# --------------------------------------------------------------------------
# Frozen geometry (see README 2, ppu_plan.py SELECTED)
# --------------------------------------------------------------------------

INTERNAL_W, INTERNAL_H = 320, 240
PIX_DIV = 1              # core cycles per pixel; must match PPU_PIX_DIV
DISPLAY_W, DISPLAY_H = 640, 480

# --------------------------------------------------------------------------
# ARGB1555
# --------------------------------------------------------------------------

def unpack1555(v: int) -> tuple[int, int, int, int]:
    """-> (a, r, g, b); a is 1 bit, channels are 5 bits."""
    return ((v >> 15) & 1, (v >> 10) & 0x1F, (v >> 5) & 0x1F, v & 0x1F)


def pack1555(a: int, r: int, g: int, b: int) -> int:
    return ((a & 1) << 15) | ((r & 0x1F) << 10) | ((g & 0x1F) << 5) | (b & 0x1F)


# --------------------------------------------------------------------------
# Blend arithmetic -- the normative definitions
# --------------------------------------------------------------------------
#
# Channels and alpha are both 5 bits, so nothing divides evenly and the exact
# integer form has to be chosen deliberately. These are picked to be cheap in
# hardware (5x5 multiply plus shifts, no dividers) and are what the RTL must
# reproduce bit for bit.

def blend_alpha(src: int, dst: int, alpha: int) -> int:
    """dst = (src*a + dst*(32-a)) >> 5, a in [0,31].

    a=0 yields dst exactly. a=31 yields (31*src + dst)/32 -- NOT fully opaque,
    which is deliberate: full opacity is mode 0, so the alpha path never needs
    a=32 and alpha stays in 5 bits."""
    return (src * alpha + dst * (32 - alpha)) >> 5


def blend_add(src: int, dst: int, alpha: int) -> int:
    return min(31, dst + ((src * alpha) >> 5))


def blend_sub(src: int, dst: int, alpha: int) -> int:
    return max(0, dst - ((src * alpha) >> 5))


def blend_mul(src: int, dst: int, _alpha: int = 0) -> int:
    """Exact-endpoint multiply: x/31 via the shift-add identity rather than a
    divider. 31*31 -> 31 and 0*x -> 0, which a plain >>5 would get wrong (30)."""
    x = src * dst
    return (x + (x >> 5) + 16) >> 5


MODE_OPAQUE, MODE_ALPHA, MODE_ADD, MODE_SUB, MODE_MUL = range(5)
_BLEND_FN = {MODE_ALPHA: blend_alpha, MODE_ADD: blend_add,
             MODE_SUB: blend_sub, MODE_MUL: blend_mul}


def blend_pixel(src1555: int, dst1555: int, mode: int, alpha: int,
                prio: int = 1) -> int:
    """Apply blend state. The per-pixel A bit is a hard transparency test in
    EVERY mode; `alpha` is per-command opacity. Splitting transparency this
    way -- a hard per-texel bit plus a per-command blend strength -- is the
    conventional arrangement for tile-and-sprite hardware of this class.

    `prio` is the per-pixel priority level and it lives in bit 15 of the stored
    pixel -- the bit scanout never reads, since the display takes only [14:0].

    The DEFAULT is 1, which is what bit 15 has always held for a written pixel,
    so ordinary content is bit-identical to before this existed. Drawing with
    prio=0 marks content that YIELDS: it will not overwrite a pixel already
    holding priority 1. That covers the one case painter's order cannot -- a
    span drawn LATER that must appear behind something drawn earlier, such as a
    foreground playfield that a sprite should stand in front of. Where the draw
    order already matches the depth order, none of this is needed."""
    sa, sr, sg, sb = unpack1555(src1555)
    if sa == 0:
        return dst1555                      # transparent -- no write at all
    if (dst1555 >> 15) and not prio:
        return dst1555                      # destination outranks this pixel
    if mode == MODE_OPAQUE or mode not in _BLEND_FN:
        return (src1555 & 0x7FFF) | (prio << 15)
    _, dr, dg, db = unpack1555(dst1555)
    f = _BLEND_FN[mode]
    return pack1555(prio, f(sr, dr, alpha), f(sg, dg, alpha), f(sb, db, alpha))


# --------------------------------------------------------------------------
# Instruction encoding
# --------------------------------------------------------------------------

OP_SYNC, OP_CLIP, OP_FILL, OP_BLEND = 0x0, 0x1, 0x2, 0x3
OP_BLIT, OP_TILE, OP_ABLIT, OP_ATILE = 0x4, 0x5, 0x6, 0x7
OP_PALW, OP_BLITLIST = 0x8, 0x9
OP_WIN = 0xA
OP_PUSH, OP_POPJ = 0xE, 0xF

FMT_ARGB1555, FMT_P8, FMT_P4, FMT_P1 = 0, 1, 2, 3
FMT_BITS = {FMT_ARGB1555: 16, FMT_P8: 8, FMT_P4: 4, FMT_P1: 1}

CC_ALWAYS, CC_YLT, CC_YGE = 0, 1, 2


def _bits(w: int, hi: int, lo: int) -> int:
    return (w >> lo) & ((1 << (hi - lo + 1)) - 1)


def _sign16(v: int) -> int:
    return v - 0x10000 if v & 0x8000 else v


# --------------------------------------------------------------------------
# Machine state
# --------------------------------------------------------------------------

class Cache:
    """Direct-mapped, line = 2 bytes = one 16-bit bus beat.

    Models the only thing worth caching on this design: repeat access to the
    same bus word. A hit costs no external cycle."""

    def __init__(self, entries: int, line_bytes: int = 2):
        self.n, self.line = entries, line_bytes
        self.tags: list[int | None] = [None] * entries
        self.hits = self.misses = 0

    def access(self, addr: int) -> bool:
        line = addr // self.line
        idx = line % self.n
        if self.tags[idx] == line:
            self.hits += 1
            return True
        self.tags[idx] = line
        self.misses += 1
        return False

    @property
    def hit_rate(self) -> float:
        t = self.hits + self.misses
        return self.hits / t if t else 0.0


class Memory:
    """Flat little-endian external memory. The PPU only ever reads it.

    Fetches are tagged by category so the tile-index stream can be costed
    separately from the texel stream -- that split is what decides whether an
    on-chip tilemap RAM earns its area."""

    def __init__(self, size: int = 1 << 19, cache: Cache | None = None,
                 caches: dict[str, Cache] | None = None):
        self.data = bytearray(size)
        self.reads = 0                      # for the G4 bandwidth check
        self.by_kind = {"texel": 0, "index": 0, "program": 0}
        # `cache` is one unified cache; `caches` gives each fetch stream its own,
        # which stops the index and texel streams evicting each other.
        self.cache = cache
        self.caches = caches or {}
        self.kind = "program"

    def _count(self, addr: int) -> None:
        self.by_kind[self.kind] = self.by_kind.get(self.kind, 0) + 1
        c = self.caches.get(self.kind, self.cache)
        if c is None or not c.access(addr):
            self.reads += 1                 # only misses cost a bus cycle

    def u8(self, addr: int) -> int:
        self._count(addr)
        return self.data[addr % len(self.data)]

    def u16(self, addr: int) -> int:
        self._count(addr)
        d, n = self.data, len(self.data)
        return d[addr % n] | (d[(addr + 1) % n] << 8)

    def u32(self, addr: int) -> int:
        return self.u16(addr) | (self.u16(addr + 2) << 16)

    def write32(self, addr: int, val: int) -> None:
        for i in range(4):
            self.data[(addr + i) % len(self.data)] = (val >> (8 * i)) & 0xFF


class PPU:
    def __init__(self, mem: Memory):
        self.mem = mem
        self.pram = [0] * 256
        # Two alternating buffers, as in the RTL -- see render_frame().
        self.buffers = [[0] * INTERNAL_W, [0] * INTERNAL_W]
        self.scanbuf = self.buffers[0]
        # Persistent state, set by CLIP / BLEND, exactly as RISCBoy's CLIP works.
        self.clip_start, self.clip_end = 0, INTERNAL_W - 1
        self.blend_mode, self.blend_alpha = MODE_OPAQUE, 31
        self.blend_prio = 1
        self.win_start = self.win_end = 0
        self.win_en = self.win_out = 0
        self.stack: list[int] = []
        self.y = 0
        self.halted = False

    # -- pixel sourcing ----------------------------------------------------

    def _texel(self, base: int, fmt: int, u: int, v: int, width: int, poff: int) -> int:
        """Fetch texture pixel (u,v) and resolve it to ARGB1555.

        Sub-byte formats are little-endian *within* the byte: the
        least-significant pixel is the first displayed, matching RISCBoy 3.1."""
        self.mem.kind = "texel"
        bits = FMT_BITS[fmt]
        idx = v * width + u
        if fmt == FMT_ARGB1555:
            return self.mem.u16(base + idx * 2)
        per_byte = 8 // bits
        byte = self.mem.u8(base + idx // per_byte)
        shift = (idx % per_byte) * bits
        entry = (byte >> shift) & ((1 << bits) - 1)
        return self.pram[(entry + (poff << 5)) & 0xFF]

    def _put(self, x: int, colour: int) -> None:
        """CLIP bounds the span; the WIN window masks pixels inside it, so a
        hole can be cut without splitting the span across two commands."""
        if self.win_en:
            inside = self.win_start <= x <= self.win_end
            if not (inside ^ bool(self.win_out)):
                return
        if self.clip_start <= x <= self.clip_end and 0 <= x < INTERNAL_W:
            self.scanbuf[x] = blend_pixel(colour, self.scanbuf[x],
                                          self.blend_mode, self.blend_alpha,
                                          self.blend_prio)

    # -- pixel-producing commands -----------------------------------------

    def _fill(self, colour: int) -> None:
        for x in range(max(0, self.clip_start), min(INTERNAL_W, self.clip_end + 1)):
            self._put(x, colour)

    def _blit(self, x0: int, y0: int, size: int, poff: int, img: int, fmt: int,
              hflip: bool = False, vflip: bool = False) -> None:
        """Flipping mirrors the TEXTURE read, not the screen span: the sprite
        occupies the same pixels either way, and only the source coordinate is
        reflected. That is what lets one stored sprite face both directions,
        which is most of why the feature exists."""
        dim = 1 << (size + 3)               # 8..1024 px square
        dv = self.y - y0
        if not (0 <= dv < dim):
            return                          # this scanline misses the sprite
        tv = (dim - 1 - dv) if vflip else dv
        for du in range(dim):
            tu = (dim - 1 - du) if hflip else du
            self._put(x0 + du, self._texel(img, fmt, tu, tv, dim, poff))

    def _tile(self, xscroll: int, yscroll: int, s: int, poff: int,
              tilemap: int, pfs: int, tileset: int, fmt: int,
              wide: int = 0) -> None:
        """`wide` selects a 16-bit tilemap entry instead of an 8-bit one:

            index[7:0]  hflip[8]  vflip[9]  poff[12:10]

        The extra byte buys per-tile mirroring and a per-tile sub-palette, the
        two things a one-byte entry cannot carry. It costs one index fetch per
        tile instead of one per two tiles, which is affordable only because the
        index is now read once per tile rather than once per pixel -- at the
        original rate this would have been ruinous.
        """
        tdim = 8 << s                       # 8 or 16 px tiles
        pdim = 128 << pfs                   # playfield 128..1024 px
        v = (self.y + yscroll) % pdim
        for x in range(max(0, self.clip_start), min(INTERNAL_W, self.clip_end + 1)):
            u = (x + xscroll) % pdim
            self.mem.kind = "index"
            ent = (v // tdim) * (pdim // tdim) + u // tdim
            if wide:
                w = self.mem.u16(tilemap + ent * 2)
                tile = w & 0xFF
                tu = (tdim - 1 - u % tdim) if (w >> 8) & 1 else u % tdim
                tv = (tdim - 1 - v % tdim) if (w >> 9) & 1 else v % tdim
                tp = (w >> 10) & 0x7
            else:
                tile = self.mem.u8(tilemap + ent)
                tu, tv, tp = u % tdim, v % tdim, poff
            src = tileset + tile * tdim * tdim * FMT_BITS[fmt] // 8
            self._put(x, self._texel(src, fmt, tu, tv, tdim, tp))

    def _affine_span(self, a: tuple[int, int, int, int], b: tuple[int, int],
                     x0: int, y0: int, lo: int, hi: int, sample) -> None:
        """u = A(s - s0) + b, stepped incrementally.

        Fixed point: `a` components are signed 8.8, `b` **signed** 10.6, and
        u-space is unsigned 10.8. 8.8 and 10.8 share a fractional width, so `a`
        adds to the accumulator directly; `b` is shifted left by 2 to match.

        `b` is signed here where RISCBoy specifies unsigned. That is not a
        gratuitous change: centring a rotation requires
        b = tex/2 - A*(dim/2, dim/2), and for every rotation angle the u
        component of that is NEGATIVE (30 deg -> -5.88, 45 deg -> -6.62). With an
        unsigned b, ABLIT cannot express a centred rotation at all, which is the
        headline use for the instruction. The field is 16 bits either way, so
        signedness is free."""
        a00, a01, a10, a11 = a
        dy = self.y - y0
        u = a01 * dy + (b[0] << 2) + a00 * (lo - x0)
        v = a11 * dy + (b[1] << 2) + a10 * (lo - x0)
        for x in range(lo, hi + 1):
            sample(x, u >> 8, v >> 8)
            u += a00
            v += a10

    # -- execution ---------------------------------------------------------

    def run_scanline(self, pc: int, y: int) -> int:
        """Execute from `pc` until SYNC; return the PC that follows it.

        SYNC does not rewind. The display list is a PER-FRAME program and the
        vector is reloaded once per frame, so a scanline may run different
        commands from its neighbours -- which is what makes a linear-framebuffer
        display list possible (one BLIT per line, each a stride further on)."""
        self.y = y
        guard = 0
        while True:
            guard += 1
            if guard > 100_000:
                raise RuntimeError(f"runaway program at pc=0x{pc:05x}, y={y}")
            self.mem.kind = "program"
            w = self.mem.u32(pc)
            op = _bits(w, 31, 28)
            pc += 4

            if op == OP_SYNC:
                return pc

            elif op == OP_CLIP:
                self.clip_start, self.clip_end = _bits(w, 9, 0), _bits(w, 19, 10)

            elif op == OP_FILL:
                self._fill(pack1555(1, _bits(w, 14, 10), _bits(w, 9, 5), _bits(w, 4, 0)))

            elif op == OP_WIN:
                self.win_start, self.win_end = _bits(w, 9, 0), _bits(w, 19, 10)
                self.win_en, self.win_out = _bits(w, 20, 20), _bits(w, 21, 21)

            elif op == OP_BLEND:
                self.blend_mode, self.blend_alpha = _bits(w, 2, 0), _bits(w, 7, 3)
                self.blend_prio = 1 - _bits(w, 8, 8)   # bit 8 set == yields

            elif op == OP_PALW:
                self.pram[_bits(w, 23, 16)] = _bits(w, 15, 0)

            elif op == OP_BLIT:
                w1 = self.mem.u32(pc); pc += 4
                self._blit(_bits(w, 9, 0), _bits(w, 19, 10), _bits(w, 25, 23),
                           _bits(w, 22, 20), _bits(w1, 31, 2) << 2, _bits(w1, 1, 0),
                           bool(_bits(w, 26, 26)), bool(_bits(w, 27, 27)))

            elif op == OP_TILE:
                w1 = self.mem.u32(pc); w2 = self.mem.u32(pc + 4); pc += 8
                self._tile(_bits(w, 9, 0), _bits(w, 19, 10), _bits(w, 23, 23),
                           _bits(w, 22, 20), _bits(w1, 31, 2) << 2, _bits(w1, 1, 0),
                           _bits(w2, 31, 2) << 2, _bits(w2, 1, 0),
                           _bits(w, 24, 24))

            elif op in (OP_ABLIT, OP_ATILE):
                w1, w2, w3 = (self.mem.u32(pc), self.mem.u32(pc + 4), self.mem.u32(pc + 8))
                pc += 12
                b = (_sign16(_bits(w1, 15, 0)), _sign16(_bits(w1, 31, 16)))
                a = (_sign16(_bits(w2, 15, 0)), _sign16(_bits(w2, 31, 16)),
                     _sign16(_bits(w3, 15, 0)), _sign16(_bits(w3, 31, 16)))
                poff = _bits(w, 22, 20)

                if op == OP_ABLIT:
                    w4 = self.mem.u32(pc); pc += 4
                    x0, y0 = _bits(w, 9, 0), _bits(w, 19, 10)
                    size, half = _bits(w, 25, 23), _bits(w, 26, 26)
                    dim = 1 << (size + 3)
                    tex = dim >> 1 if half else dim
                    img, fmt = _bits(w4, 31, 2) << 2, _bits(w4, 1, 0)

                    def sample(x, u, v, _t=tex, _i=img, _f=fmt, _p=poff):
                        if 0 <= u < _t and 0 <= v < _t:
                            self._put(x, self._texel(_i, _f, u, v, _t, _p))

                    lo = max(x0, self.clip_start)
                    hi = min(x0 + dim - 1, self.clip_end)
                    if lo <= hi:
                        self._affine_span(a, b, x0, y0, lo, hi, sample)
                else:
                    w4, w5 = self.mem.u32(pc), self.mem.u32(pc + 4); pc += 8
                    x0, y0 = _bits(w, 9, 0), _bits(w, 19, 10)
                    tdim = 8 << _bits(w, 23, 23)
                    pdim = 128 << _bits(w4, 1, 0)
                    tmap, tset, fmt = _bits(w4, 31, 2) << 2, _bits(w5, 31, 2) << 2, _bits(w5, 1, 0)

                    def sample(x, u, v):
                        u, v = u % pdim, v % pdim
                        self.mem.kind = "index"
                        tile = self.mem.u8(tmap + (v // tdim) * (pdim // tdim) + u // tdim)
                        src = tset + tile * tdim * tdim * FMT_BITS[fmt] // 8
                        self._put(x, self._texel(src, fmt, u % tdim, v % tdim, tdim, poff))

                    lo, hi = max(0, self.clip_start), min(INTERNAL_W - 1, self.clip_end)
                    if lo <= hi:
                        self._affine_span(a, b, x0, y0, lo, hi, sample)

            elif op == OP_BLITLIST:
                count, ptr = _bits(w, 27, 20), _bits(w, 19, 0) << 2
                for i in range(count):
                    d0, d1 = self.mem.u32(ptr + i * 8), self.mem.u32(ptr + i * 8 + 4)
                    self._blit(_bits(d0, 9, 0), _bits(d0, 19, 10), _bits(d0, 25, 23),
                               _bits(d0, 22, 20), _bits(d1, 31, 2) << 2, _bits(d1, 1, 0),
                               bool(_bits(d0, 26, 26)), bool(_bits(d0, 27, 27)))

            elif op == OP_PUSH:
                self.stack.append(self.mem.u32(pc)); pc += 4
                if len(self.stack) > 8:
                    self.stack.pop(0)       # 8 deep, wraps -- RISCBoy 3.4

            elif op == OP_POPJ:
                target = self.stack.pop() if self.stack else 0
                cc, arg = _bits(w, 24, 23), _bits(w, 9, 0)
                if cc == CC_ALWAYS or (cc == CC_YLT and self.y < arg) \
                        or (cc == CC_YGE and self.y >= arg):
                    pc = target

            else:
                raise RuntimeError(f"illegal opcode 0x{op:x} at pc=0x{pc - 4:05x}")

    def render_frame(self, pc: int) -> list[list[int]]:
        """400x300 of ARGB1555.

        Scanbuf contents persist between lines rather than being cleared -- if
        you want a background colour you must FILL it every line (RISCBoy 3.4).
        There are TWO buffers alternating, so line N inherits what line N-2 left
        behind, NOT line N-1. Modelling a single persistent buffer here would
        silently disagree with the hardware on any program that does not FILL,
        and the RTL bench would then be checking against the wrong answer."""
        return [self._render_line(pc, y) for y in range(INTERNAL_H)]

    def _render_line(self, pc: int, y: int) -> list[int]:
        # The vector is reloaded at the frame boundary only; within a frame the
        # PC flows on from wherever the previous line's SYNC left it.
        if y == 0 or not hasattr(self, "_pc"):
            self._pc = pc
        self.scanbuf = self.buffers[y & 1]
        self._pc = self.run_scanline(self._pc, y)
        return list(self.scanbuf)


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def frame_to_rgb8(frame: list[list[int]], double: bool = True) -> list[bytearray]:
    """ARGB1555 frame -> rows of 8-bit RGB, pixel- and line-doubled as the
    display does. 5 -> 8 bits by bit replication, which is what the digital
    path produces for an external encoder or panel."""
    w, h = (DISPLAY_W, DISPLAY_H) if double else (INTERNAL_W, INTERNAL_H)
    rows = []
    for y in range(h):
        src = frame[y // 2 if double else y]
        row = bytearray()
        for x in range(w):
            _, r, g, b = unpack1555(src[x // 2 if double else x])
            row += bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))
        rows.append(row)
    return rows


def write_png(path: str, rows: list) -> None:
    """Minimal 8-bit RGB PNG. Written by hand rather than with Pillow so the
    benches have no dependency beyond the standard library -- zlib is in it and
    Pillow is not guaranteed to be in the nix-shell."""
    import struct
    import zlib

    height = len(rows)
    width = len(rows[0]) // 3
    raw = b"".join(b"\x00" + bytes(r) for r in rows)      # filter type 0 per row

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9))
                + chunk(b"IEND", b""))


def to_png(frame: list[list[int]], path: str, double: bool = True) -> None:
    write_png(path, frame_to_rgb8(frame, double))


def to_ppm(frame: list[list[int]], path: str, double: bool = True) -> None:
    """Write P6 PPM, pixel- and line-doubled to 800x600 as the display does."""
    w, h = (DISPLAY_W, DISPLAY_H) if double else (INTERNAL_W, INTERNAL_H)
    out = bytearray(f"P6\n{w} {h}\n255\n".encode())
    for y in range(h):
        row = frame[y // 2 if double else y]
        for x in range(w):
            _, r, g, b = unpack1555(row[x // 2 if double else x])
            # 5 -> 8 bits by bit replication, which is what the digital RGB555
            # path does for an external encoder or panel.
            out += bytes(((r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2)))
    with open(path, "wb") as f:
        f.write(out)


# --------------------------------------------------------------------------
# Assembler helpers, for tests and demos
# --------------------------------------------------------------------------

def sync():                 return [OP_SYNC << 28]
def clip(s, e):             return [(OP_CLIP << 28) | (e << 10) | s]
def win(s, e, en=1, out=0):
    """Second window. `out=0` draws only inside [s,e]; `out=1` draws only
    outside it. `en=0` disables masking entirely."""
    return [(OP_WIN << 28) | (int(out) << 21) | (int(en) << 20) | (e << 10) | s]
def fill(r, g, b):          return [(OP_FILL << 28) | (r << 10) | (g << 5) | b]
def blend(mode, alpha=31, behind=False):
    """bit 8 marks subsequent pixels as YIELDING: they will not overwrite a
    pixel already written at normal priority. Clear by default, so a plain
    BLEND behaves exactly as it always has. See blend_pixel."""
    return [(OP_BLEND << 28) | (int(behind) << 8) | (alpha << 3) | mode]
def palw(i, c):             return [(OP_PALW << 28) | (i << 16) | c]
def push(v):                return [(OP_PUSH << 28), v]
def popj():                 return [(OP_POPJ << 28)]


# --------------------------------------------------------------------------
# Linear framebuffer -- the `simple-framebuffer` path
#
# Normative reference for rtl/ppu_fbscan.v. The format codes are FB_CTRL.FMT and
# the names are the kernel's, from SIMPLEFB_FORMATS in
# include/linux/platform_data/simplefb.h.
# --------------------------------------------------------------------------

FB_A1R5G5B5, FB_X1R5G5B5, FB_R5G6B5, FB_X8R8G8B8, FB_R5G5B5A1 = 0, 1, 2, 3, 4

FB_FORMAT_NAMES = {FB_A1R5G5B5: "a1r5g5b5", FB_X1R5G5B5: "x1r5g5b5",
                   FB_R5G6B5: "r5g6b5", FB_X8R8G8B8: "x8r8g8b8",
                   FB_R5G5B5A1: "r5g5b5a1"}
FB_BPP = {FB_A1R5G5B5: 16, FB_X1R5G5B5: 16, FB_R5G6B5: 16, FB_X8R8G8B8: 32,
          FB_R5G5B5A1: 16}


def fb_convert(fmt: int, raw: int) -> int:
    """One source pixel to the internal ARGB1555.

    Alpha is forced opaque in every format: the framebuffer engine writes the
    scanline buffer directly, nothing downstream of it tests alpha, and
    drm_sysfb's to_nonalpha_fourcc() rewrites every native alpha format to its
    non-alpha twin before userspace sees it anyway, so a framebuffer whose alpha
    bit happens to be clear must not come out different from one whose alpha bit
    is set.
    """
    if fmt in (FB_A1R5G5B5, FB_X1R5G5B5):
        return 0x8000 | (raw & 0x7FFF)
    if fmt == FB_R5G6B5:
        # Green loses its LSB. Both paths out of this chip are 5 bits per gun.
        return 0x8000 | ((raw >> 11) << 10) | (((raw >> 6) & 0x1F) << 5) | (raw & 0x1F)
    if fmt == FB_R5G5B5A1:
        # Alpha in the LOW bit -- this is what arch/mips/n64 ships.
        return 0x8000 | ((raw >> 11) << 10) | (((raw >> 6) & 0x1F) << 5) | ((raw >> 1) & 0x1F)
    b, g, r = raw & 0xFF, (raw >> 8) & 0xFF, (raw >> 16) & 0xFF
    return 0x8000 | ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)


def fb_line(mem: "Memory", y: int, base: int, stride: int,
            w: int = INTERNAL_W, h: int = INTERNAL_H,
            fmt: int = FB_A1R5G5B5) -> list[int]:
    """The internal scanline the framebuffer engine produces for display line y.

    Always INTERNAL_W entries: a framebuffer narrower or shorter than the
    display is legal in the binding, and the hardware blanks the remainder
    rather than leaving whatever was in the buffer two frames ago.
    """
    # The list is as long as the INTERNAL LINE of the current mode -- 320 for
    # the fixed 640x480 design, up to 640 for the programmable-CRTC HD modes --
    # and a framebuffer narrower than that is blank-padded, as the hardware
    # blanks it.
    int_w = max(w, INTERNAL_W) if w > INTERNAL_W else INTERNAL_W
    out = [0] * int_w
    if y >= h:
        return out
    px = FB_BPP[fmt] // 8
    row = base + y * stride
    for x in range(min(w, int_w)):
        raw = mem.u32(row + x * px) if px == 4 else mem.u16(row + x * px)
        out[x] = fb_convert(fmt, raw)
    return out


def fb_write_line(mem: "Memory", y: int, pixels: list[int], base: int,
                  stride: int, fmt: int = FB_A1R5G5B5) -> None:
    """Put one row of already-encoded source pixels into memory, as a driver
    would with a memcpy into the mapped framebuffer."""
    px = FB_BPP[fmt] // 8
    for x, v in enumerate(pixels):
        addr = base + y * stride + x * px
        for i in range(px):
            mem.data[(addr + i) % len(mem.data)] = (v >> (8 * i)) & 0xFF


def framebuffer_list(fb_base: int, at: int, mem: "Memory",
                     w: int = INTERNAL_W, h: int = INTERNAL_H) -> int:
    """Emit a display list that scans out a LINEAR framebuffer, and return `at`.

    SUPERSEDED by the hardware engine above (FB_CTRL.FB_EN, rtl/ppu_fbscan.v),
    which is what makes this a device simpledrm can bind to. This remains as the
    software fallback: it puts a flat framebuffer on the screen using only the
    render path, which is useful for bring-up and for a host that wants a
    framebuffer composited with rendered layers. It is NOT compliant on its own
    -- the geometry lives in the program rather than in registers, the fetches
    go through the texel cache, and `stride` cannot differ from `width * 2`
    without rebuilding all `h` entries.

    Each BLIT sets y to its own line, so dv is 0 and the texel address collapses
    to img_base + u*2: a straight linear read of that row. img advances one
    stride per line. `size` only has to make the square at least as wide as the
    screen; the CLIP bounds the span, and height is irrelevant because only row 0
    is ever touched.

    The framebuffer is ARGB1555, which is byte-identical to the kernel's
    `a1r5g5b5` in SIMPLEFB_FORMATS -- red at bit 10, green 5, blue 0, alpha 15.
    No conversion anywhere.
    """
    size = 0
    while (8 << size) < w:
        size += 1
    words = clip(0, w - 1)
    for y in range(h):
        words += blit(0, y, size, fb_base + y * w * 2, FMT_ARGB1555) + sync()
    assemble(words, mem, at)
    return at


def loop_to(addr):
    """Make a per-scanline program repeat: SYNC does not rewind the PC."""
    return push(addr) + popj()


def blit(x, y, size, img, fmt, poff=0, hflip=False, vflip=False):
    """bit 26 mirrors horizontally, bit 27 vertically. Both are free in BLIT's
    encoding; ABLIT uses bit 26 for its half-texture flag, so flipping applies
    to plain BLIT (and BLITLIST descriptors, which share the layout) only."""
    return [(OP_BLIT << 28) | (int(vflip) << 27) | (int(hflip) << 26)
            | (size << 23) | (poff << 20) | (y << 10) | x,
            (img & ~3) | fmt]


def tile(xs, ys, s, tilemap, pfs, tileset, fmt, poff=0, wide=False):
    """`wide` switches the tilemap to 16-bit entries carrying per-tile flip and
    sub-palette; see PPU._tile."""
    return [(OP_TILE << 28) | (int(wide) << 24) | (s << 23) | (poff << 20) | (ys << 10) | xs,
            (tilemap & ~3) | pfs, (tileset & ~3) | fmt]


def ablit(x, y, size, img, fmt, a, b, poff=0, half=0):
    return [(OP_ABLIT << 28) | (half << 26) | (size << 23) | (poff << 20) | (y << 10) | x,
            ((b[1] & 0xFFFF) << 16) | (b[0] & 0xFFFF),
            ((a[1] & 0xFFFF) << 16) | (a[0] & 0xFFFF),
            ((a[3] & 0xFFFF) << 16) | (a[2] & 0xFFFF),
            (img & ~3) | fmt]


def atile(xs, ys, s, tilemap, pfs, tileset, fmt, a, b, poff=0):
    return [(OP_ATILE << 28) | (s << 23) | (poff << 20) | (ys << 10) | xs,
            ((b[1] & 0xFFFF) << 16) | (b[0] & 0xFFFF),
            ((a[1] & 0xFFFF) << 16) | (a[0] & 0xFFFF),
            ((a[3] & 0xFFFF) << 16) | (a[2] & 0xFFFF),
            (tilemap & ~3) | pfs, (tileset & ~3) | fmt]


def assemble(words: list[int], mem: Memory, at: int) -> int:
    for i, w in enumerate(words):
        mem.write32(at + i * 4, w & 0xFFFFFFFF)
    return at


# --------------------------------------------------------------------------
# Self-test
# --------------------------------------------------------------------------

def selftest() -> int:
    fails = []

    def check(cond, what):
        if not cond:
            fails.append(what)

    # Blend endpoints -- the cases a careless implementation gets wrong.
    check(blend_alpha(31, 0, 0) == 0, "alpha a=0 must yield dst exactly")
    check(blend_alpha(0, 31, 0) == 31, "alpha a=0 must yield dst exactly (2)")
    check(blend_mul(31, 31) == 31, "multiply 31*31 must saturate to 31, not 30")
    check(blend_mul(0, 31) == 0, "multiply by zero must be zero")
    check(blend_mul(31, 16) == 16, "multiply by unity must be identity")
    check(blend_add(31, 31, 31) == 31, "additive must clamp at 31")
    check(blend_sub(31, 0, 31) == 0, "subtractive must clamp at 0")
    for a in range(32):
        check(0 <= blend_alpha(31, 0, a) <= 31, f"alpha out of range at a={a}")

    # Transparency is a hard test in every mode.
    for mode in range(5):
        check(blend_pixel(0x0000, 0x7FFF, mode, 31) == 0x7FFF,
              f"A=0 must not write in mode {mode}")

    # Pack/unpack round trip.
    for v in (0x0000, 0x7FFF, 0xFFFF, 0x1234):
        check(pack1555(*unpack1555(v)) == v, f"1555 round trip failed for {v:#06x}")

    # A program that exercises the sub-byte unpacker and PRAM offsetting.
    mem = Memory()
    ppu = PPU(mem)
    for i in range(256):
        ppu.pram[i] = pack1555(1, i & 0x1F, (i >> 2) & 0x1F, (i >> 3) & 0x1F)
    mem.data[0x1000:0x1008] = bytes([0x10, 0x32, 0x54, 0x76] * 2)   # P4 texels
    prog = assemble(clip(0, INTERNAL_W - 1) + blit(0, 0, 0, 0x1000, FMT_P4) + sync(), mem, 0)
    ppu.run_scanline(prog, 0)
    # P4 little-endian within the byte: low nibble first.
    check(ppu.scanbuf[0] == ppu.pram[0x0], "P4 pixel 0 should be low nibble")
    check(ppu.scanbuf[1] == ppu.pram[0x1], "P4 pixel 1 should be high nibble")

    # CLIP must actually clip.
    ppu2 = PPU(mem)
    assemble(clip(10, 20) + fill(31, 0, 0) + sync(), mem, 0x2000)
    ppu2.run_scanline(0x2000, 0)
    check(ppu2.scanbuf[9] == 0, "pixel left of clip must be untouched")
    check(ppu2.scanbuf[10] == pack1555(1, 31, 0, 0), "clip start must be written")
    check(ppu2.scanbuf[20] == pack1555(1, 31, 0, 0), "clip end is inclusive")
    check(ppu2.scanbuf[21] == 0, "pixel right of clip must be untouched")

    if fails:
        print(f"FAIL -- {len(fails)} check(s):", file=sys.stderr)
        for f in fails:
            print(f"  {f}", file=sys.stderr)
        return 1
    print("selftest: all checks passed")
    return 0


# --------------------------------------------------------------------------
# Demo -- exercises every opcode, which is what G5 needs
# --------------------------------------------------------------------------

def demo_scene(mem: Memory, ppu: "PPU") -> int:
    """Build the demo scene into `mem`/`ppu` and return its program vector.

    Split out of demo() so the RTL bench can render the SAME scene through real
    silicon and diff the two images -- see tb/ppu_render_png.py.

    This scene is sized to what the hardware sustains at 59.52 Hz: measured
    worst case 1491 of the 1600 core clocks in an internal line, over a full
    240-line frame, with tb/ppu_throughput_probe.py gating it there. It is NOT
    the opcode-coverage vehicle it used to claim to be -- fitting the budget
    meant a half-width playfield, three banded sprites and a tightly clipped
    affine blit, which no longer exercises every opcode or all five blend
    modes. tb/ppu_tb.py's 13 scenes are what cover those, one opcode at a time
    and without a frame-rate constraint.
    """
    TILESET, TILEMAP, SPRITE, PROG, SUBR = 0x1000, 0x2000, 0x3000, 0x8000, 0x9000
    TILESET2, TILEMAP2 = 0xC000, 0xD000

    for i in range(256):                                   # palette ramp
        ppu.pram[i] = pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    ppu.pram[0] = 0                                        # index 0 transparent

    for t in range(4):                                     # four 16x16 P8 tiles
        for v in range(16):
            for u in range(16):
                edge = u in (0, 15) or v in (0, 15)
                mem.data[TILESET + t * 256 + v * 16 + u] = (1 + t * 8) if edge else (200 + t * 8)
    for i in range(64 * 64):                               # 1024px playfield
        mem.data[TILEMAP + i] = (i + (i // 64)) % 4

    # Foreground playfield: mostly palette index 0, the hard transparency, so
    # the background layer shows through its gaps. Two independently scrolled
    # indexed layers on one scanline is the thing a 16-bit console gets from
    # having several hardware background planes.
    for t in range(4):
        for v in range(16):
            for u in range(16):
                ring = (u in (0, 15) or v in (0, 15)) and ((u + v + t) % 3 != 0)
                mem.data[TILESET2 + t * 256 + v * 16 + u] = (60 + t * 40) if ring else 0
    for i in range(64 * 64):
        mem.data[TILEMAP2 + i] = (i * 5 + (i // 64) * 3) % 4

    for v in range(32):                                    # a round-ish sprite
        for u in range(32):
            inside = (u - 16) ** 2 + (v - 16) ** 2 < 200
            mem.write32(SPRITE + (v * 32 + u) * 2,
                        pack1555(1, 31, u, v) if inside else 0)

    # Per-scanline subroutine: the same 32 px sprite three times, opaque then
    # alpha then additive, so the blend modes are visible SIDE BY SIDE over the
    # tiled background.
    #
    # These coordinates were 300/330/360, which is off the right-hand edge of a
    # 320 px screen -- they are left over from the 400x300 internal resolution
    # this design used when it targeted 800x600. The result was that the demo
    # claimed to cover every blend mode (README section 11, G5) while drawing
    # two of them entirely outside the visible area.
    # The blended sprites sit OVER the playfield, not over the flat panel: a
    # sprite's cost does not depend on x, and alpha and additive blending
    # against a tiled background is the thing worth showing. Their y bands are
    # 40/100/160, which the BLITLIST descriptors below avoid.
    assemble(
        blit(40, 40, 2, SPRITE, FMT_ARGB1555)
        + blend(MODE_ALPHA, 16)
        + blit(150, 100, 2, SPRITE, FMT_ARGB1555)
        + blend(MODE_ADD, 20)
        + blit(252, 160, 2, SPRITE, FMT_ARGB1555)
        + blend(MODE_OPAQUE)
        + [(OP_POPJ << 28)], mem, SUBR)

    # BLITLIST descriptors. Three, not six, and placed in scanline bands that
    # miss the subroutine's sprites at y=40/100/160 -- see the budget note
    # above `head`. A BLIT that misses a line costs only its instruction
    # overhead, so keeping sprites off each other's bands is what bounds the
    # WORST line rather than the average one.
    sprites = 0xA000
    # d0 is (size << 23) | (poff << 20) | (y << 10) | x -- y in [19:10], x in
    # [9:0], the same packing blit() uses. Getting that pair the wrong way
    # round puts sprites off the playfield without failing any test, since the
    # model and the RTL read the same descriptor and agree either way.
    for i, (sx, sy) in enumerate(((24, 0), (120, 0), (216, 0),
                                  (60, 196), (200, 196), (140, 228))):
        mem.write32(sprites + i * 8, (2 << 23) | (sy << 10) | sx)
        mem.write32(sprites + i * 8 + 4, (SPRITE & ~3) | FMT_ARGB1555)

    # CALLING A SUBROUTINE NEEDS THE RETURN ADDRESS PUSHED FIRST
    # ----------------------------------------------------------
    # There is no call instruction: POPJ pops an address and jumps, and popping
    # an empty stack jumps to 0. `PUSH SUBR; POPJ` is therefore a one-way jump,
    # and the subroutine's own POPJ falls into address 0 -- where the whole
    # program is zeros, opcode 0 is SYNC, and every line after the first ends
    # immediately having drawn nothing. That is what this scene used to do: 5
    # unique colours in the frame and 320 texel fetches for the WHOLE frame
    # instead of per line. Push the return address, then the target.
    # DRAWING THIS SCENE INSIDE ONE SCANLINE'S BUDGET
    # -----------------------------------------------
    # An internal line is 1600 core clocks and the full-width P8 playfield
    # costs ~1194 of them, so roughly 400 remain for everything else. The scene
    # this replaces spent them badly and underran on 74% of lines even after
    # the tile-index fix. Two costs were pure waste:
    #
    #   * A full-width FILL, then an opaque full-width TILE straight over it.
    #     No tile texel is palette index 0, the transparent one, so every
    #     filled pixel was overwritten -- 316 clocks a line for nothing. FILL
    #     is kept in the list for opcode coverage but clipped to 32 pixels, so
    #     it costs ~33 clocks instead of 316. It is still overdrawn by the
    #     playfield; tb/ppu_tb.py's `fill` scene is what actually verifies the
    #     opcode, and drawing it over the playfield instead just put a bar
    #     down the edge of the showcase frame.
    #
    #   * An ABLIT with no CLIP around it. An affine op takes its span from
    #     clip_start..clip_end because an affine map can land anywhere, and
    #     each pixel outside the texture still costs two states. One 32 px
    #     sprite therefore walked all 320 pixels of all 240 lines: 678 clocks
    #     a line, writing nothing on the ~195 lines it does not touch. CLIP is
    #     the mechanism for bounding it, and this scene simply never used it.
    #
    # An affine op cannot reject by scanline the way BLIT does, so its clipped
    # span is paid on every line -- keep the window tight.
    head = (clip(0, INTERNAL_W - 1)
            + palw(255, pack1555(1, 31, 31, 31))
            # THE PLAYFIELD IS FULL WIDTH AGAIN
            # ---------------------------------
            # It was briefly half the screen with a flat panel beside it,
            # because a tiled pixel cost 3.76 core clocks and 320 of them ate
            # 1195 of an internal line's 1600 -- the scene missed every line.
            # Folding S_SPAN out of ppu_cmd's fetch loop took a tiled pixel to
            # 2.87 clocks, so a full-width playfield is 914 clocks and the
            # whole scene fits again: worst line 1430 of 1600 over a full
            # frame, measured, with tb/ppu_throughput_probe.py gating it.
            #
            # The FILL is kept clipped to 32 px and overdrawn: it is here for
            # opcode presence, and tb/ppu_tb.py's `fill` scene is what verifies
            # the opcode. A full-width FILL under an opaque playfield was 316
            # clocks a line for pixels nobody ever sees.
            + clip(0, 31) + fill(2, 2, 8) + clip(0, INTERNAL_W - 1)
            + tile(0, 0, 1, TILEMAP, 3, TILESET, FMT_P8)
            # The foreground layer covers the left 128 px rather than the
            # full width. Two full-width indexed layers cost 1194 of an
            # internal line's 1600 clocks -- see the `parallax` scene, which
            # proves that case -- but this scene also carries an affine blit,
            # six sprites and a subroutine, and the total ran 12% over. CLIP
            # bounds a layer the same way it bounds anything else.
            + clip(0, 127)
            + tile(53, 19, 1, TILEMAP2, 3, TILESET2, FMT_P8)
            + clip(0, INTERNAL_W - 1)
            # 30 deg rotation, texture shrunk to ~1/1.4 so the corners stay
            # inside the 32 px region. b centres it -- and is negative in u,
            # which is exactly the case an unsigned b could not express.
            + clip(168, 248)
            + ablit(190, 30, 2, SPRITE, FMT_ARGB1555,
                    a=(310, 179, -179, 310), b=(-932, 500))
            + clip(0, INTERNAL_W - 1)
            + [(OP_BLITLIST << 28) | (6 << 20) | (sprites >> 2)])
    call = push(0) + push(SUBR) + popj()          # push(0) patched below
    ret_addr = PROG + 4 * (len(head) + len(call))
    call[1] = ret_addr

    # And the list must LOOP: SYNC ends the scanline but does not rewind the PC,
    # so without loop_to() the next line runs off the end of the program.
    assemble(head + call + sync() + loop_to(PROG), mem, PROG)

    return PROG


def demo(path: str) -> int:
    mem = Memory()
    ppu = PPU(mem)
    prog = demo_scene(mem, ppu)

    frame = ppu.render_frame(prog)
    (to_png if path.endswith(".png") else to_ppm)(frame, path)

    # G4 instrumentation: worst-case sustained fetch against the 80 MB/s budget.
    per_line = mem.reads / INTERNAL_H
    budget = 1056 * 2                                      # core clocks per internal line
    print(f"demo written to {path}  ({DISPLAY_W}x{DISPLAY_H})")
    print(f"  memory reads: {mem.reads} total, {per_line:.0f}/line "
          f"vs {budget} cycles available -> {per_line / budget:.0%} of bus")
    if per_line > budget:
        print("  WARNING: program exceeds the per-line fetch budget")
    return 0


def _atile_scene(mem: Memory, ppu: PPU, scale: float) -> int:
    """Full-width affine-tiled layer -- the heaviest tile-index workload there is,
    and the only case an on-chip tilemap RAM was ever going to justify."""
    import math
    TILESET, TILEMAP, PROG = 0x1000, 0x2000, 0x8000
    for i in range(256):
        ppu.pram[i] = pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    for t in range(4):
        for v in range(16):
            for u in range(16):
                edge = u in (0, 15) or v in (0, 15)
                mem.data[TILESET + t * 256 + v * 16 + u] = (1 + t * 8) if edge else (200 + t * 8)
    for i in range(64 * 64):
        mem.data[TILEMAP + i] = (i + (i // 64)) % 4

    th = math.radians(30)
    c, s = math.cos(th) * scale, math.sin(th) * scale
    a = (round(c * 256), round(s * 256), round(-s * 256), round(c * 256))
    assemble(clip(0, INTERNAL_W - 1)
             + atile(0, 0, 1, TILEMAP, 3, TILESET, FMT_P8, a=a, b=(0, 0))
             + sync(), mem, PROG)
    return PROG


def cache_sweep() -> int:
    """Decide the tile-index strategy from measurement, not from argument.

    Three options are on the table, all serving affine tiling:
      (a) fetch indices over the bus, no help          -- 0 mm2
      (b) small direct-mapped cache on the fetch path  -- ~0 mm2 (registers)
      (c) 1 KB on-chip tilemap RAM, 2x sram512x8       -- 0.419 mm2
    """
    BUDGET = 1056 * 2                       # core clocks per internal line

    print("Full-width ATILE, 16x16 P8 tiles, 30 deg rotation.")
    print(f"Per-line budget at 1 px/clk: {BUDGET} core clocks, {INTERNAL_W} px active.\n")

    for scale in (0.5, 1.0, 2.0):
        base_mem = Memory()
        base_ppu = PPU(base_mem)
        base_mem.kind = "program"
        prog = _atile_scene(base_mem, base_ppu, scale)
        base_ppu.render_frame(prog)
        n = INTERNAL_H
        tex = base_mem.by_kind["texel"] / n
        idx = base_mem.by_kind["index"] / n
        tot = base_mem.reads / n

        label = {0.5: "2x magnified", 1.0: "unit scale", 2.0: "2x minified"}[scale]
        print(f"--- {label} (a00 = {round(0.866 * scale * 256)}) ---")
        print(f"  no cache        texel {tex:6.0f} + index {idx:6.0f} = "
              f"{tot:6.0f}/line  {tot / BUDGET:5.0%} of bus")

        for entries in (1, 2, 4, 8, 16, 64):
            m = Memory(cache=Cache(entries))
            p = PPU(m)
            m.kind = "program"
            p.render_frame(_atile_scene(m, p, scale))
            per = m.reads / n
            print(f"  cache {entries:3} lines  hit {m.cache.hit_rate:5.1%}"
                  f"{'':17}{per:6.0f}/line  {per / BUDGET:5.0%} of bus")

        onchip = (base_mem.reads - base_mem.by_kind["index"]) / n
        print(f"  on-chip tilemap {'':29}{onchip:6.0f}/line  "
              f"{onchip / BUDGET:5.0%} of bus   [costs 0.419 mm2]\n")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--demo", metavar="OUT.ppm")
    ap.add_argument("--cache-sweep", action="store_true",
                    help="measure the tile-index workload and size the cache")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.cache_sweep:
        return cache_sweep()
    if args.demo:
        return demo(args.demo)
    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
