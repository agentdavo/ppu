# SPDX-License-Identifier: Apache-2.0
"""
Measure the command processor's sustained line rate against the display.

    PPU_SCENE=demo python3 tb/ppu_throughput_probe.py
    PPU_PROBE_LINES=40 PPU_SCENE=demo python3 tb/ppu_throughput_probe.py

`tb/ppu_render_png.py` shows THAT the renderer falls behind -- lines repeat and
the image stretches vertically. It cannot show WHY, because it only samples
pixels. This probe watches the internals instead and answers three questions:

    1. How many core clocks does one rendered line actually take, against the
       1600 available (two 800-clock display lines, since both axes double)?
    2. Is the shortfall memory or compute? `f_req && !f_ack` counts cycles the
       fetch path stalled; `f_ack` counts cycles it delivered.
    3. Where do the cycles go? A histogram over ppu_cmd's state register
       attributes every clock to a pipeline phase.

It also samples the `underrun` output, which is the design's own signal that a
line buffer missed its swap.
"""

from pathlib import Path
import collections
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb_tools.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ppu_model as M  # noqa: E402
from aps12808 import idle_burst_port, psram_burst_server  # noqa: E402
from ppu_render_png import build_scene  # noqa: E402
from ppu_tb import clear_scanbufs, load_pram, mem_server  # noqa: E402

CLK_NS = 40
H_TOTAL = 800
LINES = int(os.environ.get("PPU_PROBE_LINES", "30"))

STATE_NAMES = ["IDLE", "IF0", "IF1", "DEC", "ARG0", "ARG1", "SPAN", "IDX0",
               "IDX1", "TEX0", "TEX1", "AFF", "NEXT", "HALT", "BLD0", "BLD1"]


