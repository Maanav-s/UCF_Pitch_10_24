# Builds the FPGA trader bitstream (board 2, LAN8720 on JB) without the GUI:
#   vivado -mode batch -source scripts/build_board2_eth.tcl
#   vivado -mode batch -source scripts/build_board2_eth.tcl -tclargs spec
# With "spec", the trader is built with SPECULATIVE_TX = 1.
# Output: build/board2_eth[_spec]/board2_eth.bit, plus timing and CDC reports.

set root [file normalize [file join [file dirname [info script]] ..]]
set spec [expr {[llength $argv] > 0 && [lindex $argv 0] eq "spec"}]
set out  [file join $root build [expr {$spec ? "board2_eth_spec" : "board2_eth"}]]
file mkdir $out

read_verilog -sv [list \
    $root/rtl/board1/fix_packets_pkg.sv \
    $root/rtl/board2_eth/crc32.sv \
    $root/rtl/board2_eth/rmii_rx.sv \
    $root/rtl/board2_eth/rmii_tx.sv \
    $root/rtl/common/debounce.sv \
    $root/rtl/common/sevenseg.sv \
    $root/rtl/board2_eth/trader_core.sv \
    $root/rtl/board2_eth/board2_eth_top.sv]
read_xdc $root/constraints/board2_eth.xdc
auto_detect_xpm

synth_design -top board2_eth_top -part xc7a35tcpg236-1 -generic SPECULATIVE_TX=$spec
opt_design
place_design
route_design

report_timing_summary -file $out/timing_summary.rpt
report_cdc            -file $out/cdc.rpt
write_bitstream -force $out/board2_eth.bit
