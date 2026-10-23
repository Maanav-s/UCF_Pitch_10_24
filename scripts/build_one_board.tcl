# Builds the single-board bitstream (exchange on JB, trader on JC) without
# the GUI:
#   vivado -mode batch -source scripts/build_one_board.tcl
#   vivado -mode batch -source scripts/build_one_board.tcl -tclargs spec
# With "spec", the trader is built with SPECULATIVE_TX = 1.
# Output: build/one_board[_spec]/one_board.bit, plus timing and CDC reports.

set root [file normalize [file join [file dirname [info script]] ..]]
set spec [expr {[llength $argv] > 0 && [lindex $argv 0] eq "spec"}]
set out  [file join $root build [expr {$spec ? "one_board_spec" : "one_board"}]]
file mkdir $out

read_verilog -sv [list \
    $root/rtl/board1/fix_packets_pkg.sv \
    $root/rtl/board2_eth/crc32.sv \
    $root/rtl/board2_eth/rmii_rx.sv \
    $root/rtl/board2_eth/rmii_tx.sv \
    $root/rtl/common/bin2bcd.sv \
    $root/rtl/common/debounce.sv \
    $root/rtl/common/latency_timer.sv \
    $root/rtl/common/sevenseg.sv \
    $root/rtl/common/uart_tx.sv \
    $root/rtl/board1/exchange_core.sv \
    $root/rtl/board1/sample_log.sv \
    $root/rtl/board1/exchange_dump.sv \
    $root/rtl/board1/exchange.sv \
    $root/rtl/board2_eth/trader_core.sv \
    $root/rtl/one_board/one_board_top.sv]
read_xdc $root/constraints/one_board.xdc
auto_detect_xpm

# FSM extraction is off, as in the project settings: Vivado 2025.2 crashed in
# it on exchange_core (see the fsm_encoding note there).
synth_design -top one_board_top -part xc7a35tcpg236-1 -fsm_extraction off \
    -generic SPECULATIVE_TX=$spec
opt_design
place_design
route_design

report_timing_summary -file $out/timing_summary.rpt
report_cdc            -file $out/cdc.rpt
write_bitstream -force $out/one_board.bit