def micro_scene(kind):
    """One opcode, full width, nothing else -- to price it in isolation.

    `fill` is the cheapest possible span: no fetches at all, so it measures the
    raw span-walk rate against the README's "1 pixel per clock" premise.
    `tile` is a full-width P8 playfield, the demo's dominant cost.
    `blit` is a single 32 px direct-colour sprite.
    """
    from ppu_tb import R_CTRL, R_PC, apb_write

    mem = M.Memory()
    ppu = M.PPU(mem)
    TILESET, TILEMAP, SPRITE, PROG = 0x1000, 0x2000, 0x3000, 0x8000

    for i in range(256):
        ppu.pram[i] = M.pack1555(1, i & 0x1F, 31 - (i & 0x1F), (i >> 3) & 0x1F)
    for t in range(4):
        for v in range(16):
            for u in range(16):
                edge = u in (0, 15) or v in (0, 15)
                mem.data[TILESET + t * 256 + v * 16 + u] = (1 + t * 8) if edge else (200 + t * 8)
    for i in range(64 * 64):
        mem.data[TILEMAP + i] = (i + (i // 64)) % 4
    for v in range(32):
        for u in range(32):
            inside = (u - 16) ** 2 + (v - 16) ** 2 < 200
            mem.write32(SPRITE + (v * 32 + u) * 2,
                        M.pack1555(1, 31, u, v) if inside else 0)

    # demolean: the demo scene with its two measured wastes removed -- the
    # full-width FILL that the opaque full-width TILE completely overdraws,
    # and the ABLIT that walks all 320 pixels of every scanline. Everything
    # that puts visible pixels on the screen is retained.
    sprites = 0xA000
    for i in range(6):
        mem.write32(sprites + i * 8, (2 << 23) | ((40 + i * 30) << 10) | (20 + i * 40))
        mem.write32(sprites + i * 8 + 4, (SPRITE & ~3) | M.FMT_ARGB1555)

    # A second tileset whose tiles are mostly palette index 0 -- the hard
    # transparency -- so a foreground playfield drawn over the first one shows
    # it through the gaps. Without transparent texels a second TILE would just
    # overwrite the first and prove nothing about layering.
    TILESET2, TILEMAP2 = 0x6000, 0x7000
    for t in range(4):
        for v in range(16):
            for u in range(16):
                solid = (u < 6 and v < 6) or (u > 9 and v > 9)
                mem.data[TILESET2 + t * 256 + v * 16 + u] = (100 + t * 8) if solid else 0
    for i in range(64 * 64):
        mem.data[TILEMAP2 + i] = (i * 3 + (i // 64) * 5) % 4

    # A sprite-game workload: many sprites in one BLITLIST, spread down the
    # screen so only one or two touch any given scanline. What this prices is
    # not sprite PIXELS but the per-descriptor evaluation the walker pays for
    # every sprite on the list, hit or miss -- the thing that decides how many
    # sprites a game can have on screen at all.
    # A 4bpp sprite: four texels per 16-bit fetch instead of ARGB1555's one.
    # 16-colour sprites are what sprite-oriented hardware of this class
    # conventionally uses, and the fetch arithmetic is why.
    SPRITE4 = 0xE000
    for v in range(64):
        for u in range(64):
            inside = (u - 32) ** 2 + (v - 32) ** 2 < 900
            idx = (1 + ((u >> 2) + (v >> 2)) % 15) if inside else 0
            off = SPRITE4 + (v * 64 + u) // 2
            if u & 1:
                mem.data[off] = (mem.data[off] & 0x0F) | (idx << 4)
            else:
                mem.data[off] = (mem.data[off] & 0xF0) | idx

    many = 0xB000
    for i in range(128):
        mem.write32(many + i * 8, (2 << 23) | (((i * 7) % 272) << 10) | ((i * 9) % 288))
        mem.write32(many + i * 8 + 4, (SPRITE & ~3) | M.FMT_ARGB1555)

    body = {
        "fill": M.fill(2, 2, 8),
        "sprites32": [(M.OP_BLITLIST << 28) | (32 << 20) | (many >> 2)],
        "sprites64": [(M.OP_BLITLIST << 28) | (64 << 20) | (many >> 2)],
        "sprites128_bg": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                          + [(M.OP_BLITLIST << 28) | (128 << 20) | (many >> 2)]),
        "sprites64_bg": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                         + [(M.OP_BLITLIST << 28) | (64 << 20) | (many >> 2)]),
        "sprites32_bg": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                         + [(M.OP_BLITLIST << 28) | (32 << 20) | (many >> 2)]),
        # Two-layer parallax: two independently scrolled indexed playfields on
        # one scanline, the foreground transparent in places. This is the
        # capability a 16-bit console gets from having several hardware
        # background layers, and it only fits here because a tiled pixel came
        # down to ~1.9 clocks -- at the original 3.76 two layers needed 2400
        # clocks against a 1600-clock line.
        "parallax": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                     + M.tile(37, 11, 1, TILEMAP2, 3, TILESET2, M.FMT_P8)),
        # Two layers plus sprite work, which is what a real game scanline
        # looks like.
        "parallax_spr": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                         + M.tile(37, 11, 1, TILEMAP2, 3, TILESET2, M.FMT_P8)
                         + M.blend(M.MODE_ALPHA, 16)
                         + M.blit(60, 100, 2, SPRITE, M.FMT_ARGB1555)
                         + M.blend(M.MODE_OPAQUE)
                         + M.blit(200, 100, 2, SPRITE, M.FMT_ARGB1555)),
        "tile": M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8),
        "blit": M.blit(100, 100, 2, SPRITE, M.FMT_ARGB1555),
        # Same 64x64 sprite drawn every line, in each format, to price the
        # fetch cost per drawn pixel cleanly.
        "big_argb": M.blit(0, 0, 3, SPRITE, M.FMT_ARGB1555),
        "big_p4":   M.blit(0, 0, 3, SPRITE4, M.FMT_P4),
        "demolean": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                     + [(M.OP_BLITLIST << 28) | (6 << 20) | (sprites >> 2)]),
        # demofix: everything the demo draws, but with the redundant FILL gone
        # and the ABLIT bracketed by a tight CLIP. An affine op takes its span
        # from clip_start..clip_end, so CLIP is already the mechanism for
        # bounding one -- the demo simply never used it.
        "demofix": (M.tile(0, 0, 1, TILEMAP, 3, TILESET, M.FMT_P8)
                    + M.clip(160, 260)
                    + M.ablit(190, 30, 2, SPRITE, M.FMT_ARGB1555,
                              a=(310, 179, -179, 310), b=(-932, 500))
                    + M.clip(0, M.INTERNAL_W - 1)
                    + [(M.OP_BLITLIST << 28) | (6 << 20) | (sprites >> 2)]),
    }[kind]
    prog = PROG
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + body + M.sync() + M.loop_to(PROG),
               mem, PROG)

    async def bring_up(dut):
        await apb_write(dut, R_PC, prog)
        await apb_write(dut, R_CTRL, 0x1)

    return mem, list(ppu.pram), None, bring_up


