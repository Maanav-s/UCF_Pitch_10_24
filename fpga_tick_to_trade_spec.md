# FPGA Tick-to-Trade Demo — Technical Specification

This document specifies a two-board FPGA latency demo for implementation. It covers RTL, constraints, host software and verification. Scheduling and presentation are out of scope.

## 1. Overview

Two Digilent Basys3 boards (Artix-7 XC7A35T-1CPG236C, 100 MHz oscillator), a Linux laptop, and WIZnet W5500 Ethernet modules. All trading traffic is real UDP over 100 Mb/s Ethernet.

- **Board 1 — exchange and stopwatch.** Sends market-data messages from BRAM as UDP packets through its own W5500 ("W5500-X"). It timestamps each send and each reply with a 200 MHz counter.
- **Trader under test.** Exactly one trader is cabled to board 1's Ethernet port at a time. All three use the same IP address and the same trading rule:
  - **Run A — board 2 with W5500.** An FPGA trader on board 2 reads each packet from its W5500 ("W5500-T") over SPI, decides, and sends the reply through the same W5500.
  - **Run B — laptop.** A C++ program on Linux receives each packet through the laptop's network interface and replies.
  - **Run C — board 2 with LAN8720 (extension).** An FPGA trader on board 2 runs its own Ethernet logic on a LAN8720 PHY over RMII. It decides as the bytes arrive off the wire and starts the reply before the incoming frame ends.

Board 1's hardware, configuration and measurement are identical in every run. Only the trader changes.

```
                  Ethernet cable (moved between runs)
 Board 1                           ┌──────────────────────────────────────────┐
 ┌───────────────────────┐         │ Run A: Board 2 ── W5500-T ⇄ SPI ⇄ trader │
 │ Feed replayer         │         │ Run B: Laptop ── NIC ⇄ kernel ⇄ trader   │
 │ SPI ⇄ W5500-X ────────┼─────────┤ Run C: Board 2 ── LAN8720 ⇄ RMII ⇄ MAC + │
 │ Timer (t0, t1)        │         │                  trader (extension)      │
 └───────────────────────┘         └──────────────────────────────────────────┘
```

Each reported latency is a full round trip: board 1's send path, the wire, the trader, the wire back, and board 1's receive path. Board 1's share is the same in every run, so differences between runs are differences between traders.

## 2. Conventions

- **HDL:** SystemVerilog (Verilog-2001 compatible where practical). **Toolchain:** AMD Vivado.
- **Byte order:** all multi-byte message fields are big-endian.
- **Prices:** unsigned 32-bit integers in units of $0.0001 (ITCH convention), so $50.00 = 500000.
- **Clock-domain crossings:** use the Xilinx Parameterized Macros (XPM):
  - `xpm_cdc_single` for single-bit levels
  - `xpm_cdc_array_single` for quasi-static buses (switches)
  - `xpm_cdc_pulse` for pulses
  - `xpm_fifo_async` for data
- **Signal names:** active-low signals end in `_n`.
- **Pins:** names refer to the Digilent `Basys3-Master.xdc` port names (`JA[0]`…`JA[7]`, etc.). Use that file for package pins; do not hand-assign them.
- **I/O standard:** all Pmod I/O is `LVCMOS33`.

## 3. Network

| Device | Role | MAC | IP | UDP port | Sends to |
| --- | --- | --- | --- | --- | --- |
| W5500-X (board 1) | Exchange | 02:00:00:00:00:02 | 192.168.10.2 | 5000 | 192.168.10.1:5000 |
| W5500-T (board 2, run A) | Trader | 02:00:00:00:00:01 | 192.168.10.1 | 5000 | 192.168.10.2:5000 |
| Laptop (run B) | Trader | its own | 192.168.10.1/24, static | 5000 | reply to sender |
| LAN8720 trader (board 2, run C) | Trader | 02:00:00:00:00:03 | 192.168.10.1 | 5000 | reply to sender |

