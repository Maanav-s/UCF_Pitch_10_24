#!/usr/bin/env python3
"""Testbench vectors for the two-trader exchange, from the Python models.

Writes into sim/mm/ (read with $readmemh):

  gen_fields.mem / gen_frames.mem   tb_mm_frames: field values and the frame
                                    each must produce (and parse back to)
  ex_actions.mem / ex_frames.mem    tb_mm_exchange: frames to inject on each
                                    port and the frames the exchange must send
  tr_actions.mem / tr_frames.mem    tb_mm_trader: frames the FPGA trader
                                    receives and the orders it must send
  e2e_actions.mem / e2e_frames.mem  tb_mm_e2e: the laptop's side of the demo

Frames are stored in slots of FRAME_STRIDE bytes, one byte per line, FCS
included; the slot's length is in the matching *_len.mem. Actions are 32-bit
words {kind[31:24], port[23:16], index[15:0]}:
  kind 0  AAPL print: press "next step" (index = step)
  kind 1  inject frame index on port (0 = L, 1 = F)
  kind 2  expect frame index as the next frame sent on port (2 = both)
  kind 3  quiet: expect no frame on either port for a while
  kind 0xFF  end
Field records for tb_mm_frames are 14 words: type code (0 X, 1 D, 2 F, 3 ER,
4 CR), seq, clordid, ordid, orig, qty, size (BCD), price (BCD cents), sym
(ASCII), entry, exectype, ordstatus, side, reason (ASCII).

Usage: python tools/mm_vectors.py [--out sim/mm]
"""
import argparse
import os
import random
import zlib

import mm_fix as fx
import mm_model as mm

FRAME_STRIDE = 160
MT = {"X": 0, "D": 1, "F": 2, "8": 3, "9": 4}
K_PRINT, K_RX, K_EXPECT, K_QUIET, K_END = 0, 1, 2, 3, 0xFF


def bcd(n, digits):
    return int(f"{n:0{digits}d}", 16)


def write_frames(path_base, frames):
    with open(path_base + "_frames.mem", "w", newline="\n") as f:
        for fr in frames:
            assert len(fr) <= FRAME_STRIDE, len(fr)
            fr = fr + b"\x00" * (FRAME_STRIDE - len(fr))
            f.write("".join(f"{b:02x}\n" for b in fr))
    with open(path_base + "_len.mem", "w", newline="\n") as f:
        f.write("".join(f"{len(fr):02x}\n" for fr in frames))


def write_words(path, words):
    with open(path, "w", newline="\n") as f:
        f.write("".join(f"{w & 0xFFFFFFFF:08x}\n" for w in words))


def action(kind, port=0, idx=0):
    return (kind << 24) | (port << 16) | idx


class Scenario:
    """Collects frames and actions; frames are de-duplicated by content."""

    def __init__(self):
        self.frames = []
        self.index = {}
        self.actions = []

    def frame_idx(self, fr):
        if fr not in self.index:
            self.index[fr] = len(self.frames)
            self.frames.append(fr)
        return self.index[fr]

    def print_step(self, step):
        self.actions.append(action(K_PRINT, 0, step))

    def rx(self, port, fr):
        self.actions.append(action(K_RX, port, self.frame_idx(fr)))

    def expect(self, dst, fr):
        self.actions.append(action(K_EXPECT, dst, self.frame_idx(fr)))

    def quiet(self):
        self.actions.append(action(K_QUIET))

    def write(self, base):
        write_frames(base, self.frames)
        write_words(base + "_actions.mem", self.actions + [action(K_END)])


# ---------------------------------------------------------------- tb_mm_frames

