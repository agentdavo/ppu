# SPDX-License-Identifier: Apache-2.0
"""ppu_axi_rd in isolation: does every line request become LEGAL AXI4 bursts,
and does the reassembled stream carry exactly the right beats?

Hostile-within-spec slave: random ARREADY delay, random RVALID gaps. Legality
checked per AR: length <= 256 beats, INCR, 4-byte size, and the burst must not
cross a 4 KB boundary. Runs in milliseconds -- no frames, no PPU.
"""
import random
from pathlib import Path
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.runner import get_runner

rng = random.Random(7)


async def axi_slave(dut, log):
    """Serve R beats for each accepted AR; record every AR for legality checks."""
    dut.arready.value = 0
    dut.rvalid.value = 0
    dut.rlast.value = 0
    ars = []
    while True:
        # AR handshake with random readiness.
        while True:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            if int(dut.arvalid.value) and rng.random() < 0.4:
                break
        addr, beats = int(dut.araddr.value), int(dut.arlen.value) + 1
        ars.append((addr, beats))
        # legality, checked at the moment of acceptance
        assert beats <= 256, f"ARLEN burst of {beats} beats"
        assert (addr & 3) == 0, f"unaligned ARADDR {addr:#x}"
        assert (addr & ~0xFFF) == ((addr + 4 * beats - 1) & ~0xFFF), \
            f"AR at {addr:#x} x{beats} crosses 4 KB"
        assert int(dut.arsize.value) == 2 and int(dut.arburst.value) == 1
        dut.arready.value = 1
        await RisingEdge(dut.clk)
        dut.arready.value = 0
        # R stream with gaps; data encodes its own address.
        for i in range(beats):
            while rng.random() < 0.3:
                dut.rvalid.value = 0
                await RisingEdge(dut.clk)
            dut.rdata.value = (addr + 4 * i) & 0xFFFFFFFF
            dut.rvalid.value = 1
            dut.rlast.value = 1 if i == beats - 1 else 0
            await RisingEdge(dut.clk)
        dut.rvalid.value = 0
        dut.rlast.value = 0
        dut._ars = ars


async def one_line(dut, base, beats):
    """Issue one line request, collect the stream, check everything."""
    got = []

    async def collect():
        while len(got) < beats:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            if int(dut.burst_valid.value):
                got.append(int(dut.burst_data.value))
    task = cocotb.start_soon(collect())

    dut.burst_addr.value = base
    dut.burst_len.value = beats
    dut.burst_req.value = 1
    while True:
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.burst_gnt.value):
            break
    dut.burst_req.value = 0
    await task
    want = [(base + 4 * i) & 0xFFFFFFFF for i in range(beats)]
    assert got == want, f"stream wrong at base {base:#x}: first bad " + str(
        next((i, g, w) for i, (g, w) in enumerate(zip(got, want)) if g != w))


@cocotb.test()
async def splitting(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.rst_n.value = 0
    dut.burst_req.value = 0
    dut.burst_addr.value = 0
    dut.burst_len.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(axi_slave(dut, dut._log))

    await one_line(dut, 0x1F80000, 160)      # 16 bpp line, no boundary: 1 AR
    await one_line(dut, 0x1F80000, 320)      # 32 bpp line: ARLEN forces 2 ARs
    await one_line(dut, 0x0000FF8, 8)        # 2 beats to a 4 KB edge: split 2+6
    await one_line(dut, 0x0FFFC00, 320)      # crosses 4 KB mid-line
    for i in range(4):                       # back-to-back lines
        await one_line(dut, 0x1000000 + i * 640, 160)

    ars = dut._ars
    dut._log.info(f"axi_rd OK: {len(ars)} legal AR bursts for 8 line requests; "
                  f"lens {[b for _, b in ars]}")
    lens = [b for _, b in ars]
    assert lens == [160,            # 16 bpp line: one AR
                    256, 64,        # 320 beats: ARLEN cap forces 256+64
                    2, 6,           # 2 beats to the 4 KB edge, then the rest
                    256, 64,        # 4 KB crossing mid-line
                    160, 160, 160, 160], f"chunking wrong: {lens}"


def main():
    d = Path(__file__).resolve().parents[1]
    r = get_runner("icarus")
    r.build(verilog_sources=[d / "rtl" / "ppu_axi_rd.v"], hdl_toplevel="ppu_axi_rd",
            build_args=["-g2005"], always=True, build_dir="sim_build_axi",
            timescale=("1ns", "1ps"))
    r.test(hdl_toplevel="ppu_axi_rd", test_module="axi_rd_tb")


if __name__ == "__main__":
    main()