- **Cabling:** a direct cable from W5500-X to the trader, with no switch. All devices auto-negotiate 100 Mb/s full duplex. W5500 and LAN8720 support auto-MDIX, so a straight cable works.
- **After moving the cable,** press board 1 BTNL to re-initialize W5500-X. That clears its cached ARP entry, so it resolves the new trader's MAC.

## 4. Message formats

### Market data (board 1 → trader): UDP payload, 20 bytes

| Offset | Size | Field | Values |
| --- | --- | --- | --- |
| 0 | 1 | `type` | `'A'` (0x41) = add order |
| 1 | 2 | `seq` | Sequence number, increments per message |
| 3 | 8 | `ticker` | ASCII, left-justified, space-padded |
| 11 | 1 | `side` | `'B'` (0x42) bid or `'S'` (0x53) ask |
| 12 | 4 | `price` | uint32, $0.0001 units |
| 16 | 4 | `qty` | uint32 |

### Reply (trader → board 1): UDP payload, 8 bytes

| Offset | Size | Field | Values |
| --- | --- | --- | --- |
| 0 | 1 | `type` | `'B'` (0x42) buy or `'N'` (0x4E) no trade |
| 1 | 2 | `seq` | Copied from the market-data message |
| 3 | 1 | `ticker_id` | Index of the matched ticker preset (0–3), else 0xFF |
| 4 | 4 | `price` | Copied from the market-data message |

Every market-data message gets exactly one reply, buy or no trade, so every message produces a latency sample.

## 5. Trading rule

Identical in all three traders.

- **Ticker:** one of 4 presets: `TICKER0`…`TICKER3`, 8-byte ASCII, defaults `"AAPL    "`, `"MSFT    "`, `"NVDA    "`, `"TSLA    "`. On board 2 the preset is selected by `SW[1:0]`.
- **Limit:** `LIMIT_BASE + k × LIMIT_STEP`, with defaults `LIMIT_BASE` = 400000 ($40.00) and `LIMIT_STEP` = 100 ($0.01). On board 2, `k` = `SW[13:2]` (0–4095), giving a range of $40.00–$80.95.
- **Decision:** reply `'B'` if all of the following hold, else reply `'N'`:
  - `type == 'A'`
  - `ticker == TICKER[sel]`
  - `side == 'S'`
  - `price <= limit`
- **Reply fields:** `ticker_id` = `sel` on a buy, else 0xFF.
- **Laptop:** ticker and limit are command-line arguments (§10).

## 6. W5500 interface (shared by board 1 and board 2)

Reference: WIZnet W5500 datasheet. The register addresses and command values below are the ones this design uses. **Verify each against the datasheet before relying on it.**

### SPI

- **Mode:** SPI mode 0, MSB first.
- **Clock:** `SCLK = clk_sys / SPI_DIV`. `SPI_DIV` default 4 (25 MHz); must also support 8 (12.5 MHz).
- **`SCLK` generation:** a register output driven by the state machine, not a clock net.
- **Frame:** `CS_n` low, then 16-bit address, then 8-bit control byte, then N data bytes, then `CS_n` high (variable-length data mode).
- **Control byte:** `{BSB[4:0], RWB, OM[1:0]}`, with `RWB` 1 = write, 0 = read, and `OM = 00`.
- **Block select (`BSB`):**

| Block | `BSB` |
| --- | --- |
| Common registers | `00000` |
| Socket 0 registers | `00001` |
| Socket 0 TX buffer | `00010` |
| Socket 0 RX buffer | `00011` |

- **`spi_master` interface:** a command port taking (address, `BSB`, read/write, length, data stream in/out) and a `done` flag.
  - Read data streams out byte by byte as it is received, so callers can act before a burst ends.
  - Bursts of at least 32 bytes must be supported.

### Registers used

