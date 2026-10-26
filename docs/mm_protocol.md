# Two-trader exchange with a thin order book

One Basys3 runs an FPGA exchange with two Ethernet ports and the FPGA
trader. A laptop trader is cabled to the exchange's first port, the FPGA
trader (on the same board, with its own PHY) to the second. Both traders run
the same market-making strategy on an ETF whose fair value follows AAPL. The
exchange prints AAPL prices from a script, keeps a two-order ETF book,
matches orders, and timestamps every message so the race between the two
traders can be read off a UART dump.

```
                 JB  PHY L ──── cable ──── laptop NIC     host/mm_trader.py (or .cpp)
 exchange ──┤
 (clk_ex)        JC  PHY F ──── cable ──── PHY T (JXADC) ── FPGA trader (clk_tr)
```

## Hardware

| Pmod | Module | Role | Clock |
| --- | --- | --- | --- |
| JB | LAN8720 | Exchange port L (laptop) | `clk_l`: the module's 50 MHz REF_CLK, RMII RX/TX only |
| JC | LAN8720 | Exchange port F (FPGA trader) | `clk_f`: the module's REF_CLK, RMII RX/TX only |
| JXADC | LAN8720 | FPGA trader's PHY | `clk_tr`: the module's REF_CLK, whole trader |
| W5 | 100 MHz oscillator | Exchange logic | `clk_ex` = 50 MHz from an MMCM (`MMCME2_BASE`, ×10 / 20) |

Pin order on every Pmod is the spec §9 one: `[0]` REF_CLK, `[1]` CRS_DV,
`[2]` RXD0, `[3]` RXD1, `[4]` TX_EN, `[5]` TXD0, `[6]` TXD1. The three REF_CLK
inputs and `clk_ex` are four unrelated clocks (`set_clock_groups
-asynchronous`).

Each exchange port crosses between its PHY clock and `clk_ex` through
`xpm_fifo_async` instances (`rtl/mm/rmii_port.sv`):

- **Receive**: `rmii_rx` (PHY clock) writes `{last, byte}` words into a
  9-bit FIFO; the exchange reads them cut-through, as they arrive. The
  frame end is a marker word with `last` = 1.
- **Transmit**: the exchange writes a whole frame at one byte per clock into
  a 9-bit data FIFO and then pushes a token into a second FIFO. The PHY side
  starts `rmii_tx` only when a token is there, so the frame is complete and
  cannot underrun.

The FPGA trader has no FIFOs: like `trader_core` before it, it runs entirely
on its own PHY's clock and acts on bytes as they arrive.

## Network

Both traders have MAC 02:00:00:00:00:01 and IP 192.168.10.1 (each link is
point to point, so the identities can be the same); the exchange is
02:00:00:00:00:02 / 192.168.10.2 on both ports. UDP port 5000 both ways.
The exchange does not do ARP, so the laptop needs the MAC override and the
static ARP entry that `host/setup_windows.ps1` / `host/setup_mac.sh` set up.
The exchange sends UDP checksum 0 (none); receivers do not check the source
MAC, IPv4 ID/flags/TTL, IPv4 checksum or UDP checksum, so an OS stack's
frames are accepted as they are. The FCS is checked on every received frame.

## Messages

Fixed-width FIX 4.4 tag=value, as in `docs/fix_test_packet.md`: every value
has a fixed width with leading zeros, so every field sits at a constant
offset and the FPGAs parse and build messages by position. `tools/mm_fix.py`
is the single source of the layouts; `python tools/mm_fix.py` prints them
with offsets, `--sv` writes `rtl/mm/mm_fix_pkg.sv` (one frame template and
one field map per type), `--check` proves template + field patches rebuild
every message byte-exact.

Prices are `DDDD.DD` (cents, $0.01 tick). Symbols are 4 characters:
`AAPL` and `ETF ` (trailing space). Quantities are always 00100; the exchange
carries them but every order trades as one unit, all or nothing.