def gen_vectors(out, n=24):
    rnd = random.Random(7)
    recs, frames = [], []
    for i in range(n):
        t = "XDF89"[i % 5]
        seq = rnd.randrange(100000)
        ids = [rnd.randrange(100000) for _ in range(3)]
        cents = rnd.choice([rnd.randrange(1000000), 5100, 8000, 0, 999999])
        qty = rnd.randrange(100000)
        sym = rnd.choice([fx.SYM_AAPL, fx.SYM_ETF, "MSFT"])
        side = rnd.choice("12")
        entry, exectype, ordstatus, reason = rnd.choice("012"), rnd.choice("0F48"), rnd.choice("0248"), rnd.choice("01")
        if t == "X":
            p, _ = fx.market_data(seq, sym, entry, cents, qty)
        elif t == "D":
            p, _ = fx.new_order(seq, ids[0], sym, side, qty, cents)
        elif t == "F":
            p, _ = fx.cancel(seq, ids[0], ids[1], sym, side)
        elif t == "8":
            p, _ = fx.exec_report(seq, ids[2], ids[0], exectype, ordstatus, sym, side, cents, qty)
        else:
            p, _ = fx.cancel_reject(seq, ids[2], ids[0], ids[1], ordstatus, reason)
        d = fx.parse(p)
        rec = [MT[t], bcd(seq, 5), bcd(ids[0], 5), bcd(ids[2], 5), bcd(ids[1], 5), bcd(qty, 5),
               bcd(qty, 5), bcd(cents, 6), int.from_bytes(sym.encode(), "big"),
               ord(entry), ord(exectype), ord(ordstatus), ord(side), ord(reason)]
        # Fields a type does not carry are zero in the parser's output; the
        # testbench only compares the ones the type has, by code.
        recs += rec
        frames.append(fx.frame(p, fx.TYPES[t][1]))
    write_words(os.path.join(out, "gen_fields.mem"), recs)
    write_frames(os.path.join(out, "gen"), frames)
    return n


# ---------------------------------------------------------------- tb_mm_exchange

def corrupt_fcs(fr):
    return fr[:-1] + bytes([fr[-1] ^ 0x5A])


ARP_REQUEST = bytes.fromhex(
    "ffffffffffff" "020000000001" "0806" "0001" "0800" "06" "04" "0001"
    "020000000001" "c0a80a01" "000000000000" "c0a80a02") + b"\x00" * 18


def with_fcs(eth):
    import struct
    return eth + struct.pack("<I", zlib.crc32(eth))


