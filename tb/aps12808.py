# SPDX-License-Identifier: Apache-2.0
"""
Bench model of the framebuffer read port: a dual-channel SoC memory controller
in front of two APS12808L-3OBMx OPI Xccela PSRAMs.

    two x8 DDR parts = a 16-bit DDR pair = 32 bits per memory clock
    128 Mb each, 32 MB total, 1 KB row, tCEM-bounded bursts

WHY THIS EXISTS
---------------
The bench used to model a flat asynchronous SRAM that answered one beat per
cycle, forever, with no command phase. Against that memory, ppu_fbscan's
latency tolerance was never exercised at all -- every claim about surviving a
late first beat or a mid-stream stall was an assertion, not a test. This model
makes the display controller earn those claims by reproducing the four things
the datasheet says will actually happen:

  LC latency          command + address + latency code before the first beat.
                      LC is 3/4/5 (MR0[4:2]); 5 is the power-up default.
  refresh pushout     an internal refresh landing on a read delays the first
                      beat by anywhere from LC to LC*2, and the device gives no
                      warning (section 8.5). Modelled as a random extra delay.
  tRBXwait            a linear read crossing a 1 KB row boundary stalls 30-65 ns
                      MID-STREAM (figure 6). Modelled at every 1 KB boundary.
  tCEM splitting      CE# may be low at most 8 us (85 C) or 3 us (105 C), so a
                      long line is served as several bursts with a gap between
                      them. Modelled as a stall every CEM_BEATS beats.

None of that is visible to ppu_fbscan as anything but gaps in `burst_valid`,
which is exactly the property under test.
"""

import os
import random

import cocotb
from cocotb.triggers import RisingEdge, Timer

# Interface. The controller runs faster than the 25 MHz core; what reaches the
# scanner is one 32-bit beat per core cycle when the stream is flowing.
LATENCY_CODE = int(os.environ.get("PSRAM_LC", "5"))          # MR0[4:2] = 010
REFRESH_PUSHOUT = os.environ.get("PSRAM_REFRESH", "1") != "0"
ROW_BYTES = 1024                                             # 1 KB row
RBX_WAIT_CYCLES = 2                                          # 30-65 ns at 25 MHz core
CEM_BEATS = int(os.environ.get("PSRAM_CEM_BEATS", "0"))      # 0 = no split
SEED = int(os.environ.get("PSRAM_SEED", "1"))


async def psram_burst_server(dut, mem, log=None):
    """Serve dut.fb_burst_* from `mem` (a ppu_model.Memory), the way the real
    controller and part would.

    Deliberately hostile within spec: the first beat is late by a random amount
    inside the LC..LC*2 window the datasheet permits, and the stream stalls at
    every row boundary and every tCEM limit.
    """
    rng = random.Random(SEED)
    dut.fb_burst_gnt.value = 0
    dut.fb_burst_valid.value = 0
    dut.fb_burst_data.value = 0
    stats = {"bursts": 0, "beats": 0, "stall_cycles": 0}

    while True:
        # --- wait for a request ------------------------------------------
        while True:
            await RisingEdge(dut.clk)
            await Timer(1, unit="ps")
            if int(dut.fb_burst_req.value):
                break

        addr = int(dut.fb_burst_addr.value)
        beats = int(dut.fb_burst_len.value)

        dut.fb_burst_gnt.value = 1
        await RisingEdge(dut.clk)
        dut.fb_burst_gnt.value = 0
        stats["bursts"] += 1

        # --- command + address + latency ---------------------------------
        # LC on a good day, up to LC*2 when a refresh gets in the way, and the
        # host is not told which it is going to be.
        wait = LATENCY_CODE
        if REFRESH_PUSHOUT:
            wait = rng.randint(LATENCY_CODE, LATENCY_CODE * 2)
        for _ in range(wait):
            await RisingEdge(dut.clk)
        stats["stall_cycles"] += wait

        # --- stream ------------------------------------------------------
        served = 0
        while served < beats:
            byte_addr = addr + served * 4

            # Row boundary: the part stalls mid-stream to open the next row.
            if served and (byte_addr % ROW_BYTES) == 0:
                dut.fb_burst_valid.value = 0
                for _ in range(RBX_WAIT_CYCLES):
                    await RisingEdge(dut.clk)
                stats["stall_cycles"] += RBX_WAIT_CYCLES

            # tCEM: CE# has to go high, so the controller re-issues.
            if CEM_BEATS and served and served % CEM_BEATS == 0:
                dut.fb_burst_valid.value = 0
                gap = LATENCY_CODE + 2
                for _ in range(gap):
                    await RisingEdge(dut.clk)
                stats["stall_cycles"] += gap

            n = len(mem.data)
            word = (mem.data[byte_addr % n]
                    | (mem.data[(byte_addr + 1) % n] << 8)
                    | (mem.data[(byte_addr + 2) % n] << 16)
                    | (mem.data[(byte_addr + 3) % n] << 24))
            dut.fb_burst_data.value = word
            dut.fb_burst_valid.value = 1
            await RisingEdge(dut.clk)
            served += 1
            stats["beats"] += 1

        dut.fb_burst_valid.value = 0
        if log and stats["bursts"] % 240 == 0:
            log.info(f"psram: {stats['bursts']} bursts, {stats['beats']} beats, "
                     f"{stats['stall_cycles']} stall cycles")


def idle_burst_port(dut):
    """Tie the port off for tests that never enable the framebuffer engine."""
    dut.fb_burst_gnt.value = 0
    dut.fb_burst_valid.value = 0
    dut.fb_burst_data.value = 0