| Block | Address | Name | Use |
| --- | --- | --- | --- |
| Common | 0x0001–0x0004 | `GAR` | Gateway: 0.0.0.0 |
| Common | 0x0005–0x0008 | `SUBR` | Subnet mask: 255.255.255.0 |
| Common | 0x0009–0x000E | `SHAR` | Source MAC |
| Common | 0x000F–0x0012 | `SIPR` | Source IP |
| Common | 0x0013–0x0014 | `INTLEVEL` | Interrupt re-assert interval: 0 |
| Common | 0x0018 | `SIMR` | Socket interrupt mask: 0x01 (socket 0) |
| Common | 0x002E | `PHYCFGR` | Bit 0 = link up |
| Common | 0x0039 | `VERSIONR` | Must read 0x04 |
| Socket 0 | 0x0000 | `Sn_MR` | 0x02 = UDP |
| Socket 0 | 0x0001 | `Sn_CR` | Commands; auto-clears to 0 when accepted |
| Socket 0 | 0x0002 | `Sn_IR` | Bit 4 `SEND_OK`, bit 2 `RECV`; write 1 to clear |
| Socket 0 | 0x0003 | `Sn_SR` | 0x22 = `SOCK_UDP` |
| Socket 0 | 0x0004–0x0005 | `Sn_PORT` | Local port |
| Socket 0 | 0x0006–0x000B | `Sn_DHAR` | Destination MAC; filled by ARP, used by `SEND_MAC` |
| Socket 0 | 0x000C–0x000F | `Sn_DIPR` | Destination IP |
| Socket 0 | 0x0010–0x0011 | `Sn_DPORT` | Destination port |
| Socket 0 | 0x0024–0x0025 | `Sn_TX_WR` | TX write pointer |
| Socket 0 | 0x0026–0x0027 | `Sn_RX_RSR` | Received size |
| Socket 0 | 0x0028–0x0029 | `Sn_RX_RD` | RX read pointer |
| Socket 0 | 0x002C | `Sn_IMR` | Socket interrupt mask: 0x04 (`RECV` only) |

Command values: `OPEN` = 0x01, `SEND` = 0x20, `SEND_MAC` = 0x21, `RECV` = 0x40.

### Init sequence

1. Drive `RST_n` low for 1 ms, release it, then wait 5 ms.
2. Read `VERSIONR`. If it isn't 0x04, flag an error and stop.
3. Write `SHAR`, `SIPR`, `SUBR` and `GAR` per §3.
4. Write `INTLEVEL` = 0, `SIMR` = 0x01, `Sn_IMR` = 0x04.
5. Write `Sn_MR` = 0x02 and `Sn_PORT` = 5000.
6. Write `Sn_CR` = `OPEN`, poll until `Sn_CR` reads 0, then confirm `Sn_SR` = 0x22.
7. Write `Sn_DIPR` and `Sn_DPORT` to the "Sends to" address in §3: 192.168.10.1:5000 on board 1, 192.168.10.2:5000 on board 2. A W5500 UDP socket always sends to these registers; it does not reply to a packet's sender automatically.
8. Read `Sn_TX_WR` and `Sn_RX_RD` into local shadow registers.
9. Poll `PHYCFGR[0]` continuously and show it on an LED. Do not block on it.

Any poll that exceeds `CMD_TIMEOUT_US` (default 1000) flags an error.

### Send

1. Burst-write the payload into the socket 0 TX buffer at address `tx_wr`, where `tx_wr` is the 16-bit shadow value. The chip wraps pointers into the buffer internally, so the 16-bit value is used directly as the address.
2. `tx_wr += len`; write `Sn_TX_WR`.
3. Write `Sn_CR` = `SEND` or `SEND_MAC` (see below).
4. Before the next send, wait for `Sn_IR.SEND_OK` and clear it by writing 0x10 to `Sn_IR`. This is off the critical path.

**ARP and `SEND_MAC`.** A plain `SEND` may trigger ARP resolution, which adds a variable delay. Each side therefore uses `SEND` for the warm-up exchanges (§7, `N_WARMUP`) and `SEND_MAC` afterwards. `SEND_MAC` sends to the MAC already in `Sn_DHAR` without ARP; `Sn_DHAR` is populated by the earlier ARP.

Parameter `USE_SEND_MAC` (default 1) disables this behavior when set to 0.

**Verify on hardware with Wireshark** that no ARP frames appear between timed messages.

### Receive

