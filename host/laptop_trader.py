#!/usr/bin/env python3
"""Laptop trader for the FPGA exchange (Windows and macOS).

Listens on UDP port 5000. For each datagram that is the standard FIX market
data (AAPL ask $100.00, docs/fix_test_packet.md) it sends the standard buy
reply back to the sender. The exchange times the round trip to the end of
this reply.

Both messages come from tools/fix_test_packet.py, so they always match what
the exchange sends and expects. The reply is built once at start-up; the loop
only receives, compares and sends.

Run the setup script for your OS first (host/setup_windows.ps1 or
host/setup_mac.sh): the exchange sends to MAC 02:00:00:00:00:01 and does not
answer ARP, so the laptop needs that MAC, IP 192.168.10.1 and a static ARP
entry for the exchange.

Usage:
  python laptop_trader.py [--port 5000] [--busy] [--verbose]

  --busy     spin on a non-blocking socket instead of blocking in recvfrom.
             Lower and steadier latency, at the cost of one CPU core at 100%.
  --verbose  print one line per message, with the time from receive to send.
             Printing is done after the reply is sent, so it is off the timed
             path, but it slows the next message slightly.

Ctrl+C prints the counts and exits.
"""
import argparse
import os
import socket
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tools"))
from fix_test_packet import buy_order, market_data  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--busy", action="store_true", help="busy-poll the socket")
    ap.add_argument("--verbose", action="store_true", help="print each message")
    a = ap.parse_args()

    md = market_data()
    reply = buy_order()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", a.port))
    if a.busy:
        sock.setblocking(False)
    else:
        # A timeout rather than a plain blocking socket, so Ctrl+C works on
        # Windows (it is not delivered while recvfrom is blocked there).
        sock.settimeout(0.5)

    print(f"listening on UDP {a.port} ({'busy-poll' if a.busy else 'blocking'})")
    print(f"  expecting {len(md)}-byte market data, replying with {len(reply)}-byte buy")
    print("  Ctrl+C to stop")

    buys = 0
    other = 0
    recv = sock.recvfrom
    send = sock.sendto
    now = time.perf_counter_ns
    try:
        while True:
            try:
                data, addr = recv(2048)
            except (BlockingIOError, socket.timeout):
                continue
            except ConnectionResetError:
                # Windows reports an ICMP port-unreachable from an earlier
                # send as an error on the next receive. Ignore it.
                continue
            t0 = now()
            if data == md:
                send(reply, addr)
                t1 = now()
                buys += 1
                if a.verbose:
                    print(f"buy #{buys} to {addr[0]}:{addr[1]}  "
                          f"receive->send {(t1 - t0) / 1000:.1f} us")
            else:
                other += 1
                if a.verbose:
                    print(f"ignored {len(data)} bytes from {addr[0]}:{addr[1]}: {data[:40]!r}")
    except KeyboardInterrupt:
        pass
    finally:
        sock.close()
        print(f"\nbuys {buys}, ignored {other}")


if __name__ == "__main__":
    main()
