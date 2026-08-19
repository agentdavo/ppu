# Pre-place STA for both PPU operating modes -- gate G1.
#
# Run from the repo root (shell.nix lives there):
#   nix-shell --run "openroad -no_init -exit ip/ppu/scripts/sta_modes.tcl"
#
# Two checks against reports/ppu_synth.v at ss_125C_4v50 (slow, hot, -10% VDD),
# 0.7 ns clock uncertainty, ideal clocks (pre-CTS):
#
#   1. games mode   -- 25 MHz, FULL design, no exceptions. The render engine
#                      (command processor, blend, affine multiplier) must make
#                      timing because it is running.
#   2. HD fb mode   -- 37.125 MHz (1280x720@60 worst case; 1024x768@60 is
#                      32.5 MHz and strictly easier), MODE SDC: fb_en is held 1
#                      by case analysis and the render-domain registers are
#                      false-pathed. This is sound, not optimistic: ppu_top.v
#                      line ~194 has `cmd_enable = enable && !fb_en`, so in
#                      framebuffer mode the command engine is structurally
#                      parked and s3_*/pend_* (blend pipeline) never load.
#
# The fb_en flop is found BY ITS Q NET, not by instance name -- yosys/abc
# instance names (_NNNNN_) change every resynthesis, net names of registered
# RTL signals survive flattening.
#
# Reference results (2026-08, -D 20 netlist, 8444 cells):
#   games 25 MHz         worst slack +0.38   tns 0
#   HD    37.125 MHz     worst slack +6.25   tns 0  (worst path = fbscan
#                                                    conversion -> scanbuf D)

set repo [file normalize [file join [file dirname [info script]] ../../..]]
set pdk  $repo/gf180mcu/ciel/gf180mcu/versions/f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7/gf180mcuD
set sc   $pdk/libs.ref/gf180mcu_fd_sc_mcu7t5v0
set sram $pdk/libs.ref/gf180mcu_fd_ip_sram

# Corner selectable via STA_CORNER; G1 requires both ss_125C_4v50 (hot-slow)
# and ss_n40C_4v50 (cold-slow -- temperature inversion can make it worse).
set corner ss_125C_4v50
if {[info exists env(STA_CORNER)]} { set corner $env(STA_CORNER) }
puts "=== corner: $corner ==="

read_lef $sc/techlef/gf180mcu_fd_sc_mcu7t5v0__nom.tlef
read_lef $sc/lef/gf180mcu_fd_sc_mcu7t5v0.lef
read_lef $sram/lef/gf180mcu_fd_ip_sram__sram256x8m8wm1.lef
read_lef $sram/lef/gf180mcu_fd_ip_sram__sram512x8m8wm1.lef
read_liberty $sc/lib/gf180mcu_fd_sc_mcu7t5v0__$corner.lib
read_liberty $sram/lib/gf180mcu_fd_ip_sram__sram256x8m8wm1__$corner.lib
read_liberty $sram/lib/gf180mcu_fd_ip_sram__sram512x8m8wm1__$corner.lib
read_verilog $repo/ip/ppu/reports/ppu_synth.v
link_design ppu_top

# ---- check 1: games mode, 25 MHz, full design --------------------------------
create_clock -name clk -period 40.0 [get_ports clk]
set_clock_uncertainty 0.7 [get_clocks clk]
puts "=== games mode: 25 MHz, full design, no exceptions ==="
puts "worst slack [format %.2f [sta::worst_slack -max]]  (must be >= 0)"
report_tns

# ---- check 2: HD framebuffer mode, 37.125 MHz, mode SDC ----------------------
create_clock -name clk -period 26.936 [get_ports clk]
set_clock_uncertainty 0.7 [get_clocks clk]

# fb_en is registered as u_csr.fb_ctrl[0]; find its flop via the net.
set fbnet [get_nets {u_csr.fb_ctrl[0]}]
if {$fbnet == ""} { error "u_csr.fb_ctrl\[0\] net not found -- netlist renamed?" }
set fbq ""
foreach p [get_pins -of_objects $fbnet -filter "direction == output"] { set fbq $p }
set_case_analysis 1 $fbq

# Render-domain registers, identified by their Q nets (names survive flatten).
foreach g {u_cmd.* s3_* pend_*} {
  set cells {}
  foreach p [get_pins -quiet -of_objects [get_nets -quiet $g] -filter "direction == output"] {
    set c [get_cells -of_objects $p]
    if {[string match "*dff*" [get_property $c ref_name]]} { lappend cells $c }
  }
  puts "false-path group $g: [llength $cells] flops"
  if {[llength $cells]} { set_false_path -from $cells }
}

puts "=== HD fb mode: 37.125 MHz, fb_en=1, render domain excluded ==="
puts "worst slack [format %.2f [sta::worst_slack -max]]  (must be >= 0)"
report_tns
report_checks -path_delay max -digits 3 -group_path_count 2