1. **Detect a packet:** `INT_n` goes low, because `RECV` is the only unmasked interrupt.
   - **Fallback:** poll `Sn_RX_RSR`, reading it twice per poll and accepting the value only when both reads agree, until non-zero.
2. **Read the packet:** burst-read from the socket 0 RX buffer at `rx_rd`. The first 8 bytes are the W5500 UDP header: sender IP (4), sender port (2), payload length (2). The payload follows.
3. **Release the buffer:**
   - `rx_rd += 8 + payload_length`; write `Sn_RX_RD`.
   - Write `Sn_CR` = `RECV`, and poll until `Sn_CR` reads 0.
4. **Clear the interrupt:** write 0x04 to `Sn_IR`. `INT_n` returns high.

`Sn_CR` accepts one command at a time. Always confirm `Sn_CR` reads 0 before writing a new command.

## 7. Board 1 — exchange and stopwatch

### Clocks

| Domain | Source | Contents |
| --- | --- | --- |
| `clk_sys` 100 MHz | MMCM from the oscillator | W5500-X SPI and control, buttons, 7-seg, UART |
| `clk_ts` 200 MHz | Same MMCM | Timestamp counter, `t0`/`t1` capture |

`clk_sys` and `clk_ts` are related, so Vivado times paths between them normally. `INT_n` is an asynchronous input.

### Modules

1. **`msg_rom`.** BRAM holding `N_MSGS` (default 4096) × 20-byte messages, initialized from `messages.mem` (generated by `tools/gen_messages.py`, §11). Byte-addressed or 32-bit-word layout, at the implementer's choice; document it in the generator.
2. **`w5500_ctrl`** (`clk_sys`). SPI master plus the §6 init, send and receive sequences for W5500-X.
3. **`feed_replayer`** (`clk_sys`).
   - **On run start:** first run `N_WARMUP` (default 16) warm-up exchanges using `SEND`. These are not recorded.
   - **Then, for `i = 0 … N_MSGS−1`:**
     1. Write message `i` into the TX buffer and advance `Sn_TX_WR`. Not timed.
     2. Write `Sn_CR` = `SEND_MAC`. The rising edge of `CS_n` that ends this command write is `t0`; signal it with a one-cycle `t0_pulse`.
     3. Wait for the reply (`INT_n` low), or a timeout of `TIMEOUT_US` (default 10000).
     4. After the reply, run the receive sequence and compare the reply's `seq` with `i`. On a mismatch, record a seq error.
     5. Wait `GAP_US` (default 100), then continue with the next message.
   - **Stale replies:** any reply whose `seq` doesn't match the current message (e.g. one arriving after a timeout) is read, discarded and counted.
4. **`timestamp`** (`clk_ts`).
   - **Counter:** 32-bit, free-running.
   - **`t0`:** the counter value at `t0_pulse`, registered across from `clk_sys`.
   - **`t1`:** pass `INT_n` through `xpm_cdc_single` (2 stages) into `clk_ts`. `t1` is the counter value at its first falling edge after `t0`.
   - **Latency:** `t1 − t0`, in 5 ns ticks.
5. **`sample_store`.** True dual-port BRAM, `N_MSGS` × 32-bit.
   - **Per message:** the latency, or `0xFFFFFFFF` for a timeout, or `0xFFFFFFFE` for a seq error. A latency is recorded only after the seq check passes.
   - **Counters:** `min`, `max`, `count`, `timeouts`, `seq_errors`, `buys`, `no_trades`.
6. **`uart_dump`** (`clk_sys`).
   - **Port:** 8N1 at `UART_BAUD` (default 115200) over the Basys3 USB-UART.
   - **On BTNR:**
     - A header line `# run label=<A|B|C|D>`, with the label taken from `SW[15:14]` = 00/01/10/11.
     - One line per sample: `<seq>,<ticks>\n`, decimal.
     - A summary line: `# min=<>,max=<>,count=<>,timeouts=<>,seq_errors=<>,buys=<>,no_trades=<>`.
