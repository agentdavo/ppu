#!/usr/bin/env python3
"""
Turn the Yosys stat report into the area budget that ip/ppu/README.md quotes.

Standard-cell area comes from synthesis against the real
gf180mcu_fd_sc_mcu7t5v0 liberty. SRAM macros are blackboxed during synthesis --
they are hard macros, so their area comes from the LEF instead and is added here
rather than double-counted as logic.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PPU = HERE.parent
PDK = Path(__file__).resolve().parents[3] / "gf180mcu" / "gf180mcuD"

# Macro instance counts, from the RTL. Kept explicit so a change in the design
# that is not reflected here shows up as a mismatch against the netlist.
MACROS = {
    # Scanbufs deepened 256 -> 512 words for the HD modes: a 1280x720 display
    # doubled is a 640-px internal line = 320 words. +0.50 mm2 over sram256.
    "sram512x8m8wm1": {
        "scanbuf (2 buffers x 4 lanes)": 8,
    },
    "sram256x8m8wm1": {
        "palette RAM (16 b wide)": 2,
    },
}


def lef_area(macro: str) -> float:
    lef = PDK / "libs.ref" / "gf180mcu_fd_ip_sram" / "lef" / \
        f"gf180mcu_fd_ip_sram__{macro}.lef"
    m = re.search(r"SIZE\s+([\d.]+)\s+BY\s+([\d.]+)", lef.read_text())
    return float(m.group(1)) * float(m.group(2))


def main() -> int:
    stat = PPU / "reports" / "stat.txt"
    if not stat.exists():
        print("no reports/stat.txt -- run scripts/synth.sh first", file=sys.stderr)
        return 2
    text = stat.read_text()

    m = re.search(r"Chip area for module '\\ppu_top':\s*([\d.]+)", text)
    cell_area = float(m.group(1)) if m else 0.0
    seq = re.search(r"sequential elements:\s*([\d.]+)", text)
    seq_area = float(seq.group(1)) if seq else 0.0

    cells = re.findall(r"^\s+(\d+)\s+\S+\s+(gf180mcu_fd_sc_\S+)$", text, re.M)
    total_cells = sum(int(n) for n, _ in cells)
    flops = sum(int(n) for n, c in cells if "__dff" in c or "__sdff" in c)

    print("=" * 68)
    print("PPU synthesis area -- gf180mcu_fd_sc_mcu7t5v0, tt_025C_5v00")
    print("=" * 68)
    print(f"\nStandard cells   {total_cells:>8} instances")
    print(f"  of which flops {flops:>8}")
    print(f"  combinational  {total_cells - flops:>8}")
    print(f"\nLogic area       {cell_area / 1e6:>8.4f} mm2"
          f"   ({seq_area / cell_area:.0%} sequential)" if cell_area else "")

    macro_total = 0.0
    print("\nHard macros (LEF area, blackboxed during synthesis):")
    for macro, uses in MACROS.items():
        a = lef_area(macro)
        for label, n in uses.items():
            print(f"  {label:34} {n:>3} x {a / 1e6:.4f} = {n * a / 1e6:7.4f} mm2")
            macro_total += n * a

    print(f"\n{'Logic':36} {cell_area / 1e6:>19.4f} mm2")
    print(f"{'Macros':36} {macro_total / 1e6:>19.4f} mm2")
    print(f"{'TOTAL (pre-place, 100% util)':36} {(cell_area + macro_total) / 1e6:>19.4f} mm2")
    for util in (0.60, 0.70):
        placed = cell_area / util + macro_total
        print(f"{f'At {util:.0%} placement utilisation':36} {placed / 1e6:>19.4f} mm2")
    print("\nBudget in README section 10 is 4.0 mm2 (gate G10).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
