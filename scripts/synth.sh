#!/usr/bin/env bash
# Synthesise the PPU to gf180mcu_fd_sc_mcu7t5v0 and report real cell area.
#
# Replaces the estimate in ip/ppu/README.md section 10 with a measured number.
# SRAM macros are blackboxed (hard macros with known LEF area) and added back
# in the summary rather than double-counted as logic.
set -euo pipefail
cd "$(dirname "$0")/.."
PDK_ROOT="${PDK_ROOT:-../../gf180mcu/gf180mcuD}"
CORNER="${CORNER:-tt_025C_5v00}"
LIB="$PDK_ROOT/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__${CORNER}.lib"
[ -f "$LIB" ] || { echo "liberty not found: $LIB" >&2; exit 2; }
mkdir -p reports
sed "s|@LIBERTY@|$LIB|g" scripts/synth.ys > reports/synth.gen.ys
yosys -l reports/synth.log reports/synth.gen.ys >/dev/null 2>&1 || {
    echo "synthesis failed; see reports/synth.log" >&2; tail -20 reports/synth.log; exit 1; }
python3 scripts/area_report.py