7. **`display`** (`clk_sys`).
   - **Statistic shown:** selected by `SW[1:0]`: `00` last, `01` min, `10` max, `11` timeout count.
   - **Format:** latency in µs. `XX.XX` below 100 µs, an integer `XXXX` up to 9999, saturating above that. `----` when there's no data.

### Controls

| Control | Function |
| --- | --- |
| BTNC | Start run (clears statistics) |
| BTND | Abort run |
| BTNR | UART dump |
| BTNL | Re-initialize W5500-X (after moving the cable) |
| BTNU | Reset statistics |
| SW[1:0] | Display select |
| SW[15:14] | Run label for the UART dump |
| LED0 | Run in progress |
| LED1 | Run complete |
| LED2 | W5500-X init OK |
| LED3 | W5500-X PHY link up |
| LED13 | W5500 error |
| LED14 | Seq error seen |
| LED15 | Timeout seen |

Debounce all buttons.

### Pins

| Port | `[0]` | `[1]` | `[2]` | `[3]` | `[4]` | `[5]` |
| --- | --- | --- | --- | --- | --- | --- |
| JA | `SCLK` | `MOSI` | `MISO` | `CS_n` | `RST_n` | `INT_n` |

## 8. Board 2 — FPGA trader with W5500 (run A)

Single clock domain: `clk_sys` 100 MHz from the oscillator. Switches enter through `xpm_cdc_array_single` and are sampled only between messages.

### Modules

1. **`w5500_ctrl`.** Same SPI master and init as board 1, for W5500-T, with §3 identities and destination 192.168.10.2:5000.
2. **`trader_fsm`.** The critical path, ordered to send the reply as early as possible:
   1. Wait for `INT_n` low, passed through `xpm_cdc_single`.
   2. Burst-read **24 bytes** at `rx_rd`: the 8-byte W5500 header plus payload offsets 0–15, ending at the last price byte.
      - **Header check:** the payload length must be 20 and the sender must be 192.168.10.2:5000. Otherwise abort to the error path: read `Sn_RX_RSR`, discard the packet, count an error. The check runs in parallel with the read and does not delay the decision.
   3. Evaluate the §5 rule on the bytes as they stream out of the SPI master. The decision must be registered a fixed number of `clk_sys` cycles after the last price byte; document that number.
   4. Burst-write the 8-byte reply into the TX buffer at `tx_wr`.
   5. Write `Sn_TX_WR` = `tx_wr + 8`.
   6. Write `Sn_CR` = `SEND_MAC` (`SEND` during warm-up: the first `N_WARMUP` replies after init).
   7. **Off the critical path:**
      - Wait until `Sn_CR` reads 0.
      - Write `Sn_RX_RD` = `rx_rd + 28`, then write `Sn_CR` = `RECV` and wait until `Sn_CR` reads 0.
      - Write 0x14 to `Sn_IR` to clear both `RECV` and `SEND_OK`.
      - Update the shadow pointers.
3. **`display` / LEDs.** The 7-segment display shows the current limit as `XX.XX` dollars.

The critical path is about 47 SPI bytes plus 4 chip-select gaps, roughly 15 µs at 25 MHz. That is an estimate; the measurement will show the real figure.

### Controls

| Control | Function |
| --- | --- |
| BTNC | Re-initialize W5500-T |
| SW[1:0] | Ticker select |
| SW[13:2] | Limit `k` |
| LED0 | Buy (stretched to 50 ms per buy) |
| LED2 | W5500-T init OK |
| LED3 | W5500-T PHY link up |
| LED13 | Error (bad version, socket failed to open, command timeout, bad packet length) |

### Pins

| Port | `[0]` | `[1]` | `[2]` | `[3]` | `[4]` | `[5]` |
| --- | --- | --- | --- | --- | --- | --- |
| JA | `SCLK` | `MOSI` | `MISO` | `CS_n` | `RST_n` | `INT_n` |

### Power

Each W5500 module requires 3.3 V at ≥ 200 mA. Unless the Basys3 reference manual confirms the Pmod 3.3 V pins can supply that, power the modules from an external 3.3 V supply whose ground is tied to the Basys3 ground.