| 35= | Message | Direction | Fields |
| --- | --- | --- | --- |
| X | Market Data Incremental Refresh | exchange → both traders | 55 symbol, 269 entry type (`0` bid, `1` offer, `2` trade), 270 price, 271 size |
| D | New Order Single | trader → exchange | 11 ClOrdID, 55, 54 side (`1` buy, `2` sell), 38 qty, 40=2 limit, 44 price |
| F | Order Cancel Request | trader → exchange | 11 ClOrdID (of the cancel), 41 OrigClOrdID, 55, 54 |
| 8 | Execution Report | exchange → one trader | 37 OrderID, 11 ClOrdID, 150 ExecType, 39 OrdStatus, 55, 54, 44 price (fill price on a trade), 38 |
| 9 | Order Cancel Reject | exchange → one trader | 37, 11, 41, 39 OrdStatus, 434=1, 102 reason (`0` too late to cancel, `1` unknown order) |

AAPL prints are `X` with 55=AAPL, 269=2. ETF book updates are `X` with
55=ETF and 269=0/1; size 00000 means the level is gone. 34 MsgSeqNum is one
counter per sender; the exchange's is shared by both ports, so each trader
sees gaps. 10 CheckSum is correct on every message.

## Exchange rules (`rtl/mm/mm_book.sv`, reference `tools/mm_model.py`)

The ETF book is two orders: one resting bid and one resting ask, each
`{trader, ClOrdID, OrderID, price}`. In the order the messages are sent:

| Incoming | Condition | Exchange sends |
| --- | --- | --- |
| D | symbol ≠ ETF, or side not 1/2 | 8 rejected (150=8, 39=8) |
| D | crosses the resting opposite order owned by the other trader | 8 filled (150=F, 39=2, 44 = resting price) to the taker, 8 filled to the maker, X size 0 for that level. The resting order is gone. |
| D | crosses the resting opposite order owned by the sender | 8 rejected (no self-trade) |
| D | same side empty, or price better than the resting same-side order | 8 canceled (150=4, 39=4) to the displaced trader if any, 8 new (150=0, 39=0) to the sender, X with the new level |
| D | otherwise | 8 rejected |
| F | 41 names the sender's resting order on that side | 8 canceled, X size 0 |
| F | 41 names the sender's last filled order | 9 with 39=2, 102=0 (too late to cancel) |
| F | otherwise | 9 with 39=8, 102=1 |

OrderIDs are a global counter, assigned when an order rests or fills;
rejects carry 37=00000.

## Strategy (both traders; `MarketMaker` in `tools/mm_model.py`)

Fair = 3/10 × AAPL + $20.00, in cents: $100 → $50, $200 → $80, $150 → $65,
$120 → $56, $180 → $74. On each AAPL print, in this order:

1. If the resting ETF ask is below fair and is not our own order: buy it at
   its price. Else if the resting bid is above fair and not ours: sell to it.
2. Cancel our resting bid, then our resting ask, if we have them.
3. If quoting: new bid at fair − half-spread, new ask at fair + half-spread.

ETF market data keeps the trader's view of the book. Execution reports for
the trader's own ClOrdIDs update its order state (new → active, anything
else → gone); other reports and cancel rejects change nothing. The trader
does not requote on a cancel notice, only on AAPL prints, so there are no
quote loops.

The FPGA trader quotes wider (half-spread from `SW[5:2]` dollars, use 2)
than the laptop (`--half-spread 1`), so the laptop's tighter quote replaces
the FPGA's and is the one resting when AAPL moves. The FPGA then lifts it
before the laptop's cancel arrives, and the laptop gets "too late to
cancel". With `SW[13]` on, the FPGA does not quote at all (taker only).

## Demo script and measurement

`SCRIPT_DOLLARS` in `tools/mm_fix.py` (default 100, 200, 150, 120, 180, 100)
is the sequence of AAPL prints, stored in `mm_fix_pkg`. BTNC sends the next
one; BTND plays the rest 1 s apart.

Every frame the exchange sends or accepts is logged with a 32-bit `clk_ex`
timestamp (20 ns ticks) in `mm_event_log` (1024 entries). BTNR dumps the log
over the USB-UART (115200 8N1) as CSV:

```
# mm label=A tick_ns=20 events=<n>
<i>,<ticks>,<dir>,<port>,<type>,<side>,<status>,<clordid>,<orderid>,<price>
...
# steps=<n>,fills=<n>,rx_bad=<n>
```

`dir` is `rx`/`tx`; `port` is `L`, `F` or `B` (both); `type` is the FIX
35= value; `side` is the 54 or 269 value; `status` is 150 for a report,
102 for a cancel reject, blank otherwise; `price` is in cents. A receive is
stamped when its last byte (FCS) has been checked, a transmit when its first
byte enters the TX FIFO, so a trader's "latency" in this log is from the
exchange's send decision to the exchange's acceptance of the reply, about
3 µs more than the wire-to-wire time, the same for both traders.

