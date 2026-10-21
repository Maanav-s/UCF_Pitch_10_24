## LAN8720 bring-up debug design (rtl/debug/phy_debug_top.sv), board 2.
## Package pins are taken from Basys3_Master.xdc.

set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## 100 MHz oscillator
set_property -dict {PACKAGE_PIN W5 IOSTANDARD LVCMOS33} [get_ports clk]
create_clock -name clk_sys -period 10.000 [get_ports clk]

## Switches SW[2:0]: display select
set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} [get_ports {sw[0]}]
set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} [get_ports {sw[1]}]
set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} [get_ports {sw[2]}]

## BTNC: force MODE = 111 and soft-reset the PHY
set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} [get_ports btnC]

## LEDs
set_property -dict {PACKAGE_PIN U16 IOSTANDARD LVCMOS33} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN U19 IOSTANDARD LVCMOS33} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN V19 IOSTANDARD LVCMOS33} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN U15 IOSTANDARD LVCMOS33} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN U14 IOSTANDARD LVCMOS33} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN V14 IOSTANDARD LVCMOS33} [get_ports {led[7]}]
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports {led[8]}]
set_property -dict {PACKAGE_PIN V3  IOSTANDARD LVCMOS33} [get_ports {led[9]}]
set_property -dict {PACKAGE_PIN W3  IOSTANDARD LVCMOS33} [get_ports {led[10]}]
set_property -dict {PACKAGE_PIN U3  IOSTANDARD LVCMOS33} [get_ports {led[11]}]
set_property -dict {PACKAGE_PIN P3  IOSTANDARD LVCMOS33} [get_ports {led[12]}]
set_property -dict {PACKAGE_PIN N3  IOSTANDARD LVCMOS33} [get_ports {led[13]}]
set_property -dict {PACKAGE_PIN P1  IOSTANDARD LVCMOS33} [get_ports {led[14]}]
set_property -dict {PACKAGE_PIN L1  IOSTANDARD LVCMOS33} [get_ports {led[15]}]

## 7-segment display
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS33} [get_ports {seg[0]}]
set_property -dict {PACKAGE_PIN W6 IOSTANDARD LVCMOS33} [get_ports {seg[1]}]
set_property -dict {PACKAGE_PIN U8 IOSTANDARD LVCMOS33} [get_ports {seg[2]}]
set_property -dict {PACKAGE_PIN V8 IOSTANDARD LVCMOS33} [get_ports {seg[3]}]
set_property -dict {PACKAGE_PIN U5 IOSTANDARD LVCMOS33} [get_ports {seg[4]}]
set_property -dict {PACKAGE_PIN V5 IOSTANDARD LVCMOS33} [get_ports {seg[5]}]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS33} [get_ports {seg[6]}]
set_property -dict {PACKAGE_PIN V7 IOSTANDARD LVCMOS33} [get_ports dp]
set_property -dict {PACKAGE_PIN U2 IOSTANDARD LVCMOS33} [get_ports {an[0]}]
set_property -dict {PACKAGE_PIN U4 IOSTANDARD LVCMOS33} [get_ports {an[1]}]
set_property -dict {PACKAGE_PIN V4 IOSTANDARD LVCMOS33} [get_ports {an[2]}]
set_property -dict {PACKAGE_PIN W4 IOSTANDARD LVCMOS33} [get_ports {an[3]}]

## LAN8720 module on JB (spec §9 pinout)
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33}             [get_ports rmii_ref_clk]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33 PULLUP true} [get_ports rmii_crs_dv]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33 PULLUP true} [get_ports rmii_rxd0]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33 PULLUP true} [get_ports rmii_rxd1]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33}             [get_ports rmii_tx_en]
set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS33}             [get_ports rmii_txd0]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33}             [get_ports rmii_txd1]

## Self-test: 25 MHz out on JB[7] (JB pin 10), to be jumpered to JB pin 1
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS33}             [get_ports selftest_clk]

## MDIO on JC (debug only; the spec's run C leaves MDIO unconnected)
set_property -dict {PACKAGE_PIN K17 IOSTANDARD LVCMOS33}             [get_ports mdc]
set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33 PULLUP true} [get_ports mdio]

## REF_CLK: allow general routing to the BUFG in case JB[0] is not clock-capable (spec §9).
create_clock -name clk_rmii -period 20.000 [get_ports rmii_ref_clk]
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets rmii_ref_clk_IBUF]
set_clock_groups -asynchronous -group [get_clocks clk_sys] -group [get_clocks clk_rmii]