## 9. Board 2 — FPGA trader with LAN8720 (run C, extension)

A separate top level and bitstream (`board2_eth_top`) on the same board. The LAN8720 sits on JB, so the W5500-T can stay wired on JA.

### Clocks

| Domain | Source | Contents |
| --- | --- | --- |
| `clk_rmii` 50 MHz | LAN8720 module's reference clock output, on `JB[0]` | RMII RX, parser, trader, ARP responder, RMII TX, CRC |
| `clk_sys` 100 MHz | Oscillator | Switches, LEDs, 7-seg |

- **Reference clock path:** `JB[0]` → `IBUF` → `BUFG`. If `JB[0]` isn't clock-capable, add `CLOCK_DEDICATED_ROUTE FALSE` on that net.
- **Asynchronous groups:** `set_clock_groups -asynchronous` between `clk_rmii` and `clk_sys`.
- **Switches:** cross into `clk_rmii` via `xpm_cdc_array_single`, sampled only between frames.
- **No FIFO** on the trading path.

### RMII

- **Transmit:** `TXD[1:0]` and `TX_EN` are registered on `clk_rmii`, 2 bits per clock, LSB first within each byte.
  - **Setup margin:** if the PHY receives errors, launch on the falling edge (parameter `TX_NEGEDGE`).
- **Receive:** `RXD[1:0]` and `CRS_DV` are sampled on the rising edge of `clk_rmii`.
- **Frame end:** a frame has ended only when `CRS_DV` stays low for 2 consecutive dibit periods, because `CRS_DV` can toggle near the end of a frame.
- **MDIO:** unused and unconnected. The PHY's strap defaults (auto-negotiation, RMII) are relied on.

### Pins

| Port | `[0]` | `[1]` | `[2]` | `[3]` | `[4]` | `[5]` | `[6]` |
| --- | --- | --- | --- | --- | --- | --- | --- |
| JB | `REF_CLK` (50 MHz in) | `CRS_DV` | `RXD0` | `RXD1` | `TX_EN` | `TXD0` | `TXD1` |

The module labels its clock output `nINT/RETCLK` or similar; check the module's silkscreen.

### Modules

1. **`rmii_rx`.**
   - Detects the preamble and the `0xD5` start delimiter, then outputs bytes with their offset from the start of the destination MAC.
   - The FCS is not checked.
2. **`frame_parser`.** Classifies each frame on the fly.
   - **Market data:** EtherType 0x0800, IPv4 protocol 17, destination IP 192.168.10.1, UDP destination port 5000, UDP payload length 20. Fields are captured as they stream past: source MAC, source IP and source port, then the payload.
   - **ARP request:** EtherType 0x0806, opcode 1, target IP 192.168.10.1. Capture the sender MAC and sender IP.
   - **Everything else:** ignored.
3. **`trader`.**
   - Applies the §5 rule as the payload streams in.
   - Registers the decision a fixed number of `clk_rmii` cycles after the last price byte (frame offset 42 + 15 = 57). Document that number.
4. **`rmii_tx`.** Transmits a reply frame as soon as the decision is registered, while the incoming frame is still arriving (full duplex).

   | Bytes | Field | Value |
   | --- | --- | --- |
   | 8 | Preamble + start delimiter | `0x55` ×7, then `0xD5` |
   | 6 | Destination MAC | Captured source MAC |
   | 6 | Source MAC | 02:00:00:00:00:03 |
   | 2 | EtherType | 0x0800 |
   | 20 | IPv4 header | Version/IHL 0x45, TOS 0, total length 36, ID 0, flags/fragment 0, TTL 64, protocol 17, checksum, source 192.168.10.1, destination = captured source IP |
   | 8 | UDP header | Source port 5000, destination = captured source port, length 16, checksum 0 |
   | 8 | Payload | Reply per §4 |
   | 10 | Padding | Zeros, bringing the frame to the 60-byte minimum |
   | 4 | FCS | CRC32 |

   - **IPv4 checksum:** computed from the captured source IP during reception, so it is ready before the header goes out.
   - **FCS:** CRC32 over destination MAC through padding: polynomial 0x04C11DB7, initial value 0xFFFFFFFF, final inversion, transmitted LSB first. Byte-wide update logic, generated (not hand-derived).
   - **Inter-frame gap:** at least 12 byte times between frames.
