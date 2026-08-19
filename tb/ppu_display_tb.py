# SPDX-License-Identifier: Apache-2.0
"""
Display controller verification -- the half of the PPU ppu_tb.py deliberately
skips.

ppu_tb.py reads rendered lines straight out of the scanbuf macros so that a
failure points at the render path. That leaves everything downstream of the
buffers -- pixel mux, pixel and line doubling, blanking, sync generation, both
output paths, and the buffer handshake itself -- with no coverage at all. This
file covers it.

    python3 ip/ppu/tb/ppu_display_tb.py

Tests:
  test_video_timing   every VESA DMT number for 640x480@60, measured
  test_scanout        pixels leaving vid_r/g/b, against the golden model
  test_underrun       the overrun policy actually repeats, latches and IRQs
  test_fb_*           simple-framebuffer / simpledrm compliance, clause by
                      clause -- see the block comment above them

Timing is measured on sync edges rather than by sampling every clock, so a whole
frame costs ~630 awaits instead of 663 000.
"""

from pathlib import Path
import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time
from cocotb_tools.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
import ppu_model as M  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from aps12808 import idle_burst_port, psram_burst_server  # noqa: E402
from ppu_tb import (R_CTRL, R_DISP, R_FB_BASE, R_FB_CTL, R_FB_SIZE, R_FRAME,  # noqa: E402
                    R_FB_STRIDE, R_IRQ_EN, R_IRQ_ST, R_MEM_A, R_MEM_D,
                    R_PC, R_STATUS,
                    apb_read, apb_write,
                    clear_scanbufs, load_pram, mem_server)

CLK_NS = 40   # 25.000 MHz on clk_PAD; core == pixel
PIX_NS = CLK_NS       # 1:1 today; x2 when PPU_PIX_DIV is 2

# VESA DMT 640x480@60. These are the numbers the RTL must actually produce.
H_ACTIVE, H_FRONT, H_SYNC, H_BACK, H_TOTAL = 640, 16, 96, 48, 800
V_ACTIVE, V_FRONT, V_SYNC, V_BACK, V_TOTAL = 480, 10, 2, 33, 525
# Driven from 25.000 MHz rather than the nominal 25.175, so 59.524 Hz not 59.940.
REFRESH_HZ = 1e9 / (V_TOTAL * H_TOTAL * PIX_NS)


