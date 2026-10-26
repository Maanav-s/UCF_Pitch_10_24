# Latency arbitrage demo

Exchange **E** (FPGA) is the matching engine and the fair source. Laptop **P** is the market maker. FPGA **F** is the sniper. F only goes long: it buys a stale ask when fair jumps up by more than the 2-tick spread, then sells the new bid after P requotes.

```
  JA cable                    JB cable
  Laptop (P) ──────── E (Basys3, 2× LAN8720) ──────── F (Basys3, 1× LAN8720)
  192.168.10.1                192.168.10.2                   192.168.10.3
  02:00:00:00:00:01           02:00:00:00:00:02              02:00:00:00:00:03
```

The third Ethernet cable is unused. E’s two PHYs share the **JB 50 MHz** clock. `pkt_rx_async.sv` exists but is **not** in the pipeline; see [Async FIFO (not plugged in)](#async-fifo-not-plugged-in).

Prices are ticks: $1.00 = 100, $100.00 = 10000. P quotes 2-wide: bid = fair − 1, ask = fair + 1. The fair path is hardcoded (Brownian motion, seed 1, 16 jumps, 1.1–1.8 s apart), starting at $100.00.

## Sample waveforms

Each raised block is one Ethernet packet. The insides of the packet are not shown.

Opening: E sends the same fair ($100.00) to P and F. P posts a bid and an ask. E answers with BOOK (drawn here as the book updating, not as extra traces).

```mermaid
timing
  title Opening fair $100.00
  E to P    : FAIR 100
  E to F    : FAIR 100
  P to E    : BID 99.99, ASK 100.01
  F to E    : Idle
```

Snipe: fair jumps to $110.00. F buys the still-resting $100.01 ask. P’s cancel arrives after the fill, so E rejects it as too late.

```mermaid
timing
  title Fair jumps $100 to $110 (long snipe)
  E to P    : FAIR 110
  E to F    : FAIR 110
  F to E    : IOC buy 100.01
  P to E    : cancel (too late)
```

After that, P posts a new bid/ask around $110. E sends BOOK. F sells the new bid and flattens. Down-jumps do nothing on F.

## Files

| Role | Files |
| --- | --- |
| Protocol, fair ROM | `lat-arb-rtl/lat_arb_pkg.sv` |
| Exchange | `lat-arb-rtl/exchange_latarb.sv`, `exchange_latarb_top.sv` |
| Sniper | `lat-arb-rtl/trader_sniper.sv`, `trader_sniper_top.sv` |
| Wire path | `lat-arb-rtl/pkt_tx.sv`, `pkt_rx.sv`, `rmii_tx.sv`, `rmii_rx.sv`, `crc32.sv` |
| Book / PnL | `lat-arb-rtl/book_match.sv` |
| UART log | `lat-arb-rtl/event_dump.sv` |
| Optional JA CDC | `lat-arb-rtl/pkt_rx_async.sv` (not wired in yet) |
| PC maker | `host/market_maker.py` |
| Sim | `sim/tb_latarb.sv` |
| Pins | `constraints/exchange_latarb.xdc`, `constraints/trader_sniper.xdc` |

`host/market_maker.py` is new. `host/laptop_trader.py` and the old FIX exchange were not edited for this demo.

## Async FIFO (not plugged in)

`pkt_rx_async.sv` is a standalone copy. The live path still uses `pkt_rx` everywhere:

| Instance | File | Module |
| --- | --- | --- |
| `u_frx` (FPGA port) | `exchange_latarb.sv` | `pkt_rx` |
| `u_prx` (laptop port) | `exchange_latarb.sv` | `pkt_rx` |
| `u_rx` | `trader_sniper.sv` | `pkt_rx` |
| `u_mmrx` | `sim/tb_latarb.sv` | `pkt_rx` |

Nothing instantiates `pkt_rx_async`. That is why both PHYs on E share JB’s 50 MHz (`rmii_f_ref_clk`). JA[0] is unused on purpose. The F port does not need CDC: it already shares that clock.

Leave it this way for the current hardware and for `tb_latarb`. Do not add `pkt_rx_async.sv` to the sim set unless you have wired it.

To give the JA LAN8720 its own 50 MHz REF_CLK later, swap only the laptop receive path. Keep `u_frx` as `pkt_rx`.

1. In `exchange_latarb.sv`, replace `pkt_rx u_prx` with `pkt_rx_async u_prx`. Drive `wr_clk` / `wr_rst` from the JA PHY clock and `rd_clk` / `rd_rst` from the exchange clock (JB). RMII RX pins stay on the wr side; `pkt_valid` / `pay` / `pay_len` stay on the rd side.
2. In `exchange_latarb_top.sv`, add an `rmii_p_ref_clk` input, `BUFG` it, and pass both clocks into the core. Keep the existing `BUFG` on `rmii_f_ref_clk` as the exchange clock.
3. In `constraints/exchange_latarb.xdc`, map `rmii_p_ref_clk` to JA[0] (`PACKAGE_PIN J1` on Basys3 JA) and `create_clock` it as a second 50 MHz domain. Do not share that net with JB.
4. Add `pkt_rx_async.sv` to the E project. It uses `xpm_fifo_async` / `xpm_cdc_single` (Vivado XPM).

Until those four edits exist, JA[0] must stay unused and both PHYs must share JB’s clock.

## Simulation

1. In Vivado, add as **SystemVerilog** simulation sources:
   - everything in `lat-arb-rtl/` that the bench uses (`lat_arb_pkg.sv`, `crc32.sv`, `rmii_tx.sv`, `rmii_rx.sv`, `pkt_tx.sv`, `pkt_rx.sv`, `book_match.sv`, `exchange_latarb.sv`, `trader_sniper.sv`)
   - `sim/tb_latarb.sv`
2. Set the simulation top to **`tb_latarb`**.
3. Run a **behavioral** simulation.

The bench uses `DELAY_DIV=50000`, so a 1 s fair wait is 1000 clocks. It should finish in a few milliseconds of sim time (the `#20ms` watchdog is the limit).

Console should look like:

```
Start run
quotes up fv=10000
snipe fv=10083 fill=... late=...
pnl F=... P=... n=...
TB_LATARB PASS
```

`late_seen` may still be 0 on the exact cycle `snipe_seen` rises. F fills before P’s cancel is processed. If that check fails, it is often the bench sampling too early, not a dead book.

Waveform: add `fv_now`, `quotes_up`, `snipe_seen`, `late_seen`, and the four RMII `tx_en` nets. Each `tx_en` pulse is one packet.

## Hardware

### Boards

| Board | Top | Constraints | PHY |
| --- | --- | --- | --- |
| E | `exchange_latarb_top` | `constraints/exchange_latarb.xdc` | LAN8720 on **JB** (to F) and **JA** (to laptop). Clock from JB only. |
| F | `trader_sniper_top` | `constraints/trader_sniper.xdc` | LAN8720 on **JB**. `SW[7:0]` = extra milliseconds after FAIR before the snipe (0 = fastest). |

Add the `lat-arb-rtl` sources to each project. Do not use the old `exchange` top.

### Laptop

Same NIC setup as the old FIX trader (MAC `02:00:00:00:00:01`, IP `192.168.10.1`, static ARP for `192.168.10.2`):

```bash
# macOS
sudo bash host/setup_mac.sh en5          # your adapter
python3 host/market_maker.py --verbose

# Windows (Admin)
powershell -ExecutionPolicy Bypass -File host\setup_windows.ps1 -Adapter "Ethernet 2"
python host\market_maker.py --verbose
```

`--busy` busy-polls the socket (steadier, one core at 100%).

### Controls on E

| Control | Action |
| --- | --- |
| BTNC | Start the fair path |
| BTNU | Abort / clear |
| BTNR | UART dump, 115200 8N1 |

| LED | Meaning |
| --- | --- |
| 0 | Run in progress |
| 1 | Both quotes resting |
| 2 | F has sniped at least once |
| 3 | A P cancel was too late |
| 4 / 5 | F port RX / TX |
| 6 / 7 | P port RX / TX |
| 8 | Dump in progress |
| 15 | Run done |

7-seg shows fair in whole dollars.

### Bring-up order

1. Program F, then E. Cable E-JB to F-JB, E-JA to the laptop. Power the PHYs.
2. Run the NIC setup script, then `market_maker.py`.
3. Press BTNC on E. LED1 should light after P quotes. After the first up-jump (~1.1 s), LED2 (snipe) and usually LED3 (cancel too late).
4. After the 16 jumps, LED15. BTNR dumps:

```
# lat-arb n=17
0,10000,0,...,0
1,10083,<fill_px>,<pnl_f>,<pnl_p>,<flags>
...
# done
```

`flags` bit 0 = F sniped that jump, bit 1 = P cancel was too late. Capture with `tools/capture.py` or any 115200 serial reader.

### If nothing moves

- LED1 never lights: P is not quoting. Check MAC/IP/ARP, firewall, and that `market_maker.py` is running (not `laptop_trader.py`).
- LED2 never lights: no up-jump snipe. Confirm F is programmed with `trader_sniper_top` and `SW[7:0]=0`.
- Timeouts / no packets: both PHYs must share JB’s 50 MHz. JA[0] is unused on purpose.
