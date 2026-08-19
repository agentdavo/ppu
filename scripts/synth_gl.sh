#!/usr/bin/env bash
# Build the gate-level SIMULATION netlist (gate G6): scripts/synth_gl.ys, then
# rename the SRAM macro instances from yosys's escaped generate-scope names
# (`\lane[0].u_sram `) to plain identifiers (`gl_lane_0_u_sram`). cocotb cannot
# address the escaped form at all -- its handle lookup insists `lane` is an
# array and chokes on the dot -- so the testbench pokes the macros through the
# plain names instead (see _lane_sram in tb/ppu_tb.py).
set -euo pipefail
cd "$(dirname "$0")/.."
PDK_ROOT="${PDK_ROOT:-../../gf180mcu/ciel/gf180mcu/versions/f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7/gf180mcuD}"
CORNER="${CORNER:-tt_025C_5v00}"
LIB="$PDK_ROOT/libs.ref/gf180mcu_fd_sc_mcu7t5v0/lib/gf180mcu_fd_sc_mcu7t5v0__${CORNER}.lib"
[ -f "$LIB" ] || { echo "liberty not found: $LIB" >&2; exit 2; }
mkdir -p reports
sed "s|@LIBERTY@|$LIB|g" scripts/synth_gl.ys > reports/synth_gl.gen.ys
YOSYS="${YOSYS:-yosys}"
"$YOSYS" -l reports/synth_gl.log reports/synth_gl.gen.ys >/dev/null 2>&1 || {
    echo "GL synthesis failed; see reports/synth_gl.log" >&2
    tail -20 reports/synth_gl.log; exit 1; }
sed -i 's/\\lane\[\([0-9]\)\]\.u_sram /gl_lane_\1_u_sram /g' reports/ppu_synth_gl.v
echo "wrote reports/ppu_synth_gl.v"