`python tools/race.py <run> [<run> ...]` reads captured dumps
(`tools/capture.py`), pools them, and scores the two traders from the log
alone:

- **Per print**: each trader's first message, the gap, stale quotes and
  pickoffs, fills, and the laptop's "too late" cancel rejects.
- **Latency** from the print to each trader's first message, last cancel
  and last message (its requote), as p50 / p90 / p95 / p99 / max.
- **Stale quotes**: a resting quote that the new fair puts on the wrong side
  (bid above fair, ask below). Each one ends picked off or canceled in time;
  reported with the pick-off rate and the exposure window.
- **Fills, PnL and markout**: taker and maker fills, position, PnL marked to
  the last print's fair, and markout per fill against fair at the fill and
  at the next print (100 shares per fill). Negative markout is an adverse
  fill.

The script is 6 prints, so one run gives 6 latency samples; for meaningful
p90 / p95, repeat BTNU, BTND, BTNR and capture a few times (mmA1, mmA2, ...)
and pass all the runs.

The 7-segment display shows, per `SW[1:0]`: `00` laptop − FPGA gap for the
last print (µs), `01` FPGA latency, `10` laptop latency, `11` fill count.
`XX.XX` below 100 µs, whole µs above, `----` without data.

## Controls (`rtl/mm/mm_top.sv`)

| Control | Function |
| --- | --- |
| BTNC | Send the next AAPL print of the script |
| BTND | Play the rest of the script, 1 s apart |
| BTNR | UART dump of the event log |
| BTNU | Clear: log, statistics, book, script position, trader state |
| BTNL | Hold: display shows the FPGA trader's half-spread |
| SW[1:0] | Display select (above) |
| SW[5:2] | FPGA trader half-spread in dollars (0 counts as 1) |
| SW[13] | FPGA trader taker-only (no quotes) |
| SW[15:14] | Run label in the dump |
| LED0 | Exchange busy (a print is being processed) |
| LED1 | Last print: FPGA's order arrived first |
| LED2 | Last print: laptop's message arrived first |
| LED3 | Script finished |
| LED4 / LED5 | Port L / port F receive activity |
| LED6 | Auto-play running |
| LED7 / LED8 | Book has a bid / an ask |
| LED9 / LED10 | FPGA trader sent a buy / a sell (50 ms stretch) |
| LED11 | FPGA trader received a frame it does not understand |
| LED12 | Event log full |
| LED13 | FPGA trader PHY receive activity |
| LED14 | Exchange received a bad frame (FCS, length or format) |
| LED15 | Dump in progress |

## Files

```
rtl/mm/mm_fix_pkg.sv     generated: templates, field maps, script, fair constants
rtl/mm/fix_frame_gen.sv  streams a template with fields patched in, checksum computed
rtl/mm/fix_frame_parse.sv checks a received frame against a template group, extracts fields
rtl/mm/rmii_port.sv      PHY-clock RMII RX/TX with xpm_fifo_async crossings to clk_ex
rtl/mm/mm_book.sv        order book, matching, message generation
rtl/mm/mm_event_log.sv   timestamped event log in block RAM
rtl/mm/mm_dump.sv        UART dump of the log
rtl/mm/mm_exchange.sv    exchange core: two ports, script, book, log, statistics
rtl/mm/mm_trader.sv      FPGA market-making trader (clk_tr)
rtl/mm/mm_top.sv         board top: MMCM, three PHYs, controls, display
constraints/mm.xdc
scripts/build_mm.tcl
sim/mm/                  testbench vectors from tools/mm_vectors.py
sim/tb_mm_frames.sv      frame generator and parser against the Python frames
sim/tb_mm_exchange.sv    exchange against scripted traders on both ports
sim/tb_mm_trader.sv      FPGA trader against the Python strategy
sim/tb_mm_e2e.sv         exchange + FPGA trader + scripted laptop
host/mm_trader.py        laptop trader (Python, Windows/macOS)
host/mm_trader.cpp       laptop trader (C++17, Linux)
tools/mm_fix.py mm_model.py mm_vectors.py race.py
```
