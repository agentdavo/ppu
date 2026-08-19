# SPDX-License-Identifier: Apache-2.0
"""
Render a frame out of the RTL and save it as a PNG -- and the model's frame, and
the difference between them.

    python3 ip/ppu/tb/ppu_render_png.py            # framebuffer scene (fast)
    PPU_SCENE=demo python3 ip/ppu/tb/ppu_render_png.py
    PPU_FULL=1 PPU_SCENE=demo python3 ip/ppu/tb/ppu_render_png.py

Pixels are taken off `vid_r/g/b` through `DE`, exactly as an external encoder
sees them -- nothing reaches into the scanbufs. What lands in `reports/` is
therefore a picture of what the chip would actually put on a monitor, not a
picture of what the model thinks it should.

Three files per run, in ip/ppu/reports/:

    <scene>_rtl.png     what left the pins
    <scene>_model.png   what ip/ppu/model/ppu_model.py says should have
    <scene>_diff.png    magenta where they disagree, dimmed where they agree

WHY THE DIFF IMAGE IS THE POINT
-------------------------------
The cocotb benches compare a handful of lines and stop at the first mismatch,
which tells you THAT something is wrong and little else. A diff image shows the
shape of the disagreement -- a shifted column, a dropped sprite, one bad tile --
which is usually enough to name the bug without opening a waveform.

COST
----
A frame is 420 000 core cycles and Icarus manages ~85 000 ns of simulated time
per wall-clock second, so any capture costs ~200 s of simulation whatever it
samples. Sampling therefore uses the cheapest scheme that still reads real
pixels: one sample per INTERNAL pixel (every second display pixel, every second
display line), then expanded back to 640x480 on the way out, since the hardware
doubles both axes anyway. PPU_FULL=1 samples every displayed pixel instead --
4x the Python work, and the only way to see a doubling fault in the image.
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
from aps12808 import idle_burst_port, psram_burst_server  # noqa: E402
from ppu_tb import (R_CTRL, R_FB_BASE, R_FB_CTL, R_FB_SIZE, R_FB_STRIDE,  # noqa: E402
                    R_PC, apb_write, clear_scanbufs, load_pram, mem_server)

CLK_NS = 40
H_ACTIVE, H_TOTAL = 640, 800
V_ACTIVE, V_TOTAL = 480, 525
FB_BASE, FB_STRIDE = 0x10000, M.INTERNAL_W * 2

SCENE = os.environ.get("PPU_SCENE", "fb")
FULL = os.environ.get("PPU_FULL", "") not in ("", "0")
OUTDIR = Path(__file__).resolve().parents[1] / "reports"


# ---------------------------------------------------------------------------
# Scenes
# ---------------------------------------------------------------------------

def fb_test_image():
    """A framebuffer image chosen to make errors visible rather than pretty:
    colour bars for channel order, ramps for bit weighting, a 1-pixel
    checkerboard for doubling and phase, and a circle for geometry."""
    rows = []
    for y in range(M.INTERNAL_H):
        row = []
        for x in range(M.INTERNAL_W):
            band = y * 6 // M.INTERNAL_H
            if band == 0:                                   # colour bars
                c = [(31, 31, 31), (31, 31, 0), (0, 31, 31), (0, 31, 0),
                     (31, 0, 31), (31, 0, 0), (0, 0, 31), (0, 0, 0)][x * 8 // M.INTERNAL_W]
            elif band == 1:                                 # red/green/blue ramps
                v = x * 32 // M.INTERNAL_W
                c = (v, 0, 0) if x < M.INTERNAL_W // 3 else \
                    (0, v, 0) if x < 2 * M.INTERNAL_W // 3 else (0, 0, v)
            elif band == 2:                                 # grey ramp
                v = x * 32 // M.INTERNAL_W
                c = (v, v, v)
            elif band == 3:                                 # 1px checkerboard
                v = 31 if (x ^ y) & 1 else 0
                c = (v, v, v)
            elif band == 4:                                 # circle + crosshair
                cx, cy = M.INTERNAL_W // 2, 4 * M.INTERNAL_H // 6 + M.INTERNAL_H // 12
                d = (x - cx) ** 2 + (y - cy) ** 2
                on = d < 26 ** 2 and d > 20 ** 2
                c = (31, 31, 0) if on else (0, 8, 0) if (x == cx or y == cy) else (2, 2, 6)
            else:                                           # per-line gradient
                c = ((x + y) & 0x1F, (y * 3) & 0x1F, (x >> 2) & 0x1F)
            row.append(M.pack1555(1, *c))
        rows.append(row)
    return rows


def build_scene():
    """-> (mem, pram, model_frame, bring_up coroutine factory)."""
    mem = M.Memory()
    ppu = M.PPU(mem)

    if SCENE == "fb":
        rows = fb_test_image()
        for y, row in enumerate(rows):
            M.fb_write_line(mem, y, row, FB_BASE, FB_STRIDE)
        model = [M.fb_line(mem, y, FB_BASE, FB_STRIDE) for y in range(M.INTERNAL_H)]

        async def bring_up(dut):
            await apb_write(dut, R_FB_BASE, FB_BASE)
            await apb_write(dut, R_FB_STRIDE, FB_STRIDE)
            await apb_write(dut, R_FB_SIZE, M.INTERNAL_W | (M.INTERNAL_H << 16))
            await apb_write(dut, R_FB_CTL, 0x1)
            await apb_write(dut, R_CTRL, 0x1)
        return mem, list(ppu.pram), model, bring_up

    if SCENE == "demo":
        prog = M.demo_scene(mem, ppu)
        model = ppu.render_frame(prog)

        async def bring_up(dut):
            await apb_write(dut, R_PC, prog)
            await apb_write(dut, R_CTRL, 0x1)
        return mem, list(ppu.pram), model, bring_up

    raise SystemExit(f"unknown PPU_SCENE={SCENE!r}; use 'fb' or 'demo'")


# ---------------------------------------------------------------------------

def expand(v):
    """5 bits -> 8 by replication, as the digital path does."""
    return (v << 3) | (v >> 2)


async def capture(dut):
    """One frame off the pins, as rows of (r,g,b) 5-bit tuples."""
    step = 1 if FULL else 2
    width = H_ACTIVE // step
    lines = V_ACTIVE // step

    # Skip the first frame: `frame_restart` is what gives either engine its line
    # of lead, so frame 0 after enable is undefined by design.
    await FallingEdge(dut.vsync)
    while int(dut.u_timing.v_count.value) != 0:
        await RisingEdge(dut.clk)

    rows = []
    for _ in range(lines):
        while int(dut.de.value) == 0:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
        row = []
        for _ in range(width):
            row.append((int(dut.vid_r.value), int(dut.vid_g.value), int(dut.vid_b.value)))
            await ClockCycles(dut.clk, step)
            await Timer(1, unit="ps")
        rows.append(row)
        # Jump the blanking, and the skipped display line when subsampling. One
        # ClockCycles instead of ~1000 single-cycle awaits; the counters are
        # free-running so the arithmetic is exact.
        await ClockCycles(dut.clk, (H_TOTAL - H_ACTIVE) + (step - 1) * H_TOTAL - 4)
    return rows


def to_rows8(pix, step):
    """(r,g,b) 5-bit rows -> 8-bit RGB byte rows at full display resolution."""
    out = []
    for row in pix:
        line = bytearray()
        for (r, g, b) in row:
            line += bytes((expand(r), expand(g), expand(b))) * step
        for _ in range(step):
            out.append(line)
    return out


@cocotb.test()
async def render(dut):
    mem, pram, model_frame, bring_up = build_scene()

    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(mem_server(dut, mem))          # render path / keyhole
    cocotb.start_soon(psram_burst_server(dut, mem))  # framebuffer burst port
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
    await RisingEdge(dut.clk)

    pix = await capture(dut)
    step = 1 if FULL else 2

    OUTDIR.mkdir(exist_ok=True)
    stem = f"{SCENE}{'_full' if FULL else ''}"

    M.write_png(str(OUTDIR / f"{stem}_rtl.png"), to_rows8(pix, step))
    M.write_png(str(OUTDIR / f"{stem}_model.png"), M.frame_to_rgb8(model_frame))

    # Diff at the sampled resolution, against the model's internal frame.
    bad = 0
    diff = []
    for y, row in enumerate(pix):
        out = []
        for x, got in enumerate(row):
            c = model_frame[y * step // 2][x * step // 2]
            want = ((c >> 10) & 0x1F, (c >> 5) & 0x1F, c & 0x1F)
            if got != want:
                bad += 1
                out.append((31, 0, 31))                    # magenta
            else:
                out.append(tuple(v // 4 for v in got))     # dimmed
        diff.append(out)
    M.write_png(str(OUTDIR / f"{stem}_diff.png"), to_rows8(diff, step))

    total = len(pix) * len(pix[0])
    dut._log.info(f"{stem}: {len(pix[0])}x{len(pix)} sampled, "
                  f"{bad}/{total} pixels differ from the model ({bad/total:.2%})")
    dut._log.info(f"wrote {stem}_rtl.png, {stem}_model.png, {stem}_diff.png "
                  f"to ip/ppu/reports/")


def main():
    d = Path(__file__).resolve().parents[1]
    src = [d / "rtl" / f for f in (
        "ppu_blend.v", "ppu_timing.v", "ppu_cache.v", "ppu_unpack.v",
        "ppu_cmd.v", "ppu_scanbuf.v", "ppu_fbscan.v", "ppu_display.v",
        "ppu_csr.v", "ppu_top.v")] + [d / "tb" / "sram_behavioural.v"]
    r = get_runner("icarus")
    r.build(verilog_sources=src, hdl_toplevel="ppu_top", includes=[d / "rtl"],
            build_args=["-g2005"], always=True)
    r.test(hdl_toplevel="ppu_top", test_module="ppu_render_png")


if __name__ == "__main__":
    main()