5. **`arp_responder`.** On an ARP request for 192.168.10.1, sends an ARP reply:
   - Destination MAC = requester's MAC; source MAC 02:00:00:00:00:03; EtherType 0x0806.
   - Hardware type 1, protocol type 0x0800, sizes 6/4, opcode 2.
   - Sender = our MAC and IP; target = the requester's MAC and IP.
   - Padded to 60 bytes, plus FCS.
   - Shares `rmii_tx` with the reply path; market-data replies take priority.

**Optional advanced mode** (parameter `SPECULATIVE_TX`, default 0):

- Start transmitting the reply frame when an incoming frame's start delimiter is seen, using board 1's MAC and IP learned from the last valid market-data frame.
- By the time the 42 header bytes have gone out, the decision is ready.
- If the incoming frame turns out not to be a valid market-data message, end the outgoing frame with a deliberately wrong FCS, so board 1 discards it.

### Controls

Same as §8: `SW[1:0]` ticker, `SW[13:2]` limit, LED0 buy, 7-seg limit. LED4 lights on `CRS_DV` activity.

## 10. Laptop trader (`host/trader.cpp`, run B)

- **Platform:** Linux, C++17, built with `-O3 -march=native`.
- **Usage:** `trader --ticker AAPL --limit 55.25 [--port 5000] [--cpu N] [--busy-poll]`.
- **Socket:** UDP, bound to `0.0.0.0:<port>`, non-blocking. The main loop busy-polls `recvfrom`.
- **Per datagram:**
  - Ignore payloads shorter than 20 bytes.
  - Parse per §4 and apply the §5 rule.
  - `sendto` the 8-byte reply to the sender's address.
- **Hot path:** no allocation, no logging, no syscalls other than receive and send.
- **Options:**
  - `--cpu` pins the process with `sched_setaffinity`.
  - `--busy-poll` sets `SO_BUSY_POLL` where permitted.
- **On exit (SIGINT):** print counts of buys, no-trades and malformed packets.
- **Setup notes in a README:**
  - Static IP 192.168.10.1/24 on the Ethernet interface.
  - Interrupt coalescing off: `ethtool -C <iface> rx-usecs 0`.
  - CPU governor set to `performance`.
  - Confirm 100 Mb/s full duplex with `ethtool <iface>`.
  - Recommended run variants:
    - B: tuned, idle machine
    - D: same settings with background load, e.g. `stress-ng --cpu 0`

## 11. Tools (`tools/`, Python 3)

1. **`gen_messages.py`**
   - **Arguments:** `--n 4096 --seed 1 --tickers AAPL,MSFT,NVDA,TSLA,AMZN,META,GOOG,NFLX --price-min 45.00 --price-max 75.00 --ask-fraction 0.5`.
   - **Writes:**
     - `messages.mem` for `$readmemh`, in the layout `msg_rom` expects.
     - `messages.csv`, one row per message with its decoded fields.
   - The `seq` field equals the message index (mod 65536).
2. **`golden.py`**
   - **Arguments:** `--messages messages.csv --ticker AAPL --limit 55.25`.
   - **Output:** the expected reply for each message (`seq,type,ticker_id,price`).
3. **`capture.py`**
   - **Arguments:** `--port /dev/ttyUSB1 --baud 115200 --out runA.csv`.
   - Reads one board 1 UART dump.
   - Writes the CSV, with the header and summary kept as comments.
4. **`analyze.py`**
   - **Arguments:** `runA.csv runB.csv [runC.csv runD.csv]`.
   - Converts ticks to µs (× 0.005).
   - Excludes timeouts and seq errors, and reports their counts.
   - Prints p50, p99, p99.9, max and max − min per run.
   - Saves overlaid histograms (log-scale y-axis) and a CDF plot as PNG.

