# CLAUDE.md

This folder is a Vivado project (`UCF_Pitch_10_24.xpr`) for a two-board FPGA tick-to-trade latency demo (Basys3 / Artix-7).

The authoritative specification is [fpga_tick_to_trade_spec.md](fpga_tick_to_trade_spec.md). Read it before making changes, and follow it for RTL, constraints, host software and verification.

## Synthesis and simulation

Do not run Vivado synthesis, implementation, bitstream generation or simulations yourself (no `vivado`, `xvlog`, `xelab`, `xsim` or similar commands). When a change is ready to check, tell the user which run to do (for example, behavioral simulation of a named testbench, or synthesis) and what to look for in the results, then wait for them to report back.

## Vivado 2025.2 quirks (both crash with no file or line named)

- **xsim:** `xelab` dies with `EXCEPTION_ACCESS_VIOLATION` in "simulation data flow analysis" when synthesizable RTL uses string literals as integer constants (`parameter logic [31:0] T = "AAPL"`, `rx_data == "1"`) or sized casts of `int` parameters inside case selectors (`2'(off - 11'(BASE))`). Write ASCII constants in hex with the text in a comment (`32'h4141_504C // "AAPL"`, `8'h30 // '0'`) and use plain `case` items. Testbench code with string literals is fine. `-O0`, `--mt off` and cache resets do not help; the stack trace is only in the Tcl console.
- **Synthesis:** crashes on variable part-selects of wide constants and in FSM extraction (see `exchange_dump.sv` and `exchange_core.sv`). Use ROMs indexed with constants, and keep FSM extraction off.

@fpga_tick_to_trade_spec.md