@cocotb.test()
async def probe(dut):
    scene = os.environ.get("PPU_SCENE", "fb")
    if scene in ("fill", "tile", "blit", "demolean", "demofix",
                 "parallax", "parallax_spr", "sprites32", "sprites32_bg", "sprites64", "big_argb", "big_p4",
                 "sprites64_bg", "sprites128_bg"):
        mem, pram, _model_frame, bring_up = micro_scene(scene)
    else:
        mem, pram, _model_frame, bring_up = build_scene()

    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(mem_server(dut, mem))
    cocotb.start_soon(psram_burst_server(dut, mem))
    dut.rst_n.value = 0
    for sig in ("psel", "penable", "pwrite", "paddr", "pwdata", "mem_hreq"):
        getattr(dut, sig).value = 0
    idle_burst_port(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    await clear_scanbufs(dut)
    await load_pram(dut, pram)
    await bring_up(dut)

    # Let it settle past the undefined first frame before measuring.
    await ClockCycles(dut.clk, H_TOTAL * 8)

    states = collections.Counter()
    op_clocks = collections.Counter()
    op_pixels = collections.Counter()
    clocks = stall = ack = under = pixels = mem_reqs = 0
    line_clocks = []
    line_work = []
    since_line = since_work = 0
    rendered = 0

    while rendered < LINES:
        await RisingEdge(dut.clk)
        clocks += 1
        since_line += 1
        st = int(dut.u_cmd.state.value)
        states[st] += 1
        # Attribute every non-idle clock, and every pixel actually written, to
        # the opcode in flight. This is what says where a scene's time goes.
        if st != 0:
            op_clocks[int(dut.u_cmd.opcode.value)] += 1
        if int(dut.u_cmd.px_valid.value):
            pixels += 1
            op_pixels[int(dut.u_cmd.opcode.value)] += 1
        # Memory requests actually put on the bus, against fetches delivered.
        # A miss holds fetch_req high until its ack, so without the
        # !grant_fetch term in ppu_top the same address is requested twice and
        # this ratio sits near 2.0 -- bandwidth stolen from the framebuffer
        # burst master, and the stale reply is what made a pipelined fetch
        # loop return the previous pixel's texel. Nothing asserted on it
        # before; BUS_STAT reported the doubled count and no test read it.
        if int(dut.mem_req.value):
            mem_reqs += 1
        req = int(dut.u_cmd_fetch_req.value) if hasattr(dut, "u_cmd_fetch_req") \
            else int(dut.f_req.value)
        a = int(dut.f_ack.value)
        if req and not a:
            stall += 1
        if a:
            ack += 1
        if int(dut.underrun.value):
            under += 1
        if st != 0:
            since_work += 1
        if int(dut.line_done.value):
            rendered += 1
            line_clocks.append(since_line)
            line_work.append(since_work)
            since_line = since_work = 0

    budget = H_TOTAL * 2      # core clocks per INTERNAL line (both axes doubled)
    mean = sum(line_clocks) / len(line_clocks)
    log = dut._log

    log.info("=" * 68)
    log.info(f"scene={os.environ.get('PPU_SCENE', 'fb')}  rendered {rendered} lines "
             f"in {clocks} core clocks")
    log.info(f"clocks per rendered line: mean {mean:.0f}  min {min(line_clocks)}  "
             f"max {max(line_clocks)}")
    log.info(f"budget per internal line: {budget}  ->  {mean / budget:.2f}x budget "
             f"({budget / mean:.1%} of required line rate)")
    log.info(f"underrun asserted on {under}/{clocks} clocks ({under / clocks:.1%})")
    log.info("-" * 68)
    log.info(f"fetch: {ack} ack cycles, {stall} stall cycles "
             f"({stall / clocks:.1%} of all clocks stalled on memory)")
    log.info(f"       {ack / len(line_clocks):.0f} fetches per rendered line")
    log.info(f"       {mem_reqs} memory requests for {ack} fetch acks "
             f"({mem_reqs / max(ack, 1):.2f} bus requests per fetch)")
    log.info("-" * 68)
    log.info("command-processor state histogram (share of all clocks):")
    for st, n in states.most_common():
        log.info(f"    {STATE_NAMES[st]:<6} {n:8}  {n / clocks:6.1%}")
    log.info("-" * 68)
    OPS = {0: "SYNC", 1: "CLIP", 2: "FILL", 3: "BLEND", 4: "BLIT", 5: "TILE",
           6: "ABLIT", 7: "ATILE", 8: "PALW", 9: "BLITLIST", 14: "PUSH",
           15: "POPJ"}
    n = len(line_clocks)
    log.info(f"per-opcode cost ({pixels / n:.0f} pixels written per line):")
    log.info(f"    {'opcode':<9} {'clocks/line':>11} {'px/line':>8} {'clocks/px':>10}")
    for op, c in op_clocks.most_common():
        px = op_pixels.get(op, 0)
        cpp = f"{c / px:.2f}" if px else "-"
        log.info(f"    {OPS.get(op, hex(op)):<9} {c / n:11.0f} {px / n:8.0f} {cpp:>10}")
    log.info("=" * 68)

    lw = sorted(line_work)
    over = [w for w in line_work if w > budget]
    log.info("-" * 68)
    log.info(f"per-line work clocks over {len(line_work)} lines: "
             f"min {lw[0]}  median {lw[len(lw)//2]}  max {lw[-1]}")
    log.info(f"lines exceeding the {budget}-clock budget: {len(over)}/{len(line_work)} "
             f"({len(over)/len(line_work):.0%})   worst {lw[-1]/budget:.2f}x")
    log.info("=" * 68)

    # Gate. Nothing else in the suite checks sustained line rate: ppu_tb.py
    # compares line CONTENT after giving the renderer as long as it needs, and
    # ppu_render_png.py reports its frame difference without asserting. That is
    # how a tiled background that could not be drawn in real time passed every
    # test. Every scene here must keep up, `demo` included -- it was rebuilt to
    # fit the hardware, and the gate is what stops it drifting back out. The
    # test is the WORST line over the run, not the mean: a 25-line sample of an
    # earlier demo happened to contain no sprites and read as 0.99x of budget
    # while 74% of its real frame was over.
    idle = states[0]
    work = (clocks - idle) / len(line_clocks)
    # Gated scenes are the ones that MUST sustain the line rate. sprites64*,
    # sprites128_bg, demolean and demofix are diagnostics that exceed it on
    # purpose -- a gate that is expected to fail teaches people to ignore it.
    if os.environ.get("PPU_SCENE", "fb") in (
            "fb", "fill", "blit", "tile", "demo", "parallax", "parallax_spr",
            "sprites32", "sprites32_bg"):
        assert under == 0, (
            f"underrun asserted on {under} clocks -- the renderer missed the "
            f"line rate for a scene that must sustain it")
        assert lw[-1] <= budget, (
            f"worst line needs {lw[-1]} work clocks, over the {budget}-clock "
            f"budget ({lw[-1] / budget:.2f}x); {len(over)} of {len(line_work)} lines over")
        assert mem_reqs <= ack * 1.05 + 32, (
            f"{mem_reqs} bus requests for only {ack} fetch acks "
            f"({mem_reqs / max(ack, 1):.2f}x) -- the fetch path is re-requesting "
            f"addresses it has already asked for")
        log.info(f"GATE PASS: {work:.0f} work clocks/line within {budget} "
                 f"({work / budget:.2f}x), no underrun, "
                 f"{mem_reqs / max(ack, 1):.2f} bus requests per fetch")


def main():
    d = Path(__file__).resolve().parents[1]
    src = [d / "rtl" / f for f in (
        "ppu_blend.v", "ppu_timing.v", "ppu_cache.v", "ppu_unpack.v",
        "ppu_cmd.v", "ppu_scanbuf.v", "ppu_fbscan.v", "ppu_display.v",
        "ppu_csr.v", "ppu_top.v")] + [d / "tb" / "sram_behavioural.v"]
    r = get_runner("icarus")
    r.build(verilog_sources=src, hdl_toplevel="ppu_top", includes=[d / "rtl"],
            build_args=["-g2005"], always=True, build_dir="sim_build_probe")
    r.test(hdl_toplevel="ppu_top", test_module="ppu_throughput_probe",
           build_dir="sim_build_probe")


if __name__ == "__main__":
    main()
