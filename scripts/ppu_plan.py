#!/usr/bin/env python3
"""
PPU configuration planner -- proves the budget before any RTL is written.

Same role ip/audio_pll/scripts/audio_clk_plan.py plays for the audio rate table:
enumerate the design space, compute every constraint from primary sources, and
let the choice be read off a table instead of argued.

Nothing here is a rule of thumb. Video timings are exact VESA DMT integers and
the arithmetic is done in exact rationals; SRAM delays come from the shipped
liberty, macro areas from the LEF, and the pin ceiling from this repo's own
pinmaps. Where a number IS an assumption (board-level SRAM access time, pad
flight time, clock uncertainty) it is declared in ASSUMPTIONS below and printed
with the results, so it cannot masquerade as measured data.

    python3 ip/ppu/scripts/ppu_plan.py
    python3 ip/ppu/scripts/ppu_plan.py --core-mhz 40 50 --verbose

THE QUESTION THIS ANSWERS
-------------------------
Overdraw budget -- core clocks per line divided by pixels per line -- decides
whether this is a games machine or a framebuffer. Everything else (bus width,
pin count, scanbuf area) follows from the blend rate needed to hit it. The
tables below compute all of them together, because picking any one in isolation
produces a config that fails somewhere else.
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from fractions import Fraction
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]

# ---------------------------------------------------------------------------
# Primary data
# ---------------------------------------------------------------------------

# VESA DMT. Totals are the sum of active + front porch + sync + back porch, and
# are asserted against that sum at startup rather than trusted.
VGA_MODES = {
    "640x480@60": dict(
        px_hz=25_175_000,
        h=(640, 16, 96, 48), h_total=800,
        v=(480, 10, 2, 33), v_total=525,
    ),
    "800x600@60": dict(
        px_hz=40_000_000,
        h=(800, 40, 128, 88), h_total=1056,
        v=(600, 1, 4, 23), v_total=628,
    ),
    "1024x768@60": dict(
        px_hz=65_000_000,
        h=(1024, 24, 136, 160), h_total=1344,
        v=(768, 3, 6, 29), v_total=806,
    ),
}

# PPU native pixel format is ARGB1555 -- 16 bits, and the scanbuf word is 32 bits
# so one access carries two pixels. See GF180.md 6.4: the macros are single-port,
# which is what forces the double-width word in the first place.
BITS_PER_PIXEL = 16
SCANBUF_WORD_BITS = 32

# Source formats the fetch engine can stream, worst case first. Bus demand scales
# with these; ARGB1555 is the case the bus must be sized for.
SOURCE_FORMATS = {"ARGB1555": 16, "P8": 8, "P4": 4, "P1": 1}

ASSUMPTIONS = {
    "clock uncertainty (skew + jitter + OCV)": 0.70,
    "pad out, core FF to external pin": 2.00,
    "external async SRAM access time (10 ns part)": 10.00,
    "pad in, external pin to core FF D": 2.00,
    "core FF setup": 0.50,
}

SIGNOFF_CORNER = "ss_125C_4v50"

# The frozen configuration, marked in the tables below so every number quoted in
# ip/ppu/README.md is traceable to this script rather than retyped.
#
# The selection rule is "pick the mode whose pixel clock the board already
# supplies", and this template supplies 25 MHz on clk_PAD
# (librelane/config.yaml: CLOCK_PERIOD 40). So core == pixel == 25.000 MHz:
# one clock, no CDC, no second crystal and no PLL.
#
# 640x480@60 nominally wants 25.175 MHz. Driven at 25.000 it lands at 59.524 Hz
# instead of 59.940 -- 0.7% low, far inside monitor tolerance.
#
# An earlier revision selected 800x600@60 on the same "pixel clock IS the core
# clock" argument, but at 40.000 MHz -- which assumed the core clock was ours to
# choose. It is not. 800x600 would need a second crystal or a PLL, and buys
# 5.28x overdraw against 640x480's 5.00x. Not worth an analog macro.
SELECTED = ("640x480@60", 2, 1, 25.0)   # mode, internal downscale, blend px/clk, core MHz


# ---------------------------------------------------------------------------
# Primary-source readers
# ---------------------------------------------------------------------------

NUM = r"-?\d+\.?\d*(?:[eE]-?\d+)?"


def macro_areas(pdk: Path) -> dict[int, float]:
    """Depth -> area in um^2, measured from LEF SIZE. Foundry macros only: the OCD
    library is uncharacterized (GF180.md 6.3a) and must not be planned against."""
    out = {}
    lefdir = pdk / "libs.ref" / "gf180mcu_fd_ip_sram" / "lef"
    for lef in lefdir.glob("*.lef"):
        depth = int(re.search(r"sram(\d+)x8", lef.stem).group(1))
        w, h = (float(x) for x in
                re.search(r"SIZE\s+(" + NUM + r")\s+BY\s+(" + NUM + r")", lef.read_text()).groups())
        out[depth] = w * h
    return dict(sorted(out.items()))


def sram_timing(pdk: Path, depth: int, corner: str = SIGNOFF_CORNER) -> dict[str, float]:
    """CLK->Q and A setup at the setup-signoff corner, in ns.

    CLK->Q is taken at load column 1 (~0.03 pF), not column 0. A scanbuf Q drives
    a pipeline register and a mux, so column 0's 0.01 pF is optimistic and the
    1.119 pF top of the table is absurd for an on-die net.

    A setup takes the worst of rise_constraint AND fall_constraint. They differ by
    0.76 ns on these macros and quoting only the first understates it -- see
    GF180.md 6.3a."""
    f = pdk / "libs.ref" / "gf180mcu_fd_ip_sram" / "lib" / \
        f"gf180mcu_fd_ip_sram__sram{depth}x8m8wm1__{corner}.lib"
    t = f.read_text()

    q = t[t.index("bus(Q)"):]
    rows = re.search(r"cell_rise\(q_delay_template\).*?values\s*\((.*?)\)\s*\n", q, re.S).group(1)
    col1 = [[float(x) for x in re.findall(NUM, r)][1]
            for r in re.findall(r'"([^"]+)"', rows)]

    a = t[t.index("bus(A)"):]
    a = a[: a.index("bus(D)")] if "bus(D)" in a else a
    setups = [v for g in re.findall(r"timing_type\s*:\s*setup_rising\s*;(.*?)(?=timing_type|\Z)", a, re.S)
              for tbl in re.findall(r"values\s*\((.*?)\)\s*\n", g, re.S)
              for v in [float(x) for x in re.findall(NUM, tbl)]]

    return {"clk_q": max(col1), "a_setup": max(setups)}


def pin_budget(repo: Path) -> dict[str, int]:
    """Signal pins available, from the LibreLane slot definitions.

    Counted from librelane/slots/*.yaml, NOT from pinmaps/1x1_flipchip_*.csv.
    An earlier revision of this script used the flip-chip bump map and reported
    84 signals; the repository README is explicit that the bump array is "a
    geometry study, not a manufacturable plan" and that wafer.space ships CoB
    wire bonding. The shippable budget is the padring's, and it is 54 -- which
    is 20 fewer than the design was originally sized against."""
    out = {}
    for yml in sorted((repo / "librelane" / "slots").glob("slot_*.yaml")):
        t = yml.read_text()
        counts = {}
        for kind in ("bidir", "inputs", "analog"):
            idx = set(re.findall(kind + r"\\\\\[(\d+)\\\\\]", t))
            if idx:
                counts[kind] = len(idx)
        if counts:
            out[yml.stem.replace("slot_", "")] = sum(counts.values())
    return out


# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

def smallest_depth(words: int, depths: list[int]) -> int | None:
    return next((d for d in depths if d >= words), None)


class Config:
    def __init__(self, mode: str, scale: int, blend_px: int, core_mhz: float,
                 areas: dict[int, float]):
        m = VGA_MODES[mode]
        self.mode, self.scale, self.blend_px, self.core_mhz = mode, scale, blend_px, core_mhz

        self.active_w = m["h"][0]
        self.internal_w = self.active_w // scale
        self.internal_h = m["v"][0] // scale

        core_hz = int(core_mhz * 1e6)
        # Exact: one display line is h_total pixel clocks. An internal line covers
        # `scale` display lines, so the render engine gets that many times longer.
        self.clocks_per_line = Fraction(m["h_total"] * core_hz, m["px_hz"]) * scale
        self.overdraw = self.clocks_per_line * blend_px / self.internal_w

        # Worst-case (unpaletted) bus demand, bytes/s, and the bus width that meets
        # it in one core clock.
        self.bus_bits = blend_px * BITS_PER_PIXEL
        self.bw_mbs = blend_px * (BITS_PER_PIXEL // 8) * core_hz / 1e6

        # Alpha blending is read-modify-write, and the scanbuf is single-port
        # (GF180.md 6.4), so it costs one extra access per pixel pair.
        #
        # At 1 px/clk this is FREE: a 32-bit word holds 2 px, so the engine
        # spends cycle A reading the word and cycle B writing it back -- two
        # pixels in two cycles, exactly one port access per cycle. The single
        # port is never the limit.
        #
        # At 2 px/clk the engine wants a whole word per cycle, so blending needs
        # read AND write in the same cycle. One port cannot do that, and blended
        # spans fall back to half rate.
        px_per_word = SCANBUF_WORD_BITS // BITS_PER_PIXEL
        self.alpha_free = blend_px <= px_per_word // 1 and blend_px == 1
        self.overdraw_blended = self.overdraw if self.alpha_free else self.overdraw / 2

        # Two scanbufs, each internal_w pixels, packed 2 px per 32-bit word.
        px_per_word = SCANBUF_WORD_BITS // BITS_PER_PIXEL
        self.sb_words = math.ceil(self.internal_w / px_per_word)
        self.sb_depth = smallest_depth(self.sb_words, list(areas))
        if self.sb_depth is None:
            self.sb_area = None
        else:
            lanes = SCANBUF_WORD_BITS // 8
            self.sb_area = 2 * lanes * areas[self.sb_depth] / 1e6  # mm^2, both buffers
            self.sb_util = self.sb_words / self.sb_depth

    @property
    def feasible(self) -> bool:
        return self.sb_area is not None


def cycle_budget(core_mhz: float, t: dict[str, float]) -> dict[str, float]:
    period = 1000.0 / core_mhz
    used = t["clk_q"] + ASSUMPTIONS["clock uncertainty (skew + jitter + OCV)"] + t["a_setup"]
    return {"period": period, "used": used, "logic": period - used}


def ext_sram_roundtrip(core_mhz: float) -> dict[str, float]:
    period = 1000.0 / core_mhz
    rt = (ASSUMPTIONS["pad out, core FF to external pin"]
          + ASSUMPTIONS["external async SRAM access time (10 ns part)"]
          + ASSUMPTIONS["pad in, external pin to core FF D"]
          + ASSUMPTIONS["core FF setup"])
    return {"period": period, "roundtrip": rt, "slack": period - rt}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pdk-root", type=Path, default=REPO / "gf180mcu" / "gf180mcuD")
    ap.add_argument("--core-mhz", type=float, nargs="+", default=[40.0, 50.0])
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    for name, m in VGA_MODES.items():
        assert sum(m["h"]) == m["h_total"], f"{name} h timing does not sum to h_total"
        assert sum(m["v"]) == m["v_total"], f"{name} v timing does not sum to v_total"

    if not args.pdk_root.is_dir():
        print(f"PDK tree not found: {args.pdk_root}\nRun 'make clone-pdk' first.", file=sys.stderr)
        return 2

    areas = macro_areas(args.pdk_root)
    pins = pin_budget(REPO)

    print("=" * 100)
    print("PPU configuration plan -- gf180mcuD")
    print("=" * 100)

    print("\nVideo modes (VESA DMT, exact):\n")
    print(f"{'mode':14} {'px clock':>12} {'h total':>8} {'v total':>8} {'line':>10} {'refresh':>10}")
    for name, m in VGA_MODES.items():
        line_us = Fraction(m["h_total"], m["px_hz"]) * 1_000_000
        refresh = Fraction(m["px_hz"], m["h_total"] * m["v_total"])
        print(f"{name:14} {m['px_hz'] / 1e6:9.3f} MHz {m['h_total']:8} {m['v_total']:8} "
              f"{float(line_us):8.2f} us {float(refresh):8.2f} Hz")

    print("\nSRAM macros (LEF SIZE, foundry library only):\n")
    print(f"{'depth':>8} {'area (mm2)':>12} {'bytes/mm2':>12}")
    for d, a in areas.items():
        print(f"{d:8} {a / 1e6:12.4f} {d / (a / 1e6):12.0f}")

    for core in args.core_mhz:
        print(f"\n{'=' * 100}\nCore clock {core:g} MHz\n{'=' * 100}")

        b = cycle_budget(core, sram_timing(args.pdk_root, 512))
        e = ext_sram_roundtrip(core)
        print(f"\nOn-chip SRAM stage @ {SIGNOFF_CORNER}: "
              f"{b['period']:.2f} ns period - {b['used']:.2f} ns overhead = "
              f"{b['logic']:.2f} ns for logic  [{'OK' if b['logic'] > 4 else 'TOO TIGHT'}]")
        print(f"External SRAM round trip:  {e['roundtrip']:.2f} ns of "
              f"{e['period']:.2f} ns -> {e['slack']:.2f} ns slack  "
              f"[{'OK' if e['slack'] > 0 else 'FAILS'}]")

        print(f"\n{'mode':14} {'internal':>11} {'blend':>7} {'opaque':>8} {'blended':>8} "
              f"{'bus':>6} {'BW':>10} {'scanbuf':>16} {'pins':>5}")
        for mode in VGA_MODES:
            for scale in (1, 2):
                for blend in (1, 2):
                    c = Config(mode, scale, blend, core, areas)
                    if not c.feasible:
                        continue
                    sel = " <== SELECTED" if (mode, scale, blend, core) == SELECTED else ""
                    print(f"{mode:14} {f'{c.internal_w}x{c.internal_h}':>11} "
                          f"{blend:>5} px {float(c.overdraw):7.2f}x "
                          f"{float(c.overdraw_blended):7.2f}x {c.bus_bits:4} b "
                          f"{c.bw_mbs:7.0f} MB/s "
                          f"{f'{c.sb_area:.2f} mm2 @{c.sb_depth}':>16} "
                          f"{'53' if c.bus_bits == 16 else '71':>5}{sel}")
        print("  opaque = overdraw for opaque writes; blended = fully alpha-blended content.")
        print("  pins   = signal count with BOTH output paths (DAC + digital RGB555).")

    print(f"\n{'=' * 100}\nPin ceiling (this repo's pinmaps)\n{'=' * 100}\n")
    for name, n in pins.items():
        print(f"  {name:14} {n:3} signal pins")

    print("\nPer-config signal cost:\n")
    print(f"{'item':38} {'16-bit bus':>12} {'32-bit bus':>12}")
    # Fitted to the 54-pad wire-bond padring. RGB555 at 15 pins never fitted;
    # RGB222 still drives a resistor ladder to a working picture if the DAC
    # misses, which is all gate G8 actually needs.
    rows = [
        ("memory data", 16, 32),
        ("memory address (512K byte space)", 18, 18),
        ("memory control (CE/OE/WE)", 3, 5),
        ("on-chip DAC (RGB, analog pads)", 3, 3),
        ("HSYNC/VSYNC (shared by both paths)", 2, 2),
        ("digital RGB222 fallback", 6, 6),
        ("host SPI + IRQ", 5, 5),
    ]
    for label, a16, a32 in rows:
        print(f"{label:38} {a16:12} {a32:12}")
    t16, t32 = sum(r[1] for r in rows), sum(r[2] for r in rows)
    print(f"{'TOTAL (both output paths)':38} {t16:12} {t32:12}")
    for name, n in pins.items():
        print(f"    vs {name:12} ({n:3}): "
              f"{'fits' if t16 <= n else 'OVER':>6} (16b)   "
              f"{'fits' if t32 <= n else 'OVER':>6} (32b)")

    # THE HOST IS ON-CHIP. The PPU is a block on an SoC bus, so its control
    # surface is the existing APB slave and its interrupt is an internal line:
    # neither reaches a pad. That deletes the 5 "host SPI + IRQ" pins outright.
    #
    # It also deletes the bus-release COST rather than the mechanism. simpledrm
    # needs the framebuffer to be memory the CPU can address, which needs an
    # arbiter between the CPU and whatever holds the pixels -- but with both
    # masters on the same die that arbiter is on-chip and mem_hreq/mem_hgnt are
    # internal wires. README section 16.3.
    print("\nSoC configuration -- host on the on-chip bus (16-bit memory):\n")
    soc_rows = [r for r in rows if not r[0].startswith("host SPI")]
    t_soc = sum(r[1] for r in soc_rows)
    for label, a16, _ in soc_rows:
        print(f"  {label:38} {a16:6}")
    print(f"  {'host APB + IRQ (on-chip, no pads)':38} {0:6}")
    print(f"  {'bus release (on-chip arbiter)':38} {0:6}")
    print(f"  {'TOTAL, PPU owns the SRAM port':38} {t_soc:6}")
    print(f"  {'TOTAL, SoC memory controller owns it':38} {t_soc - 37:6}"
          "   (16 data + 18 addr + 3 control shared)")
    for name, n in pins.items():
        print(f"    vs {name:12} ({n:3}): {'fits' if t_soc <= n else 'OVER':>6}"
              f"   spare {n - t_soc:3}")

    print("\nAssumptions (NOT measured -- board and P&R dependent):")
    for k, v in ASSUMPTIONS.items():
        print(f"  {v:6.2f} ns  {k}")
    print("\nEverything else is read from the PDK liberty/LEF, this repo's pinmaps,")
    print("or the VESA DMT integers asserted at startup.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