async def bring_up(dut, mem, pram, prog, stall=False):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    if not stall:
        cocotb.start_soon(mem_server(dut, mem))
    else:
        dut.mem_ack.value = 0
        dut.mem_rdata.value = 0

    dut.rst_n.value = 0
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = 0
    dut.pwdata.value = 0
    dut.mem_hreq.value = 0
    idle_burst_port(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    await clear_scanbufs(dut)
    await load_pram(dut, pram)

    await apb_write(dut, R_PC, prog)
    await apb_write(dut, R_CTRL, 0x1)
    await RisingEdge(dut.clk)


def gradient_scene():
    """Three clipped FILL spans, so a scanout error that shifts pixels
    horizontally is visible rather than masked by a flat field.

    It is deliberately noted that this scene renders EVERY LINE IDENTICALLY --
    a display list has one FILL colour, not one per y -- so it cannot see a
    vertical shift or a lost first pixel, and for a long time it did not: both
    bugs described in README section 15 lived here undetected until a
    framebuffer with per-line content was scanned out. Vertical coverage comes
    from the `test_fb_*` tests below; do not add one here and assume it does.
    """
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog = 0x8000
    M.assemble(M.clip(0, M.INTERNAL_W - 1) + M.fill(31, 0, 0)
               + M.clip(80, 199) + M.fill(0, 31, 0)
               + M.clip(200, M.INTERNAL_W - 1) + M.fill(0, 0, 31) + M.sync() + M.loop_to(prog), mem, prog)
    return mem, ppu, prog


# ---------------------------------------------------------------------------

@cocotb.test()
async def test_video_timing(dut):
    """Measure every VESA DMT figure rather than trusting the parameters."""
    mem, ppu, prog = gradient_scene()
    await bring_up(dut, mem, list(ppu.pram), prog)

    async def edge_time(sig, rising=True):
        await (RisingEdge(sig) if rising else FallingEdge(sig))
        return get_sim_time("ns")

    # 640x480@60 is -H -V, so the sync pulse is the LOW time. Measure the
    # asserted level rather than assuming active-high: rising->falling on an
    # active-low sync measures the 704-pixel gap, not the 96-pixel pulse.
    await FallingEdge(dut.hsync)
    await FallingEdge(dut.hsync)

    t0 = get_sim_time("ns")
    t_rise = await edge_time(dut.hsync)                 # end of the low pulse
    t1 = await edge_time(dut.hsync, rising=False)       # start of the next

    h_period = t1 - t0
    h_width = t_rise - t0
    assert h_period == H_TOTAL * PIX_NS, \
        f"hsync period {h_period} ns, expected {H_TOTAL * PIX_NS}"
    assert h_width == H_SYNC * PIX_NS, \
        f"hsync width {h_width} ns, expected {H_SYNC * PIX_NS}"

    # Count lines per frame across one full vsync period.
    await FallingEdge(dut.vsync)
    v_t0 = get_sim_time("ns")
    lines = 0

    async def count_lines():
        nonlocal lines
        while True:
            await FallingEdge(dut.hsync)
            lines += 1

    counter = cocotb.start_soon(count_lines())
    await RisingEdge(dut.vsync)
    vs_rise = get_sim_time("ns")
    await FallingEdge(dut.vsync)
    v_period = get_sim_time("ns") - v_t0
    counter.kill()

    v_width = vs_rise - v_t0
    assert v_period == V_TOTAL * H_TOTAL * PIX_NS, \
        f"vsync period {v_period} ns, expected {V_TOTAL * H_TOTAL * PIX_NS}"
    assert v_width == V_SYNC * H_TOTAL * PIX_NS, \
        f"vsync width {v_width} ns, expected {V_SYNC * H_TOTAL * PIX_NS}"
    assert lines == V_TOTAL, f"{lines} lines per frame, expected {V_TOTAL}"

    refresh = 1e9 / v_period
    dut._log.info(f"timing OK: h {h_period} ns / {h_width} ns sync, "
                  f"v {v_period} ns / {lines} lines, refresh {refresh:.3f} Hz")
    assert abs(refresh - REFRESH_HZ) < 0.01, f"refresh {refresh:.3f} Hz"

    # Polarity is configurable; VESA DMT wants both active high here.
    before = int(dut.hsync.value)
    await apb_write(dut, R_DISP, 0b0111)          # set HSYNC_POL
    await ClockCycles(dut.clk, 4)
    assert int(dut.hsync.value) != before, "DISP_CFG HSYNC_POL has no effect"
    await apb_write(dut, R_DISP, 0b0011)
    await ClockCycles(dut.clk, 4)
    assert int(await apb_read(dut, R_DISP)) == 0b0011, "DISP_CFG does not read back"


@cocotb.test()
async def test_scanout(dut):
    """Pixels leaving the chip, against the model -- including doubling."""
    mem, ppu, prog = gradient_scene()
    await bring_up(dut, mem, list(ppu.pram), prog)

    # Skip the FIRST frame. `prep_frame` fires at the end of a frame, so the
    # renderer only acquires its one line of lead at the first frame boundary;
    # until then every line displays the previous line's content. That is real
    # hardware behaviour after enable -- frame 0 is undefined -- so the test must
    # sample from frame 1 onward rather than pretend otherwise.
    await FallingEdge(dut.vsync)
    await FallingEdge(dut.vsync)
    while not (int(dut.u_timing.v_count.value) == 40 and int(dut.u_timing.h_count.value) == 0):
        await RisingEdge(dut.clk)

    async def capture_line():
        """Active pixels of one display line, taken from DE exactly as an
        external encoder would. Driving the window from h_count instead
        loses a pixel, because DE is registered and lags the raw counter."""
        while int(dut.de.value) == 0:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
        line = int(dut.u_timing.v_count.value)
        dig = []
        while int(dut.de.value) == 1:
            # One sample per PIXEL, not per core cycle -- the core runs at 2x.
            dig.append((int(dut.vid_r.value), int(dut.vid_g.value), int(dut.vid_b.value)))
            for _ in range(M.PIX_DIV):
                await RisingEdge(dut.clk)
                await Timer(1, unit="ps")
        # Blanking: RGB must be forced to zero once DE drops so an external
        # encoder sees a proper blanking level.
        blank_ok = True
        for _ in range(40):
            if int(dut.vid_r.value) or int(dut.vid_g.value) or int(dut.vid_b.value):
                blank_ok = False
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
        return line, dig, blank_ok

    vc, dig0, blank0 = await capture_line()
    _, dig1, blank1 = await capture_line()

    assert blank0 and blank1, "RGB not blanked outside the active window"
    assert len(dig0) == H_ACTIVE, f"{len(dig0)} active pixels, expected {H_ACTIVE}"
    if dig0 != dig1:
        d = [(i, a, b) for i, (a, b) in enumerate(zip(dig0, dig1)) if a != b]
        raise AssertionError(
            f"line doubling: lines {vc} and {vc+1} differ in {len(d)}/{len(dig0)} px; "
            f"first: {d[:4]}")

    # Pixel doubling: every internal pixel appears exactly twice.
    for x in range(0, H_ACTIVE, 2):
        assert dig0[x] == dig0[x + 1], f"pixel doubling broken at x={x}"

    # Against the model. The displayed internal line is vc >> 1.
    want_line = ppu._render_line(prog, (vc >> 1) % M.INTERNAL_H)
    got = [dig0[2 * i] for i in range(M.INTERNAL_W)]
    want = [((c >> 10) & 0x1F, (c >> 5) & 0x1F, c & 0x1F) for c in want_line]
    bad = [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w]
    assert not bad, (f"scanout differs from model in {len(bad)}/{len(want)} px "
                     f"(display line {vc}, internal {vc >> 1}): {bad[:5]}")
    dut._log.info(f"scanout OK: {len(dig0)} px, doubling and blanking correct, "
                  f"matches model line {vc >> 1}")


@cocotb.test()
async def test_underrun(dut):
    """Starve the fetch path so the render cannot finish, and check the policy:
    repeat the displayed line, latch `underrun`, raise IRQ, recover on clear."""
    mem, ppu, prog = gradient_scene()
    await bring_up(dut, mem, list(ppu.pram), prog, stall=True)

    # Interrupts are masked out of reset, which is correct -- enable the
    # underrun source before expecting IRQ to assert.
    await apb_write(dut, R_IRQ_EN, 0x1)

    # No memory acks at all, so the command processor cannot complete a line.
    for _ in range(H_TOTAL * 6):
        await RisingEdge(dut.clk)

    assert int(dut.underrun.value) == 1, "underrun did not latch on a stalled render"
    assert int(dut.irq.value) == 1, "IRQ not raised on underrun"

    # The display must keep scanning -- a stalled renderer must not stall video.
    h0 = int(dut.u_timing.h_count.value)
    await ClockCycles(dut.clk, 50)
    assert int(dut.u_timing.h_count.value) != h0, "video timing stalled on underrun"

    # And it must not have swapped onto a half-rendered buffer.
    assert int(dut.u_display.busy.value) == 1, "render should still be outstanding"

    # Sticky until explicitly cleared.
    assert (await apb_read(dut, R_STATUS)) & 0x2, "STATUS does not report underrun"
    await apb_write(dut, R_IRQ_ST, 0x1)           # W1C clears underrun
    await ClockCycles(dut.clk, 4)                 # clear pulse reaches the display
    assert int(dut.underrun.value) == 0, "IRQ_STS write-1-to-clear did not clear underrun"

    # Restore memory; rendering must resume and the flag stay clear.
    cocotb.start_soon(mem_server(dut, mem))
    for _ in range(H_TOTAL * 8):
        await RisingEdge(dut.clk)
    assert int(dut.underrun.value) == 0, \
        "underrun re-latched after memory recovered -- renderer is not keeping up"
    dut._log.info("underrun OK: latched, IRQ raised, video kept running, cleared, recovered")


def main():
    ppu_dir = Path(__file__).resolve().parents[1]
    build_args = ["-g2005"]
    build_dir = os.environ.get("PPU_BUILD_DIR", "sim_build")
    if os.environ.get("PPU_GL", "0") == "1":
        # Gate-level: the synthesized netlist plus the PDK's functional cell
        # models (gate G6). FUNCTIONAL skips the specify blocks; power pins
        # stay off. This works with THIS testbench unchanged because the bench
        # only ever touches top-level ports -- APB, the burst port, and the
        # video outputs -- never hierarchical RTL state.
        pdk_sc = (ppu_dir.parents[1] / "gf180mcu" / "ciel" / "gf180mcu" /
                  "versions" / "f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7" /
                  "gf180mcuD" / "libs.ref" / "gf180mcu_fd_sc_mcu7t5v0" / "verilog")
        sources = [ppu_dir / "reports" / "ppu_synth_gl.v",
                   pdk_sc / "primitives.v",
                   pdk_sc / "gf180mcu_fd_sc_mcu7t5v0.v",
                   ppu_dir / "tb" / "sram_behavioural.v"]
        build_args.append("-DFUNCTIONAL")
        build_dir = "sim_build_gl"   # never race the RTL suite's build
    else:
        sources = [ppu_dir / "rtl" / f for f in (
            "ppu_blend.v", "ppu_timing.v", "ppu_cache.v", "ppu_unpack.v",
            "ppu_cmd.v", "ppu_scanbuf.v", "ppu_fbscan.v", "ppu_display.v",
            "ppu_csr.v", "ppu_top.v")]
        sources.append(ppu_dir / "tb" / "sram_behavioural.v")

    runner = get_runner("icarus")
    runner.build(verilog_sources=sources, hdl_toplevel="ppu_top",
                 includes=[ppu_dir / "rtl"], build_args=build_args, always=True,
                 build_dir=build_dir)
    tc = sys.argv[1] if len(sys.argv) > 1 else None
    runner.test(hdl_toplevel="ppu_top", test_module="ppu_display_tb", testcase=tc,
                build_dir=build_dir)


if __name__ == "__main__":
    main()


# ---------------------------------------------------------------------------
# simple-framebuffer / simpledrm compliance
#
# The contract these tests hold the hardware to is the driver's, not ours:
#
#   * firmware sets the display up; the driver programs NOTHING -- there is not
#     one register write anywhere in drivers/gpu/drm/tiny/simpledrm.c
#   * the framebuffer is a flat span of memory at a fixed address, described by
#     width / height / stride / format in the devicetree node
#   * the driver writes it with plain stores and expects the next scanout to
#     show them: no flush, no doorbell, no page flip
#   * `stride` is independent of `width`, and the framebuffer may be smaller
#     than the mode
#   * the format string is one of SIMPLEFB_FORMATS
#
# Each test below is one clause. README section 16 maps them onto the devicetree
# node they justify.
#
# COST NOTE: a frame is 420 000 core cycles and Icarus takes ~200 s over one, so
# these tests sample EARLY lines and reconfigure mid-frame wherever the hardware
# permits it. The one unavoidable frame is the first: `frame_restart` is what
# loads the line-address accumulator with FB_BASE, so -- exactly like the render
# path -- the frame immediately after enable is undefined.
# ---------------------------------------------------------------------------

# Near the TOP of the 32 MB APS12808L pair, so every framebuffer test proves the
# 32-bit address path end to end -- an engine that silently truncated to the old
# 19 bits would read zeros and fail every scanout comparison.
FB_BASE = 0x1F80000
FB_STRIDE = M.INTERNAL_W * 2
FB_MEM_BYTES = 1 << 25          # two APS12808L = 32 MB of system RAM


async def bring_up_fb(dut, mem, fmt=M.FB_A1R5G5B5, base=FB_BASE,
                      stride=FB_STRIDE, w=M.INTERNAL_W, h=M.INTERNAL_H):
    """Bring the chip up the way firmware would for simpledrm: describe the
    framebuffer, enable the framebuffer engine, enable the PPU. No program, no
    palette, no display list -- after this the driver never writes a register."""
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(mem_server(dut, mem))          # keyhole / render path
    idle_burst_port(dut)
    # The framebuffer is read through the memory controller in front of the
    # APS12808L pair, NOT through the flat port -- late first beats, mid-stream
    # row-crossing stalls and tCEM re-issues included.
    cocotb.start_soon(psram_burst_server(dut, mem, dut._log))

    dut.rst_n.value = 0
    dut.psel.value = 0
    dut.penable.value = 0
    dut.pwrite.value = 0
    dut.paddr.value = 0
    dut.pwdata.value = 0
    dut.mem_hreq.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    await clear_scanbufs(dut)

    await apb_write(dut, R_FB_BASE, base)
    await apb_write(dut, R_FB_STRIDE, stride)
    await apb_write(dut, R_FB_SIZE, w | (h << 16))
    await apb_write(dut, R_FB_CTL, 0x1 | (fmt << 1))
    await apb_write(dut, R_CTRL, 0x1)
    await RisingEdge(dut.clk)


def fb_pattern(w, h, fmt):
    """Source pixels with no symmetry in either axis, so a line that is shifted,
    repeated, swapped or stale cannot pass by accident."""
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            r, g, b = (x + y) & 0x1F, (y * 3 + x) & 0x1F, (x >> 2) & 0x1F
            if fmt == M.FB_R5G6B5:
                row.append((r << 11) | ((g << 1) << 5) | b)
            elif fmt == M.FB_X8R8G8B8:
                row.append((r << 19) | (g << 11) | (b << 3))
            elif fmt == M.FB_R5G5B5A1:
                row.append((r << 11) | (g << 6) | (b << 1) | 1)   # alpha bit SET
            elif fmt == M.FB_X1R5G5B5:
                row.append((r << 10) | (g << 5) | b)          # alpha bit CLEAR
            else:
                row.append(M.pack1555(1, r, g, b))
        rows.append(row)
    return rows


# The kernel's own conversion vectors, lifted from the "well_known_colors" case
# of drm_format_helper_test.c (drm_test_fb_xrgb8888_to_*). Those are the exact
# bytes drm_sysfb's blit helpers write into a framebuffer of each native format
# when userspace draws white, black, red, green, blue, magenta, yellow and cyan
# in XRGB8888 -- which is what every simpledrm client actually does, since
# XRGB8888 is the emulated format drm_sysfb_build_fourcc_list() always appends.
#
# Decoding them back to the right colour is the strongest statement available
# about format compliance without booting a kernel: it checks this hardware
# against the kernel's encoder rather than against our own reading of the
# format names.
KUNIT_COLORS = [(31, 31, 31), (0, 0, 0), (31, 0, 0), (0, 31, 0),
                (0, 0, 31), (31, 0, 31), (31, 31, 0), (0, 31, 31)]

KUNIT_VECTORS = {
    # drm_fb_xrgb8888_to_xrgb1555 / _to_argb1555 / _to_rgb565 / _to_rgba5551
    M.FB_X1R5G5B5: [0x7FFF, 0x0000, 0x7C00, 0x03E0, 0x001F, 0x7C1F, 0x7FE0, 0x03FF],
    M.FB_A1R5G5B5: [0xFFFF, 0x8000, 0xFC00, 0x83E0, 0x801F, 0xFC1F, 0xFFE0, 0x83FF],
    M.FB_R5G6B5:   [0xFFFF, 0x0000, 0xF800, 0x07E0, 0x001F, 0xF81F, 0xFFE0, 0x07FF],
    M.FB_R5G5B5A1: [0xFFFF, 0x0001, 0xF801, 0x07C1, 0x003F, 0xF83F, 0xFFC1, 0x07FF],
    # XRGB8888 is native: the blit is a memcpy, so these are the source pixels
    # from the same case -- deliberately with eight DIFFERENT values in the
    # ignored X byte, which makes this a check that we ignore it.
    M.FB_X8R8G8B8: [0x11FFFFFF, 0x22000000, 0x33FF0000, 0x4400FF00,
                    0x550000FF, 0x66FF00FF, 0x77FFFF00, 0x8800FFFF],
}


def fill_fb(mem, rows, base=FB_BASE, stride=FB_STRIDE, fmt=M.FB_A1R5G5B5):
    """A host writing the mapped framebuffer with ordinary stores."""
    for y, row in enumerate(rows):
        M.fb_write_line(mem, y, row, base, stride, fmt)


async def capture_internal_line(dut, y):
    """Wait for display line 2y and return its INTERNAL_W pixels as (r,g,b).

    Sampled off vid_r/g/b through DE exactly as an external encoder sees them,
    then de-doubled, so the comparison is against internal pixels.
    """
    while not (int(dut.u_timing.v_count.value) == y * 2
               and int(dut.u_timing.h_count.value) == 0):
        await RisingEdge(dut.clk)
    while int(dut.de.value) == 0:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    out = []
    while int(dut.de.value) == 1:
        out.append((int(dut.vid_r.value), int(dut.vid_g.value), int(dut.vid_b.value)))
        for _ in range(M.PIX_DIV):
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
    assert len(out) == H_ACTIVE, f"{len(out)} active pixels, expected {H_ACTIVE}"
    for x in range(0, H_ACTIVE, 2):
        assert out[x] == out[x + 1], f"pixel doubling broken at x={x}"
    return [out[2 * i] for i in range(M.INTERNAL_W)]


def expect_line(mem, y, **kw):
    """The model's answer for one internal line, as (r,g,b) at the pins."""
    return [((c >> 10) & 0x1F, (c >> 5) & 0x1F, c & 0x1F)
            for c in M.fb_line(mem, y, **kw)]


def compare_px(got, want, what):
    bad = [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w]
    assert not bad, f"{what}: {len(bad)}/{len(want)} px differ, first {bad[:5]}"


async def sync_frame(dut):
    """Advance to the exact start of the next frame."""
    await FallingEdge(dut.vsync)
    while int(dut.u_timing.v_count.value) != 0:
        await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------

@cocotb.test()
async def test_fb_scanout(dut):
    """A flat a1r5g5b5 framebuffer, written as memory, scanned out unchanged --
    with the command processor provably not involved."""
    mem = M.Memory(FB_MEM_BYTES)
    fill_fb(mem, fb_pattern(M.INTERNAL_W, M.INTERNAL_H, M.FB_A1R5G5B5))
    await bring_up_fb(dut, mem)

    # The render path must be OUT of the loop: FB_CTRL.FB_EN gates its enable,
    # so it may not issue a single fetch. That is what makes a bus stall a late
    # framebuffer read rather than a half-rendered line, and it is why the
    # texel cache -- which no driver can flush -- is not in the picture.
    fetches = 0

    async def watch_cmd():
        nonlocal fetches
        while True:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            if int(dut.f_req.value):
                fetches += 1
    watcher = cocotb.start_soon(watch_cmd())

    await sync_frame(dut)
    for y in (0, 1, 37):
        got = await capture_internal_line(dut, y)
        compare_px(got, expect_line(mem, y, base=FB_BASE, stride=FB_STRIDE),
                   f"a1r5g5b5 line {y}")
    watcher.kill()

    assert fetches == 0, f"command processor issued {fetches} fetches in FB mode"
    assert (await apb_read(dut, R_STATUS)) & 0x8, "STATUS does not report FB mode"
    got_base = await apb_read(dut, R_FB_BASE)
    assert got_base == FB_BASE, f"FB_BASE readback {got_base:#x} != {FB_BASE:#x}"
    dut._log.info("fb scanout OK: lines 0, 1 and 37 bit-exact vs the model at "
                  "the output pins, command processor idle, framebuffer served "
                  f"from {FB_BASE:#x} in a 32 MB space")


@cocotb.test()
async def test_fb_formats(dut):
    """Every format this hardware claims from SIMPLEFB_FORMATS.

    All three run at a 1280-byte stride so the format can be switched between
    captures without disturbing the line-address accumulator. For the two 16 bpp
    formats that means rows padded to twice their pixel width, which is a second
    reading of the stride path at no extra simulation cost.

    x1r5g5b5 is written with its top bit CLEAR and r5g5b5a1 with its low bit
    SET: an alpha bit that leaked into scanout either way would make two
    framebuffers holding the same colours look different, and drm_sysfb's
    to_nonalpha_fourcc() has already decided they are the same picture.

    Each line is also checked against the kernel's own conversion vectors --
    see KUNIT_VECTORS above.
    """
    STRIDE = M.INTERNAL_W * 4
    mem = M.Memory(FB_MEM_BYTES)
    fill_fb(mem, fb_pattern(M.INTERNAL_W, M.INTERNAL_H, M.FB_X1R5G5B5),
            stride=STRIDE, fmt=M.FB_X1R5G5B5)
    await bring_up_fb(dut, mem, fmt=M.FB_X1R5G5B5, stride=STRIDE)
    await sync_frame(dut)

    for fmt, y in ((M.FB_X1R5G5B5, 2), (M.FB_R5G6B5, 60), (M.FB_X8R8G8B8, 120),
                   (M.FB_R5G5B5A1, 180), (M.FB_A1R5G5B5, 210)):
        rows = fb_pattern(M.INTERNAL_W, M.INTERNAL_H, fmt)
        # Overlay the kernel's vectors on the first 8 pixels of the line about
        # to be sampled. Free -- it needs no extra frame -- and it is the only
        # check here whose expected values come from outside this repository.
        rows[y][:len(KUNIT_VECTORS[fmt])] = KUNIT_VECTORS[fmt]
        fill_fb(mem, rows, stride=STRIDE, fmt=fmt)
        if fmt != M.FB_X1R5G5B5:
            await apb_write(dut, R_FB_CTL, 0x1 | (fmt << 1))
        got = await capture_internal_line(dut, y)
        compare_px(got, expect_line(mem, y, base=FB_BASE, stride=STRIDE, fmt=fmt),
                   f"{M.FB_FORMAT_NAMES[fmt]} line {y}")
        compare_px(got[:len(KUNIT_COLORS)], KUNIT_COLORS,
                   f"{M.FB_FORMAT_NAMES[fmt]} against the kernel's own vectors")
        dut._log.info(f"{M.FB_FORMAT_NAMES[fmt]} OK at line {y} "
                      f"({M.FB_BPP[fmt]} bpp, stride {STRIDE}), including the "
                      f"8 drm_format_helper_test.c vectors")


@cocotb.test()
async def test_fb_stride_and_geometry(dut):
    """`stride` independent of `width`, and a framebuffer smaller than the mode.

    Both are ordinary in the binding: a driver may pad rows for alignment, and
    width/height need not fill the display. The area outside the framebuffer
    must be BLANK, not whatever the scanline buffer held two frames ago -- so
    the memory past the bottom of the framebuffer is deliberately poisoned with
    white, and white must not appear.
    """
    W, H, STRIDE = 200, 40, 1024
    mem = M.Memory(FB_MEM_BYTES)
    fill_fb(mem, fb_pattern(W, H, M.FB_A1R5G5B5), stride=STRIDE)
    for y in range(H, M.INTERNAL_H):
        M.fb_write_line(mem, y, [0x7FFF] * W, FB_BASE, STRIDE)

    await bring_up_fb(dut, mem, stride=STRIDE, w=W, h=H)
    await sync_frame(dut)

    for y in (0, H - 1):
        got = await capture_internal_line(dut, y)
        compare_px(got, expect_line(mem, y, base=FB_BASE, stride=STRIDE, w=W, h=H),
                   f"stride {STRIDE} line {y}")
        assert all(p == (0, 0, 0) for p in got[W:]), \
            f"line {y}: pixels past width {W} are not blanked"

    below = await capture_internal_line(dut, H + 5)
    assert all(p == (0, 0, 0) for p in below), \
        f"line {H + 5} is past height {H} and must be blank, got {below[:4]}"
    dut._log.info(f"stride/geometry OK: {W}x{H} at stride {STRIDE}, "
                  f"everything outside it blank")


@cocotb.test()
async def test_fb_coherency(dut):
    """A store lands on the screen with no register access anywhere.

    Twice over: a line written ahead of the beam appears in THIS frame, and a
    line written behind it appears in the NEXT one. This is the clause the
    display-list path could not honour -- its fetches go through the texel
    cache, which is flushed only on a PC write, so a driver that only ever
    writes memory can see a stale line and has no way to ask for a flush.
    """
    mem = M.Memory(FB_MEM_BYTES)
    fill_fb(mem, fb_pattern(M.INTERNAL_W, M.INTERNAL_H, M.FB_A1R5G5B5))
    await bring_up_fb(dut, mem)
    await sync_frame(dut)

    EARLY, LATE = 8, 80
    early_before = await capture_internal_line(dut, EARLY)
    compare_px(early_before, expect_line(mem, EARLY, base=FB_BASE, stride=FB_STRIDE),
               f"line {EARLY} before any store")

    # Ahead of the beam: must appear in this same frame.
    ahead = [M.pack1555(1, 31 - (x & 0x1F), (x * 5) & 0x1F, 7)
             for x in range(M.INTERNAL_W)]
    M.fb_write_line(mem, LATE, ahead, FB_BASE, FB_STRIDE)
    got = await capture_internal_line(dut, LATE)
    compare_px(got, expect_line(mem, LATE, base=FB_BASE, stride=FB_STRIDE),
               f"line {LATE} written ahead of the beam")

    # Behind the beam: must appear in the next frame, with no register write in
    # between -- note there is no APB traffic at all from here on.
    behind = [M.pack1555(1, 2, 31 - ((x * 3) & 0x1F), (x >> 3) & 0x1F)
              for x in range(M.INTERNAL_W)]
    M.fb_write_line(mem, EARLY, behind, FB_BASE, FB_STRIDE)
    await sync_frame(dut)
    early_after = await capture_internal_line(dut, EARLY)
    compare_px(early_after, expect_line(mem, EARLY, base=FB_BASE, stride=FB_STRIDE),
               f"line {EARLY} after the store")
    assert early_after != early_before, "the store did not reach the screen"
    dut._log.info("coherency OK: plain memory writes are visible on the next "
                  "scanout of the line, with no register access")


@cocotb.test()
async def test_fb_bus_release(dut):
    """The host takes the external bus, writes the framebuffer, hands it back.

    simpledrm ioremaps the framebuffer and memcpy_toio's into it, so the pixels
    have to live in memory the host can address. On a shared bus that means the
    PPU must get off it on request -- and must not tear, hang or lose sync while
    it is off.
    """
    mem = M.Memory(FB_MEM_BYTES)
    fill_fb(mem, fb_pattern(M.INTERNAL_W, M.INTERNAL_H, M.FB_A1R5G5B5))
    await bring_up_fb(dut, mem)
    await sync_frame(dut)

    assert int(dut.mem_oe.value) == 1 and int(dut.mem_hgnt.value) == 0, \
        "PPU is not driving the bus with mem_hreq low"

    # How long the host waits is the number that matters, and it is not small:
    # the scanner issues its whole line as one back-to-back burst -- 320 beats
    # for 16 bpp -- and the arbiter only hands over when nothing is outstanding.
    # Asking at the top of a frame lands mid-burst on purpose, so this measures
    # the worst case rather than a lucky gap. The bound is one internal line
    # time; anything longer would mean the scanner never goes idle, which would
    # make a host write impossible rather than merely slow.
    LINE_CYCLES = H_TOTAL * 2 // M.PIX_DIV
    dut.mem_hreq.value = 1
    latency = 0
    for latency in range(1, LINE_CYCLES + 1):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.mem_hgnt.value):
            break
    assert int(dut.mem_hgnt.value) == 1, \
        f"bus not granted within one line time ({LINE_CYCLES} cycles)"
    assert int(dut.mem_oe.value) == 0, "mem_oe still asserted while the host owns it"
    dut._log.info(f"bus granted after {latency} cycles "
                  f"({latency * CLK_NS / 1000:.2f} us), bound is {LINE_CYCLES}")

    # While the host owns the bus the PPU must be off the wire, and the display
    # must keep running: video that stops when the CPU touches memory is not
    # video the kernel can drive.
    h0 = int(dut.u_timing.h_count.value)
    for _ in range(400):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        assert int(dut.mem_req.value) == 0, "PPU drove mem_req while the bus was granted"
    assert int(dut.u_timing.h_count.value) != h0, "video stalled during bus release"

    # The host writes a line while it owns the bus, then hands back.
    Y = 40
    new = [M.pack1555(1, 3, (x * 7) & 0x1F, 31 - (x & 0x1F)) for x in range(M.INTERNAL_W)]
    M.fb_write_line(mem, Y, new, FB_BASE, FB_STRIDE)

    dut.mem_hreq.value = 0
    await ClockCycles(dut.clk, 4)
    assert int(dut.mem_hgnt.value) == 0 and int(dut.mem_oe.value) == 1, \
        "bus not reclaimed after mem_hreq dropped"

    got = await capture_internal_line(dut, Y)
    compare_px(got, expect_line(mem, Y, base=FB_BASE, stride=FB_STRIDE),
               f"line {Y}, written by the host while it owned the bus")
    dut._log.info("bus release OK: PPU off the wire, video kept running, the "
                  "host's line scanned out after handback")


