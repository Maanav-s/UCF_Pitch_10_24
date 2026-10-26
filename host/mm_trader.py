#!/usr/bin/env python3
"""Laptop market maker for the two-trader exchange (docs/mm_protocol.md).

Runs the same strategy as the FPGA trader (class MarketMaker in
tools/mm_model.py) on the ETF: on every AAPL print, pick off a stale resting
quote if there is one, cancel its own quotes, and requote around the new fair
value. The exchange timestamps everything; the point of the demo is that the
FPGA does all of this before this program has even received the print.

Network setup is as for laptop_trader.py: run host/setup_windows.ps1 or
host/setup_mac.sh first (MAC 02:00:00:00:00:01, IP 192.168.10.1, static ARP
entry for the exchange).

Usage:
  python host/mm_trader.py [--half-spread 1] [--no-quote] [--port 5000]
                           [--busy] [--verbose]

  --half-spread  dollars each side of fair (default 1; the FPGA uses 2, so
                 this trader's quotes are the ones resting in the book)
  --no-quote     only pick off, never quote
  --busy         spin on a non-blocking socket (lower latency, one core busy)
  --verbose      print every message in and out

Ctrl+C prints the counts and exits.
"""
import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
import mm_fix as fx          # noqa: E402
from mm_model import MarketMaker  # noqa: E402


def describe(payload):
    d = fx.parse(payload)
    if d is None:
        return f"{len(payload)} bytes, not ours"
    t = d[35]
    if t == "X":
        what = {"0": "bid", "1": "ask", "2": "trade"}[d[269]]
        return f"X  {d[55].strip():4s} {what} {d[270]} x{int(d[271])}"
    if t == "D":
        return f"D  {'buy ' if d[54] == '1' else 'sell'} {d[55].strip()} @ {d[44]}  id {d[11]}"
    if t == "F":
        return f"F  cancel {d[41]} ({'bid' if d[54] == '1' else 'ask'})  id {d[11]}"
    if t == "8":
        st = {"0": "new", "F": "FILLED", "4": "canceled", "8": "rejected"}.get(d[150], d[150])
        return f"8  {st:8s} {'buy ' if d[54] == '1' else 'sell'} @ {d[44]}  id {d[11]} ord {d[37]}"
    if t == "9":
        why = {"0": "TOO LATE, already filled", "1": "unknown order"}.get(d[102], d[102])
        return f"9  cancel of {d[41]} rejected: {why}"
    return t


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--half-spread", type=float, default=1.0, help="dollars (default 1)")
    ap.add_argument("--no-quote", action="store_true", help="pick off only, no quotes")
    ap.add_argument("--port", type=int, default=fx.PORT)
    ap.add_argument("--busy", action="store_true", help="busy-poll the socket")
    ap.add_argument("--verbose", action="store_true", help="print each message")
    a = ap.parse_args()

    mm = MarketMaker(int(round(a.half_spread * 100)), quoting=not a.no_quote)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", a.port))
    if a.busy:
        sock.setblocking(False)
    else:
        sock.settimeout(0.5)   # so Ctrl+C works on Windows

    print(f"market maker on UDP {a.port}: half-spread ${a.half_spread:.2f}, "
          f"{'no quotes' if a.no_quote else 'quoting'}, {'busy-poll' if a.busy else 'blocking'}")
    print(f"  fair = {fx.FAIR_NUM}/{fx.FAIR_DEN} * AAPL + ${fx.FAIR_OFF_CENTS / 100:.2f}; Ctrl+C to stop")

    n_in = n_out = n_other = 0
    too_late = 0
    recv, send, now = sock.recvfrom, sock.sendto, time.perf_counter_ns
    try:
        while True:
            try:
                data, addr = recv(2048)
            except (BlockingIOError, socket.timeout):
                continue
            except ConnectionResetError:
                continue
            t0 = now()
            out = mm.on_payload(data)
            for p in out:
                send(p, addr)
            t1 = now()
            d = fx.parse(data)
            if d is None:
                n_other += 1
            else:
                n_in += 1
                if d[35] == "9" and d[102] == "0":
                    too_late += 1
            n_out += len(out)
            if a.verbose:
                print(f"<- {describe(data)}")
                for p in out:
                    print(f"  -> {describe(p)}")
                if out and mm.fair is not None:
                    print(f"     receive->last send {(t1 - t0) / 1000:.1f} us; fair ${mm.fair / 100:.2f}")
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()
        print(f"\nin {n_in} (other {n_other}), out {n_out}, pickoff buys {mm.n_buys}, "
              f"sells {mm.n_sells}, own fills {mm.n_fills}, cancels too late {too_late}")


if __name__ == "__main__":
    main()
