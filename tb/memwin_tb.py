# SPDX-License-Identifier: Apache-2.0
"""
Host memory window -- the one piece of RTL simpledrm needs beyond a display list.

Deliberately fast and narrow: the PPU stays DISABLED, so the render engine never
competes for the bus. That separates "the write port works" from "the arbiter
starves it", which a full-frame test cannot do.

    python3 ip/ppu/tb/memwin_tb.py
"""
from pathlib import Path
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge
from cocotb_tools.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
import ppu_model as M  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent))
from aps12808 import idle_burst_port  # noqa: E402
from ppu_tb import R_CTRL, R_MEM_A, R_MEM_D, apb_read, apb_write, mem_server  # noqa: E402

CLK_NS = 40
FB = 0x10000


async def idle_bringup(dut, mem):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    cocotb.start_soon(mem_server(dut, mem))
    dut.rst_n.value = 0
    # mem_hreq must be driven, not left floating: ppu_top gates bus_grant on
    # `if (!mem_hreq)`, so an X input never releases the bus and the first
    # windowed write never completes. Every other bench in tb/ drives it.
    for sig in ("psel", "penable", "pwrite", "paddr", "pwdata", "mem_hreq"):
        getattr(dut, sig).value = 0
    idle_burst_port(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)


@cocotb.test()
async def test_memory_window_idle(dut):
    """Write and read back through MEM_ADDR/MEM_DATA with the PPU disabled."""
    mem = M.Memory()
    await idle_bringup(dut, mem)

    vals = [M.pack1555(1, i & 0x1F, (i * 5) & 0x1F, (i * 3) & 0x1F) for i in range(16)]

    await apb_write(dut, R_MEM_A, FB)
    for v in vals:
        await apb_write(dut, R_MEM_D, v)

    # The backing store must hold exactly what was written -- proves the write
    # actually reached external memory, not just the CSR.
    got = [mem.data[FB + 2 * i] | (mem.data[FB + 2 * i + 1] << 8) for i in range(16)]
    assert got == vals, f"memory contents differ:\n  got  {got}\n  want {vals}"

    # And MEM_ADDR must have auto-incremented across the run.
    end = await apb_read(dut, R_MEM_A)
    assert end == FB + 32, f"MEM_ADDR ended at {end:#x}, expected {FB + 32:#x}"

    # Read back through the same window.
    await apb_write(dut, R_MEM_A, FB)
    back = [await apb_read(dut, R_MEM_D) for _ in range(16)]
    assert back == vals, f"readback differs:\n  got  {back}\n  want {vals}"

    dut._log.info(f"memory window OK: 16 words written, verified in the backing "
                  f"store, auto-incremented to {end:#x}, and read back")


@cocotb.test()
async def test_memory_window_contended(dut):
    """Same writes with the PPU ENABLED and rendering a framebuffer list.

    This is the arbitration case: the render side has bus priority, so the host
    must still make progress rather than starve behind it."""
    mem = M.Memory()
    ppu = M.PPU(mem)
    prog = 0x8000
    M.framebuffer_list(FB, prog, mem)
    await idle_bringup(dut, mem)

    await apb_write(dut, R_MEM_A, prog)      # harmless; sets a known address
    await apb_write(dut, R_CTRL, 0x1)        # enable -- renderer starts fetching
    await ClockCycles(dut.clk, 2000)         # let it get busy

    vals = [0x8000 | (i * 7) for i in range(8)]
    await apb_write(dut, R_MEM_A, FB + 0x400)
    for v in vals:
        await apb_write(dut, R_MEM_D, v)

    got = [mem.data[FB + 0x400 + 2 * i] | (mem.data[FB + 0x400 + 2 * i + 1] << 8)
           for i in range(8)]
    assert got == vals, f"under contention:\n  got  {got}\n  want {vals}"
    dut._log.info("memory window OK under contention: host not starved by the renderer")


def main():
    ppu_dir = Path(__file__).resolve().parents[1]
    sources = [ppu_dir / "rtl" / f for f in (
        "ppu_blend.v", "ppu_timing.v", "ppu_cache.v", "ppu_unpack.v",
        "ppu_cmd.v", "ppu_scanbuf.v", "ppu_fbscan.v", "ppu_display.v",
        "ppu_csr.v", "ppu_top.v")]
    sources.append(ppu_dir / "tb" / "sram_behavioural.v")
    runner = get_runner("icarus")
    runner.build(verilog_sources=sources, hdl_toplevel="ppu_top",
                 includes=[ppu_dir / "rtl"], build_args=["-g2005"], always=True)
    runner.test(hdl_toplevel="ppu_top", test_module="memwin_tb")


if __name__ == "__main__":
    main()