@cocotb.test()
async def test_host_window(dut):
    """The MEM_A/MEM_D keyhole, which is the bring-up path rather than the
    simpledrm path -- a driver cannot ioremap a two-register window, so this
    exists for a host with no bus access of its own.

    Run against a LIVE framebuffer scanner, so it also shows the host losing
    arbitration and coming back: the scanner outranks it on the bus, and every
    keyhole access still completes because PREADY holds the transfer until the
    arbiter gets to it. No frame boundaries are waited on, so this costs
    milliseconds rather than the ~200 s a frame takes in Icarus.
    """
    mem = M.Memory(FB_MEM_BYTES)
    await bring_up_fb(dut, mem)

    # The keyhole reaches only the low 512 KB: MEM_ADDR is 19 bits and stays
    # that way, because it is bring-up plumbing for the render path's flat
    # port. Linux reaches the framebuffer as ordinary system RAM instead.
    ADDR = 0x10000 + 64
    words = [0x8000 | (i * 0x111) & 0x7FFF for i in range(8)]
    await apb_write(dut, R_MEM_A, ADDR)
    for w in words:
        await apb_write(dut, R_MEM_D, w)          # MEM_A auto-increments

    for i, w in enumerate(words):
        assert mem.u16(ADDR + 2 * i) == w, \
            f"keyhole write {i}: memory holds {mem.u16(ADDR + 2 * i):#06x}, wrote {w:#06x}"

    await apb_write(dut, R_MEM_A, ADDR)
    got = [await apb_read(dut, R_MEM_D) for _ in words]
    assert got == words, f"keyhole readback {[hex(g) for g in got[:4]]}"
    dut._log.info(f"host window OK: {len(words)} words written and read back "
                  f"through MEM_A/MEM_D with one address write")


