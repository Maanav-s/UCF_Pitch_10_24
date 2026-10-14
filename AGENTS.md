# AGENTS.md

This folder is a Vivado project (`UCF_Pitch_10_24.xpr`) for a two-board FPGA tick-to-trade latency demo (Basys3 / Artix-7).

The authoritative specification is [fpga_tick_to_trade_spec.md](fpga_tick_to_trade_spec.md). Read it before making changes, and follow it for RTL, constraints, host software and verification.

## Synthesis and simulation

Do not run Vivado synthesis, implementation, bitstream generation or simulations yourself (no `vivado`, `xvlog`, `xelab`, `xsim` or similar commands). When a change is ready to check, tell the user which run to do (for example, behavioral simulation of a named testbench, or synthesis) and what to look for in the results, then wait for them to report back.