def exchange_scenario(out):
    """Hand-written order flow on both ports, expectations from the model.
    Laptop frames carry a UDP checksum and a foreign source MAC, as an OS
    stack sends them; the exchange must not care."""
    sc = Scenario()
    ex = mm.Exchange()
    L, F = mm.L, mm.F
    seqs = {L: 0, F: 0}

    def tr_frame(port, payload):
        fr = fx.frame(payload, "tr2ex", udp_csum=(port == L), fcs=False)
        if port == L:
            fr = fr[:6] + bytes.fromhex("a4bb6d112233") + fr[12:]
            # IPv4 ID and TTL as an OS might set them; fix the IP checksum.
            ip = bytearray(fr[14:34])
            ip[4:6] = b"\x12\x34"
            ip[8] = 128
            ip[10:12] = b"\x00\x00"
            ip[10:12] = fx.csum16(bytes(ip)).to_bytes(2, "big")
            fr = fr[:14] + bytes(ip) + fr[34:]
        return with_fcs(fr)

    def send(port, payload, expect=True):
        sc.rx(port, tr_frame(port, payload))
        if expect:
            for dst, p in ex.on_payload(port, payload):
                sc.expect(dst, fx.frame(p, "ex2tr"))

    def order(port, side, cents, clordid, sym=fx.SYM_ETF, qty=fx.QTY):
        seqs[port] += 1
        send(port, fx.new_order(seqs[port], clordid, sym, side, qty, cents)[0])

    def cancel(port, side, clordid, orig, sym=fx.SYM_ETF):
        seqs[port] += 1
        send(port, fx.cancel(seqs[port], clordid, orig, sym, side)[0])

    def print_step(step):
        sc.print_step(step)
        for dst, p in ex.aapl(fx.SCRIPT_DOLLARS[step] * 100):
            sc.expect(dst, fx.frame(p, "ex2tr"))

    B, S = mm.BUY, mm.SELL
    # Step 0: AAPL 100, fair 50. FPGA quotes 48@52, laptop 49@51 replaces.
    print_step(0)
    order(F, B, 4800, 1)
    order(F, S, 5200, 2)
    order(L, B, 4900, 1)
    order(L, S, 5100, 2)
    # Noise: an ARP request and a frame with a bad FCS are ignored.
    sc.rx(L, with_fcs(ARP_REQUEST))
    sc.rx(F, corrupt_fcs(tr_frame(F, fx.new_order(99, 99, fx.SYM_ETF, B, 100, 5100)[0])))
    sc.quiet()
    # A non-ETF order and an order with a bad side are rejected.
    order(L, B, 10000, 3, sym="MSFT")
    seqs[L] += 1
    send(L, fx.new_order(seqs[L], 4, fx.SYM_ETF, "7", 100, 5000)[0])
    # Step 1: AAPL 200, fair 80. FPGA lifts 51, requotes 78@82; the laptop's
    # cancels are too late / unknown, its 79@81 replaces.
    print_step(1)
    order(F, B, 5100, 3)
    order(F, B, 7800, 4)
    order(F, S, 8200, 5)
    cancel(L, B, 5, 1)
    cancel(L, S, 6, 2)
    order(L, B, 7900, 7)
    order(L, S, 8100, 8)
    # Self-trade (laptop buys its own ask) and a worse price are rejected.
    order(L, B, 8100, 9)
    order(F, B, 7000, 6)
    # A cancel for a non-ETF symbol is unknown; a real cancel empties the ask.
    cancel(L, S, 10, 8, sym="MSFT")
    cancel(L, S, 11, 8)
    # Step 2: AAPL 150, fair 65. FPGA sells to the 79 bid, requotes 63@67.
    print_step(2)
    order(F, S, 7900, 7)
    order(F, B, 6300, 8)
    order(F, S, 6700, 9)
    sc.quiet()
    sc.write(os.path.join(out, "ex"))
    return len(sc.actions), ex.fills


# ---------------------------------------------------------------- tb_mm_trader, tb_mm_e2e

def trader_scenario(out):
    log, ex = mm.demo(verbose=False)
    sc = Scenario()
    for kind, port, p in log:
        if kind == "rx" and port == mm.F:
            sc.rx(0, fx.frame(p, "ex2tr"))
        elif kind == "tx" and port == mm.F:
            sc.expect(0, fx.frame(p, "tr2ex"))
    sc.quiet()
    sc.write(os.path.join(out, "tr"))
    return len(sc.actions)


def e2e_scenario(out):
    """The whole demo: prints, the laptop's messages injected on port L after
    the FPGA's burst, and every frame the exchange sends on either port."""
    log, ex = mm.demo(verbose=False)
    sc = Scenario()
    step = 0
    for kind, port, p in log:
        if kind == "print":
            sc.print_step(step)
            step += 1
        elif kind == "rx":
            sc.expect(port, fx.frame(p, "ex2tr"))
        elif kind == "tx" and port == mm.L:
            sc.rx(mm.L, fx.frame(p, "tr2ex", udp_csum=True))
        # tx by the FPGA: the real trader produces it
    sc.quiet()
    sc.write(os.path.join(out, "e2e"))
    return len(sc.actions), ex.fills


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  os.pardir, "sim", "mm"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    assert fx.check()
    n = gen_vectors(a.out)
    print(f"gen: {n} vectors")
    n, fills = exchange_scenario(a.out)
    print(f"ex:  {n} actions, fills {fills}")
    n = trader_scenario(a.out)
    print(f"tr:  {n} actions")
    n, fills = e2e_scenario(a.out)
    print(f"e2e: {n} actions, fills {fills}")
    print(f"wrote {os.path.normpath(a.out)}")


if __name__ == "__main__":
    main()