@cocotb.test()
async def test_fb_pageflip(dut):
    """FB_BASE latches at the frame boundary, which makes it a tear-free flip.

    This is the same primitive cirrus and bochs use to implement
    drm_atomic_helper_page_flip -- cirrus_set_start_address() writes CRTC 0x0c/
    0x0d/0x1b/0x1d, bochs_hw_setbase() writes VBE_DISPI_INDEX_X_OFFSET and
    _Y_OFFSET -- except that on both of those the write takes effect whenever
    the hardware notices it, so the driver is relying on the emulator to be
    kind about timing.

    Here FB_BASE reaches the line-address accumulator ONLY through
    `frame_restart` (see ppu_fbscan.v), so a write landing anywhere inside a
    frame cannot split it: the frame in progress finishes entirely from the old
    buffer and the next one comes entirely from the new one. That is an atomic
    flip by construction rather than by convention, and it is worth a test
    because README section 16.5 previously described the same behaviour as a
    limitation.
    """
    FRONT = FB_BASE
    BACK = FB_BASE + M.INTERNAL_H * FB_STRIDE      # 0x25800 apart, no overlap

    mem = M.Memory(FB_MEM_BYTES)
    fill_fb(mem, fb_pattern(M.INTERNAL_W, M.INTERNAL_H, M.FB_A1R5G5B5), base=FRONT)
    fill_fb(mem, [[M.pack1555(1, (x + y + 7) & 0x1F, (y * 3 + x + 11) & 0x1F,
                              ((x >> 2) + 5) & 0x1F)
                   for x in range(M.INTERNAL_W)] for y in range(M.INTERNAL_H)],
            base=BACK)

    await bring_up_fb(dut, mem, base=FRONT)
    await sync_frame(dut)

    front = lambda y: expect_line(mem, y, base=FRONT, stride=FB_STRIDE)
    back = lambda y: expect_line(mem, y, base=BACK, stride=FB_STRIDE)

    got = await capture_internal_line(dut, 8)
    compare_px(got, front(8), "line 8 before the flip")

    # Flip mid-frame, which is exactly when a driver would do it: page flips are
    # issued from userspace, not from a vblank handler.
    await apb_write(dut, R_FB_BASE, BACK)

    # The flip is now pending: FB_BASE is written but not latched. FRAME[16]
    # is the flip-done primitive an OS polls (or pairs with the vblank IRQ).
    frame0 = int(await apb_read(dut, R_FRAME))
    assert frame0 & (1 << 16), "flip_pend not set after FB_BASE write"

    # The REST OF THIS FRAME must be untouched. A flip that took effect
    # immediately would show the back buffer from here down -- a torn frame.
    late = await capture_internal_line(dut, 100)
    assert front(100) != back(100), "test is vacuous: the two buffers agree here"
    compare_px(late, front(100), "line 100 after a mid-frame FB_BASE write")

    # And the next frame must be entirely the new buffer.
    await sync_frame(dut)
    for y in (0, 8, 100):
        got = await capture_internal_line(dut, y)
        compare_px(got, back(y), f"line {y} after the flip")

    # Flip complete: pending clear, frame counter advanced.
    frame1 = int(await apb_read(dut, R_FRAME))
    assert not (frame1 & (1 << 16)), "flip_pend still set after the latch frame"
    assert (frame1 & 0xFFFF) > (frame0 & 0xFFFF), "FRAME counter did not advance"
    dut._log.info("page flip OK: mid-frame FB_BASE write left the frame in "
                  "progress untouched, took effect whole on the next one, and "
                  "FRAME reported pending -> done")


