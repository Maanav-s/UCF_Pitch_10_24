# Builds the LAN8720 bring-up debug bitstream (board 2) without the GUI:
#   vivado -mode batch -source scripts/build_phy_debug.tcl
# Output: build/phy_debug/phy_debug.bit, plus timing and CDC reports.

set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root build phy_debug]
file mkdir $out

read_verilog -sv [list \
    $root/rtl/common/debounce.sv \
    $root/rtl/common/sevenseg.sv \
    $root/rtl/common/mdio_master.sv \
    $root/rtl/debug/phy_debug_top.sv]
read_xdc $root/constraints/phy_debug.xdc
auto_detect_xpm

synth_design -top phy_debug_top -part xc7a35tcpg236-1
opt_design
place_design
route_design

report_timing_summary -file $out/timing_summary.rpt
report_cdc            -file $out/cdc.rpt
write_bitstream -force $out/phy_debug.bit
