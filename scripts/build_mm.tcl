# Builds the two-trader exchange bitstream (exchange ports on JB and JC,
# FPGA trader on JXADC) without the GUI:
#   vivado -mode batch -source scripts/build_mm.tcl
# Output: build/mm/mm.bit, plus timing and CDC reports.
#
# rtl/mm/mm_fix_pkg.sv is generated: python tools/mm_fix.py --sv rtl/mm/mm_fix_pkg.sv

set root [file normalize [file join [file dirname [info script]] ..]]
set out  [file join $root build mm]
file mkdir $out

read_verilog -sv [list \
    $root/rtl/mm/mm_fix_pkg.sv \
    $root/rtl/mm/mm_pkg.sv \
    $root/rtl/board2_eth/crc32.sv \
    $root/rtl/board2_eth/rmii_rx.sv \
    $root/rtl/board2_eth/rmii_tx.sv \
    $root/rtl/common/bin2bcd.sv \
    $root/rtl/common/debounce.sv \
    $root/rtl/common/sevenseg.sv \
    $root/rtl/common/uart_tx.sv \
    $root/rtl/mm/fix_frame_gen.sv \
    $root/rtl/mm/fix_frame_parse.sv \
    $root/rtl/mm/rmii_port.sv \
    $root/rtl/mm/mm_book.sv \
    $root/rtl/mm/mm_event_log.sv \
    $root/rtl/mm/mm_dump.sv \
    $root/rtl/mm/mm_exchange.sv \
    $root/rtl/mm/mm_trader.sv \
    $root/rtl/mm/mm_top.sv]
read_xdc $root/constraints/mm.xdc
auto_detect_xpm

# FSM extraction is off, as in the other builds: Vivado 2025.2 crashed in it
# on exchange_core (see the fsm_encoding notes in the RTL).
synth_design -top mm_top -part xc7a35tcpg236-1 -fsm_extraction off
opt_design
place_design
route_design

report_timing_summary -file $out/timing_summary.rpt
report_cdc            -file $out/cdc.rpt
report_clock_interaction -file $out/clock_interaction.rpt
write_bitstream -force $out/mm.bit