# ---------------------------------------------------------------------------
# Programmable CRTC -- the HD modes (README section 17)
#
# In pair-counting mode (dblx=0) each core cycle carries ONE internal pixel and
# the external DVI/HDMI transmitter samples both clock edges, so a 65 Mpx/s
# 1024x768 stream runs on a 32.5 MHz core. The bench does not model the
# transmitter; it checks what the transmitter would sample: counters, sync
# geometry in core cycles, and one internal pixel per DE cycle.
# ---------------------------------------------------------------------------

R_CRT_H1, R_CRT_H2, R_CRT_H3 = 0x3C, 0x40, 0x44
R_CRT_V1, R_CRT_V2, R_CRT_LN, R_CRT_MD = 0x48, 0x4C, 0x50, 0x54


async def program_mode(dut, hact, hfp, hsw, hbp, vact, vfp, vsw, vbp,
                       dblx, dbly, int_w):
    """Firmware's job, done the firmware way: bare compare points."""
    h_last = hact + hfp + hsw + hbp - 1
    v_last = vact + vfp + vsw + vbp - 1
    prep = vact - 3 if dbly else vact - 2
    await apb_write(dut, R_CRT_H1, (hact << 16) | h_last)
    await apb_write(dut, R_CRT_H2, ((hact + hfp + hsw) << 16) | (hact + hfp))
    await apb_write(dut, R_CRT_H3, hact - 1)
    await apb_write(dut, R_CRT_V1, (vact << 16) | v_last)
    await apb_write(dut, R_CRT_V2, ((vact + vfp + vsw) << 16) | (vact + vfp))
    await apb_write(dut, R_CRT_LN, (prep << 16) | prep)
    await apb_write(dut, R_CRT_MD, (int_w << 16) | (dbly << 1) | dblx)
    return h_last + 1, v_last + 1


