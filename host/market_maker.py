#!/usr/bin/env python3
"""PC market maker for the latency-arbitrage exchange.

Quotes 2-wide around the fair the exchange broadcasts (bid = fair-1 tick,
ask = fair+1 tick). On a new fair, cancels both quotes and posts again.
The FPGA sniper only goes long: it buys a stale ask when the fair jumps
up by more than the spread, then sells the new bid.

The laptop must still use host/setup_mac.sh or setup_windows.ps1 so it owns
MAC 02:00:00:00:00:01 / 192.168.10.1 and has a static ARP entry for the
exchange at 192.168.10.2.

Usage:
  python3 host/market_maker.py [--port 5000] [--busy]
"""
import argparse
import os
import socket
import struct
import sys
import time

T_ORDER, T_FILL, T_BOOK, T_FAIR, T_CANCEL, T_ACK = 1, 2, 3, 5, 6, 7
SRC_P = 2
SIDE_B, SIDE_S = 0, 1
TIF_REST, TIF_IOC = 0, 1
ACK_CANCEL_OK, ACK_CANCEL_TOO_LATE = 3, 4
HALF = 1
SIZE = 1


def hdr(typ, seq):
    return struct.pack("!BBH", typ, SRC_P, seq & 0xFFFF)


def u32(b, o):
    return struct.unpack("!I", b[o:o + 4])[0]


def u16(b, o):
    return struct.unpack("!H", b[o:o + 2])[0]


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=5000)
    ap.add_argument("--busy", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", a.port))
    if a.busy:
        sock.setblocking(False)
    else:
        sock.settimeout(0.5)

    exch = ("192.168.10.2", a.port)
    seq = 0
    next_oid = 1  # odd
    bid_oid = ask_oid = None
    pending = set()
    need_quote = False
    fv = None
    pos = 0
    cash = 0
    n_fair = n_fill = n_late = 0

    def send(payload):
        sock.sendto(payload, exch)

    def order(side, oid, px):
        nonlocal seq
        seq += 1
        send(hdr(T_ORDER, seq) + struct.pack("!IBBIH", oid, side, TIF_REST, px, SIZE))

    def cancel(oid):
        nonlocal seq
        seq += 1
        send(hdr(T_CANCEL, seq) + struct.pack("!I", oid))
        pending.add(oid)

    def quote():
        nonlocal next_oid, bid_oid, ask_oid, need_quote
        if fv is None:
            return
        bid_oid = next_oid
        next_oid += 2
        ask_oid = next_oid
        next_oid += 2
        order(SIDE_B, bid_oid, fv - HALF)
        order(SIDE_S, ask_oid, fv + HALF)
        need_quote = False
        if a.verbose:
            print(f"quote bid {fv - HALF} ask {fv + HALF} fv {fv}")

    print(f"market maker on UDP {a.port} ({'busy-poll' if a.busy else 'blocking'})")
    print("  Ctrl+C to stop")

    try:
        while True:
            try:
                data, addr = sock.recvfrom(2048)
            except (BlockingIOError, socket.timeout):
                continue
            except ConnectionResetError:
                continue
            if len(data) < 4:
                continue
            typ, src, pseq = struct.unpack("!BBH", data[:4])
            if typ == T_FAIR and len(data) >= 10:
                fv = u32(data, 6)
                n_fair += 1
                if a.verbose:
                    print(f"fair {fv} ({fv / 100:.2f})")
                if bid_oid is not None:
                    cancel(bid_oid)
                if ask_oid is not None:
                    cancel(ask_oid)
                bid_oid = ask_oid = None
                need_quote = True
                if not pending:
                    quote()
            elif typ == T_ACK and len(data) >= 9:
                oid = u32(data, 4)
                st = data[8]
                pending.discard(oid)
                if st == ACK_CANCEL_TOO_LATE:
                    n_late += 1
                    if a.verbose:
                        print(f"cancel {oid} too late")
                if need_quote and not pending:
                    quote()
            elif typ == T_FILL and len(data) >= 14:
                px = u32(data, 8)
                sz = u16(data, 12)
                n_fill += 1
                # we are the resting side of a snipe, or of a flatten
                # FILL carries the aggressor or rest oid; cash is marked on E
                if a.verbose:
                    print(f"fill px={px} sz={sz}")
            elif typ == T_BOOK and a.verbose and len(data) >= 16:
                print(f"book bid {u32(data,4)}/{u16(data,8)} ask {u32(data,10)}/{u16(data,14)}")
    except KeyboardInterrupt:
        print(f"\nfairs={n_fair} fills={n_fill} cancel_too_late={n_late}")


if __name__ == "__main__":
    main()