## 12. Verification

### Simulation (`sim/`; Vivado xsim or Verilator)

1. **SPI master.** Check against a behavioral SPI slave: frame format, mode 0 timing, bursts, and streaming read data.
2. **W5500 model.** Write a behavioral model with:
   - the common and socket 0 register file;
   - 2 KB TX and RX buffers;
   - command handling (`OPEN`, `SEND`, `SEND_MAC`, `RECV`);
   - `Sn_IR`/`INT_n` behavior;
   - a packet port, so two model instances can be connected through a "wire" with a configurable delay.
3. **Board 1.** Run against a W5500 model whose far side is a scripted responder.
   - Timing: `t1 − t0` matches the injected delay ±1 tick.
   - Error paths: timeouts, stale replies and seq mismatches.
   - Output: UART dump format.
   - Pointers: wraparound past 0xFFFF.
4. **Board 2, run A.** Drive `messages.mem` through a W5500 model and compare every reply to `golden.py` for several switch settings.
   - Assert that the decision is registered a fixed number of cycles after the last price byte is read.
   - Assert that the critical-path command order of §8 is followed.
5. **End-to-end, run A.** Board 1 and board 2 tops, two W5500 models joined by the wire model, with `clk_sys` of each board offset by ~1%. All replies match golden, with no timeouts.
6. **Board 2, run C.** Use an RMII frame generator for market-data frames, ARP requests and junk frames.
   - Replies are byte-exact against a Python reference frame builder, with correct FCS and IPv4 checksum.
   - The ARP reply is correct.
   - Junk frames are ignored.
   - TX starts a fixed number of cycles after RX offset 57.
   - Incoming FCS is not required.

### Hardware bring-up checks

1. W5500 `VERSIONR` reads 0x04 on both boards. Init OK and link LEDs light.
2. With a laptop on board 1's cable at 192.168.10.1, Wireshark shows market-data packets with correct fields, and `nc -ul 5000` receives them. No ARP between timed messages.
3. Run B: 4096 messages, zero timeouts, zero seq errors, buy/no-trade counts matching golden.
4. Run A: same criteria.
5. Run C, extension:
   - Board 1's W5500 resolves the LAN8720 trader via ARP (visible in board 1's warm-up completing).
   - Same criteria as run A.

## 13. Acceptance criteria

- **Runs A and B** (and C, if built): each completes 4096 messages with zero timeouts and zero seq errors, and every reply matches golden.
- **Laptop trader:** produces replies identical to golden for the same configuration.
- **Timing closure:** every design meets timing in Vivado with no unconstrained clock-crossing paths. All crossings use XPM CDC macros.
- **Rebuild:** each bitstream builds from a script with no GUI steps: `build_board1.tcl`, `build_board2.tcl`, `build_board2_eth.tcl`.

## 14. Suggested repository layout

```
rtl/common/     spi_master.sv w5500_ctrl.sv uart_tx.sv sevenseg.sv debounce.sv
rtl/board1/     board1_top.sv feed_replayer.sv timestamp.sv sample_store.sv uart_dump.sv msg_rom.sv
rtl/board2/     board2_top.sv trader_fsm.sv trade_rule.sv
rtl/board2_eth/ board2_eth_top.sv rmii_rx.sv frame_parser.sv rmii_tx.sv crc32.sv arp_responder.sv
constraints/    board1.xdc board2.xdc board2_eth.xdc   (derived from Basys3-Master.xdc)
sim/            tb_spi.sv w5500_model.sv wire_model.sv tb_board1.sv tb_board2.sv tb_e2e.sv tb_board2_eth.sv rmii_gen.sv
host/           trader.cpp Makefile README.md
tools/          gen_messages.py golden.py capture.py analyze.py frame_ref.py
scripts/        build_board1.tcl build_board2.tcl build_board2_eth.tcl
```

`trade_rule.sv` holds the §5 decision logic, shared by `trader_fsm` and the run C trader.

## 15. Out of scope

- The custom GPIO link and SPI bridge from earlier designs
- AWS F2
- Presentation materials
- Project schedule