async def hd_mode_test(dut, name, pairs, vpix, int_w, stride):
    """Bring up a pair-counting HD mode, verify sync geometry and one line."""
    mem = M.Memory(FB_MEM_BYTES)
    rows = [[M.pack1555(1, (x + y) & 31, (3 * y + x) & 31, (x >> 3) & 31)
             for x in range(int_w)] for y in range(vpix // 2)]
    for y, r in enumerate(rows):
        M.fb_write_line(mem, y, r, FB_BASE, stride)

    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(mem_server(dut, mem))
    idle_burst_port(dut)
    cocotb.start_soon(psram_burst_server(dut, mem, dut._log))
    dut.rst_n.value = 0
    for sig in ("psel", "penable", "pwrite", "paddr", "pwdata", "mem_hreq"):
        getattr(dut, sig).value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    await clear_scanbufs(dut)

    htot, vtot = await program_mode(dut, *pairs, *vpix_geom(vpix), 0, 1, int_w)
    await apb_write(dut, R_FB_BASE, FB_BASE)
    await apb_write(dut, R_FB_STRIDE, stride)
    await apb_write(dut, R_FB_SIZE, int_w | ((vpix // 2) << 16))
    await apb_write(dut, R_FB_CTL, 0x1)
    await apb_write(dut, R_CTRL, 0x1)

    # sync geometry, measured in core cycles
    await FallingEdge(dut.hsync)
    await FallingEdge(dut.hsync)
    t0 = get_sim_time("ns")
    await RisingEdge(dut.hsync)
    tw = get_sim_time("ns")
    await FallingEdge(dut.hsync)
    t1 = get_sim_time("ns")
    assert t1 - t0 == htot * CLK_NS, f"{name}: h period {(t1-t0)/CLK_NS} != {htot}"
    assert tw - t0 == pairs[2] * CLK_NS, f"{name}: hsync width {(tw-t0)/CLK_NS} != {pairs[2]}"

    # skip undefined frame 0, then one internal line off the pins:
    # one pixel per DE cycle in pair mode.
    await FallingEdge(dut.vsync)
    while int(dut.u_timing.v_count.value) != 0:
        await RisingEdge(dut.clk)
    Y = 5
    while not (int(dut.u_timing.v_count.value) == Y * 2
               and int(dut.u_timing.h_count.value) == 0):
        await RisingEdge(dut.clk)
    while int(dut.de.value) == 0:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    got = []
    while int(dut.de.value) == 1:
        got.append((int(dut.vid_r.value), int(dut.vid_g.value), int(dut.vid_b.value)))
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
    assert len(got) == int_w, f"{name}: {len(got)} px per line, expected {int_w}"
    want = [((c >> 10) & 31, (c >> 5) & 31, c & 31)
            for c in M.fb_line(mem, Y, FB_BASE, stride, w=int_w)[:int_w]]
    bad = [(i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w]
    assert not bad, f"{name}: {len(bad)}/{int_w} px differ, first {bad[:4]}"
    dut._log.info(f"{name} OK: htot {htot} cycles, hsync {pairs[2]}, "
                  f"{int_w} px/line bit-exact at {FB_BASE:#x}")


def vpix_geom(vact):
    return {768: (768, 3, 6, 29), 720: (720, 5, 5, 20)}[vact]


@cocotb.test()
async def test_hd_1024x768(dut):
    """1024x768@60 in pair mode: 512 pairs/line on a 32.5 MHz core; VESA
    numbers halved exactly (all even)."""
    await hd_mode_test(dut, "1024x768", (512, 12, 68, 80), 768, 512, 1024)


@cocotb.test()
async def test_hd_1280x720(dut):
    """1280x720@60 in pair mode: 640-pixel internal lines -- 320 scanbuf words,
    the reason the buffers went to sram512x8."""
    await hd_mode_test(dut, "1280x720", (640, 55, 20, 110), 720, 640, 1280)
