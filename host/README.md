# Laptop trader

`laptop_trader.py` answers the FPGA exchange's FIX market data with the stored
buy reply (docs/fix_test_packet.md). It runs on Windows and macOS with Python 3
and nothing else installed. The exchange times the round trip.

The exchange sends to MAC `02:00:00:00:00:01` / `192.168.10.1:5000` and cannot
answer ARP, so the laptop's Ethernet adapter needs that MAC, that IP, and a
static ARP entry for the exchange (`192.168.10.2` → `02:00:00:00:00:02`). The
setup scripts do this and can undo it.

## Windows

PowerShell as Administrator, from the repo folder:

```powershell
Get-NetAdapter                       # find the adapter cabled to the board
powershell -ExecutionPolicy Bypass -File host\setup_windows.ps1 -Adapter "Ethernet 2"
python host\laptop_trader.py
```

Undo: the same setup command with `-Restore`.

## macOS

Terminal, from the repo folder, with the cable connected:

```bash
networksetup -listallhardwareports   # find the device, e.g. en5
sudo bash host/setup_mac.sh en5
python3 host/laptop_trader.py
```

Undo: `sudo bash host/setup_mac.sh en5 --restore`. Run the setup again after
unplugging the adapter or restarting; on macOS also after reprogramming the
board, since the link going down can drop the static ARP entry.

## Running

1. Program the exchange, connect the cable, run the setup script, start the
   trader.
2. Press BTNC on the exchange. LED1 should light and the display shows the
   latency; the trader prints nothing unless `--verbose`.
3. SW15 on the exchange sends continuously; flip SW[1:0] for min/max.

Options: `--busy` spins on the socket (lower, steadier latency, one core at
100%); `--verbose` prints each message with the laptop's own receive-to-send
time.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| LED2 (timeout), trader prints nothing with `--verbose` | Market data not reaching Python: MAC not changed (check the setup output), firewall, or wrong adapter |
| LED2, trader prints `buy` | Reply not reaching the exchange: static ARP entry missing (run setup again), or the reply goes out another adapter |
| LED3 lit | Normal: the OS sends its own frames (IPv6, mDNS, LLMNR); the exchange counts and ignores them |

# Two-trader exchange: `mm_trader.py` / `mm_trader.cpp`

For the `mm_top` build (docs/mm_protocol.md): the laptop is cabled to the
exchange's JB port and market-makes the ETF with the same strategy as the
FPGA trader on JC. Network setup is the same as above (setup script, MAC
02:00:00:00:00:01, IP 192.168.10.1, static ARP entry).

```
python host/mm_trader.py --half-spread 1 --verbose      # Windows / macOS
make -C host && ./host/mm_trader --half-spread 1 --cpu 2 --busy-poll   # Linux
```

Set the FPGA trader's half-spread wider (SW[5:2] = 2, i.e. $2) so the
laptop's tighter quote is the one resting when AAPL moves. Then on the
exchange: BTNU (clear), BTNC per AAPL print or BTND to play the script,
BTNR to dump the event log; `python tools/capture.py --port COMn --run mmA`
followed by `python tools/race.py mmA` prints who got there first.

With `--verbose` the laptop prints each message; after a print you should
see its own cancel come back as `9 cancel of ... rejected: TOO LATE, already
filled` and an `8 FILLED` report for the quote the FPGA lifted.
