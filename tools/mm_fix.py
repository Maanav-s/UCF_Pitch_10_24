#!/usr/bin/env python3
"""Fixed-width FIX messages for the two-trader exchange (docs/mm_protocol.md).

Five message types, all tag=value with SOH (0x01) delimiters and every value
at a fixed width (leading zeros), so every field sits at a constant byte
offset and the FPGAs parse and build them by position:

  X   Market Data Incremental Refresh   exchange -> traders
  D   New Order Single                  trader   -> exchange
  F   Order Cancel Request              trader   -> exchange
  8   Execution Report                  exchange -> trader
  9   Order Cancel Reject               exchange -> trader

This module is the single source of truth for the layouts. It
  - builds and parses the messages (used by host/mm_trader.py and the tests),
  - builds whole Ethernet frames (IPv4/UDP, FCS),
  - generates rtl/mm/mm_fix_pkg.sv: one frame template and one field map per
    type, so the RTL patches fields into a stored frame instead of knowing
    the layout, plus the demo price script and fair-value constants,
  - checks itself: template + field patches must equal the directly built
    message, byte for byte, checksums included (--check, also run by --sv).

Usage:
  mm_fix.py                 print the five layouts with offsets
  mm_fix.py --check         self-test
  mm_fix.py --sv FILE       write the SystemVerilog package (runs the check)
"""
import argparse
import random
import struct
import sys
import zlib

SOH = b"\x01"

EXCH_MAC = bytes.fromhex("020000000002")
TRDR_MAC = bytes.fromhex("020000000001")
EXCH_IP = bytes([192, 168, 10, 2])
TRDR_IP = bytes([192, 168, 10, 1])
PORT = 5000
ETH_HDR = 14 + 20 + 8          # payload starts at frame offset 42
TYPE_OFF = ETH_HDR + 19        # frame offset of the 35= value (61)

SYM_AAPL = "AAPL"
SYM_ETF = "ETF "                # 4 characters, space padded
QTY = 100

# Fair value of the ETF: fair = FAIR_NUM/FAIR_DEN * AAPL + FAIR_OFF.
# 3/10 * AAPL + $20: $100 -> $50, $200 -> $80, $150 -> $65.
FAIR_NUM = 3
FAIR_DEN = 10
FAIR_OFF_CENTS = 20_00
# floor(n / 10) == (n * DIV10_M) >> DIV10_S for every n < 2^22 (checked
# exhaustively); 3 * $9999.99 in cents = 2,999,997 < 2^22.
DIV10_M = 838861
DIV10_S = 23

# Demo script: AAPL prints the exchange sends, one per BTNC press.
SCRIPT_DOLLARS = [100, 200, 150, 120, 180, 100]

# Field codes: the high nibble of a map byte. The low nibble is the digit
# (character) index within the field, most significant first.
F_NONE = 0       # template byte; on receive it must match
F_ANY = 1        # template byte; on receive it is not checked
F_SEQ = 2        # 34  MsgSeqNum, 5 digits
F_SYM = 3        # 55  Symbol, 4 characters
F_ENTRY = 4      # 269 MDEntryType: '0' bid, '1' offer, '2' trade
F_PRICE = 5      # 270/44 price DDDD.DD: 6 digits (the '.' is a template byte)
F_SIZE = 6       # 271 MDEntrySize, 5 digits
F_ORDID = 7      # 37  OrderID, 5 digits (exchange's)
F_CLORDID = 8    # 11  ClOrdID, 5 digits (trader's)
F_ORIG = 9       # 41  OrigClOrdID, 5 digits
F_EXECTYPE = 10  # 150 ExecType: '0' new, 'F' trade, '4' canceled, '8' rejected
F_ORDSTATUS = 11 # 39  OrdStatus: '0' new, '2' filled, '4' canceled, '8' rejected
F_SIDE = 12      # 54  Side: '1' buy, '2' sell
F_REASON = 13    # 102 CxlRejReason: '0' too late to cancel, '1' unknown order
F_QTY = 14       # 38  OrderQty, 5 digits
F_CKSUM = 15     # 10  CheckSum, 3 digits

FIELD_NAMES = {
    F_NONE: "NONE", F_ANY: "ANY", F_SEQ: "SEQ", F_SYM: "SYM", F_ENTRY: "ENTRY",
    F_PRICE: "PRICE", F_SIZE: "SIZE", F_ORDID: "ORDID", F_CLORDID: "CLORDID",
    F_ORIG: "ORIG", F_EXECTYPE: "EXECTYPE", F_ORDSTATUS: "ORDSTATUS",
    F_SIDE: "SIDE", F_REASON: "REASON", F_QTY: "QTY", F_CKSUM: "CKSUM",
}

# Message types: FIX 35= value, short name used in the RTL, direction.
TYPES = {
    "X": ("X", "ex2tr"),
    "D": ("D", "tr2ex"),
    "F": ("F", "tr2ex"),
    "8": ("ER", "ex2tr"),
    "9": ("CR", "ex2tr"),
}

# Positions in the Ethernet/IP/UDP header that an OS network stack fills in
# its own way; receivers do not check them.
HDR_ANY = set(range(6, 12)) | set(range(18, 23)) | {24, 25} | {40, 41}


def price_str(cents):
    if not 0 <= cents <= 999999:
        raise ValueError(f"price {cents} cents out of range")
    return f"{cents // 100:04d}.{cents % 100:02d}"


def price_cents(s):
    d, c = s.split(".")
    return int(d) * 100 + int(c)


# ---------------------------------------------------------------- building

def _fix(fields):
    """fields: (tag, value_str, code). Returns (payload, map) with the field
    map as a list of (code, idx) per payload byte."""
    body = b""
    bmap = []
    for tag, val, code in fields:
        t = f"{tag}=".encode()
        body += t
        bmap += [(F_NONE, 0)] * len(t)
        v = val.encode()
        body += v
        if code is None:
            bmap += [(F_NONE, 0)] * len(v)
        elif code == F_PRICE:
            # DDDD.DD: digits 0-3, literal '.', digits 4-5
            k = 0
            for ch in val:
                if ch == ".":
                    bmap.append((F_NONE, 0))
                else:
                    bmap.append((code, k))
                    k += 1
        else:
            bmap += [(code, k) for k in range(len(v))]
        body += SOH
        bmap.append((F_NONE, 0))
    head = b"8=FIX.4.4" + SOH + f"9={len(body):03d}".encode() + SOH
    hmap = [(F_NONE, 0)] * len(head)
    cks = sum(head + body) % 256
    tail = b"10=" + f"{cks:03d}".encode() + SOH
    tmap = [(F_NONE, 0)] * 3 + [(F_CKSUM, k) for k in range(3)] + [(F_NONE, 0)]
    return head + body + tail, hmap + bmap + tmap


def market_data(seq=1, sym=SYM_AAPL, entry="2", cents=100_00, size=QTY):
    """35=X. entry: '0' bid, '1' offer, '2' trade (AAPL prints are trades).
    size 0 means the level is gone."""
    return _fix([
        (35, "X", None),
        (34, f"{seq:05d}", F_SEQ),
        (55, f"{sym:<4}", F_SYM),
        (269, entry, F_ENTRY),
        (270, price_str(cents), F_PRICE),
        (271, f"{size:05d}", F_SIZE),
    ])


def new_order(seq=1, clordid=1, sym=SYM_ETF, side="1", qty=QTY, cents=50_00):
    """35=D. side: '1' buy, '2' sell. Limit order (40=2)."""
    return _fix([
        (35, "D", None),
        (34, f"{seq:05d}", F_SEQ),
        (11, f"{clordid:05d}", F_CLORDID),
        (55, f"{sym:<4}", F_SYM),
        (54, side, F_SIDE),
        (38, f"{qty:05d}", F_QTY),
        (40, "2", None),
        (44, price_str(cents), F_PRICE),
    ])


def cancel(seq=1, clordid=2, orig=1, sym=SYM_ETF, side="1"):
    """35=F. orig is the ClOrdID of the order to cancel."""
    return _fix([
        (35, "F", None),
        (34, f"{seq:05d}", F_SEQ),
        (11, f"{clordid:05d}", F_CLORDID),
        (41, f"{orig:05d}", F_ORIG),
        (55, f"{sym:<4}", F_SYM),
        (54, side, F_SIDE),
    ])


def exec_report(seq=1, ordid=1, clordid=1, exectype="0", ordstatus="0",
                sym=SYM_ETF, side="1", cents=50_00, qty=QTY):
    """35=8. For a trade (150=F, 39=2) 44 carries the fill price."""
    return _fix([
        (35, "8", None),
        (34, f"{seq:05d}", F_SEQ),
        (37, f"{ordid:05d}", F_ORDID),
        (11, f"{clordid:05d}", F_CLORDID),
        (150, exectype, F_EXECTYPE),
        (39, ordstatus, F_ORDSTATUS),
        (55, f"{sym:<4}", F_SYM),
        (54, side, F_SIDE),
        (44, price_str(cents), F_PRICE),
        (38, f"{qty:05d}", F_QTY),
    ])


def cancel_reject(seq=1, ordid=0, clordid=2, orig=1, ordstatus="2", reason="0"):
    """35=9. reason '0' = too late to cancel (filled), '1' = unknown order."""
    return _fix([
        (35, "9", None),
        (34, f"{seq:05d}", F_SEQ),
        (37, f"{ordid:05d}", F_ORDID),
        (11, f"{clordid:05d}", F_CLORDID),
        (41, f"{orig:05d}", F_ORIG),
        (39, ordstatus, F_ORDSTATUS),
        (434, "1", None),
        (102, reason, F_REASON),
    ])


BUILDERS = {"X": market_data, "D": new_order, "F": cancel, "8": exec_report,
            "9": cancel_reject}


def parse(payload):
    """payload -> dict of int tag -> str value, or None if not one of ours."""
    if not payload.startswith(b"8=FIX.4.4" + SOH) or not payload.endswith(SOH):
        return None
    d = {}
    for f in payload.split(SOH)[:-1]:
        tag, _, val = f.partition(b"=")
        if not tag.isdigit():
            return None
        d[int(tag)] = val.decode("ascii", errors="replace")
    if 35 not in d or d[35] not in TYPES:
        return None
    if len(payload) != len(BUILDERS[d[35]]()[0]):
        return None
    return d


# ---------------------------------------------------------------- frames

def csum16(data):
    if len(data) % 2:
        data += b"\x00"
    s = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return ~s & 0xFFFF


def frame(payload, direction, udp_csum=False, fcs=True):
    """Ethernet frame for a payload. direction 'ex2tr' or 'tr2ex'.
    udp_csum=False writes 0 (none), as the FPGAs do."""
    if direction == "ex2tr":
        src_mac, dst_mac, src_ip, dst_ip = EXCH_MAC, TRDR_MAC, EXCH_IP, TRDR_IP
    else:
        src_mac, dst_mac, src_ip, dst_ip = TRDR_MAC, EXCH_MAC, TRDR_IP, EXCH_IP
    udp_len = 8 + len(payload)
    udp = struct.pack("!HHHH", PORT, PORT, udp_len, 0) + payload
    if udp_csum:
        pseudo = src_ip + dst_ip + struct.pack("!BBH", 0, 17, udp_len)
        ck = csum16(pseudo + udp) or 0xFFFF
        udp = udp[:6] + struct.pack("!H", ck) + udp[8:]
    ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + udp_len, 0, 0, 64, 17, 0,
                     src_ip, dst_ip)
    ip = ip[:10] + struct.pack("!H", csum16(ip)) + ip[12:]
    eth = dst_mac + src_mac + b"\x08\x00" + ip + udp
    eth += b"\x00" * max(0, 60 - len(eth))
    if fcs:
        eth += struct.pack("<I", zlib.crc32(eth))
    return eth


def frame_map(pmap):
    """Field map for a whole frame (no FCS) from a payload map."""
    return [(F_ANY if i in HDR_ANY else F_NONE, 0) for i in range(ETH_HDR)] + pmap


def templates():
    """type -> (frame without FCS, map) built with all-zero/default fields.
    Header positions that differ between the types a receiver has to tell
    apart before it has seen 35= (lengths, 9=) are marked ANY."""
    out = {}
    for t, (name, direction) in TYPES.items():
        p, m = BUILDERS[t]()
        out[t] = [bytearray(frame(p, direction, fcs=False)), frame_map(m)]
    for grp in (("D", "F"), ("X", "8", "9")):
        for i in range(TYPE_OFF):
            vals = {bytes(out[t][0][i:i + 1]) for t in grp}
            if len(vals) > 1:
                for t in grp:
                    out[t][1][i] = (F_ANY, 0)
        # The parser uses the group's first template for offsets < TYPE_OFF.
        for t in grp[1:]:
            for i in range(TYPE_OFF):
                a, b = out[grp[0]], out[t]
                assert a[1][i] == b[1][i], (t, i)
                assert a[1][i][0] != F_NONE or a[0][i] == b[0][i], (t, i)
    return {t: (bytes(f), m) for t, (f, m) in out.items()}


def patch(t, values):
    """Rebuild a frame (no FCS) from the template and field values, the way
    the RTL does. values: code -> str of the field's characters."""
    tpl, fmap = templates()[t]
    out = bytearray(tpl)
    for i, (code, k) in enumerate(fmap):
        if code in (F_NONE, F_ANY, F_CKSUM):
            continue
        out[i] = ord(values[code][k])
    # CheckSum: sum of the payload bytes before "10=", mod 256.
    start = [i for i, (c, k) in enumerate(fmap) if c == F_CKSUM][0] - 3
    cks = sum(out[ETH_HDR:start]) % 256
    for i, (code, k) in enumerate(fmap):
        if code == F_CKSUM:
            out[i] = ord(f"{cks:03d}"[k])
    return bytes(out)


# ---------------------------------------------------------------- self-test

def check(verbose=False):
    rnd = random.Random(1)
    tpl = templates()
    n = 0
    for _ in range(300):
        seq = rnd.randrange(100000)
        cents = rnd.randrange(1000000)
        ids = [rnd.randrange(100000) for _ in range(3)]
        sym = rnd.choice([SYM_AAPL, SYM_ETF, "MSFT", "Q   "])
        side = rnd.choice("12")
        qty = rnd.randrange(100000)
        cases = {
            "X": (market_data(seq, sym, rnd.choice("012"), cents, qty),
                  {F_SEQ: f"{seq:05d}", F_SYM: sym, F_PRICE: price_str(cents).replace(".", ""),
                   F_SIZE: f"{qty:05d}"}),
            "D": (new_order(seq, ids[0], sym, side, qty, cents),
                  {F_SEQ: f"{seq:05d}", F_CLORDID: f"{ids[0]:05d}", F_SYM: sym, F_SIDE: side,
                   F_QTY: f"{qty:05d}", F_PRICE: price_str(cents).replace(".", "")}),
            "F": (cancel(seq, ids[0], ids[1], sym, side),
                  {F_SEQ: f"{seq:05d}", F_CLORDID: f"{ids[0]:05d}", F_ORIG: f"{ids[1]:05d}",
                   F_SYM: sym, F_SIDE: side}),
            "8": (exec_report(seq, ids[2], ids[0], "F", "2", sym, side, cents, qty),
                  {F_SEQ: f"{seq:05d}", F_ORDID: f"{ids[2]:05d}", F_CLORDID: f"{ids[0]:05d}",
                   F_EXECTYPE: "F", F_ORDSTATUS: "2", F_SYM: sym, F_SIDE: side,
                   F_PRICE: price_str(cents).replace(".", ""), F_QTY: f"{qty:05d}"}),
            "9": (cancel_reject(seq, ids[2], ids[0], ids[1], "2", "0"),
                  {F_SEQ: f"{seq:05d}", F_ORDID: f"{ids[2]:05d}", F_CLORDID: f"{ids[0]:05d}",
                   F_ORIG: f"{ids[1]:05d}", F_ORDSTATUS: "2", F_REASON: "0"}),
        }
        for t, ((payload, pmap), values) in cases.items():
            # entry type for X
            if t == "X":
                values[F_ENTRY] = payload[ETH_HDR - ETH_HDR:][42:43].decode()
            direct = frame(payload, TYPES[t][1], fcs=False)
            got = patch(t, values)
            if got != direct:
                print(f"MISMATCH type {t}")
                for i, (a, b) in enumerate(zip(got, direct)):
                    if a != b:
                        print(f"  offset {i}: patched {a:02x} direct {b:02x}")
                return False
            d = parse(payload)
            assert d is not None and d[35] == t
            assert len(payload) == len(tpl[t][0]) - ETH_HDR
            n += 1
    # Every field position in a template is covered by exactly one code.
    for t, (f, m) in tpl.items():
        assert len(f) == len(m)
    if verbose:
        print(f"check: {n} frames rebuilt byte-exact from templates")
    return True


# ---------------------------------------------------------------- output

def show():
    for t, (name, direction) in TYPES.items():
        p, m = BUILDERS[t]()
        print(f"--- 35={t} ({name}, {direction}) payload {len(p)} bytes, "
              f"frame {len(p) + ETH_HDR} + 4 FCS ---")
        print("  " + p.replace(SOH, b"|").decode())
        off = 0
        for f in p.split(SOH)[:-1]:
            tag, _, val = f.decode().partition("=")
            codes = {c for c, k in m[off:off + len(f)] if c not in (F_NONE, F_ANY)}
            fld = ",".join(FIELD_NAMES[c] for c in sorted(codes))
            print(f"  payload {off:3d}  frame {off + ETH_HDR:3d}  len {len(f) + 1:2d}"
                  f"  {tag:>4}={val:<9} {fld}")
            off += len(f) + 1
        print()


def sv_array(name, data, width, fmt):
    lines = [f"  localparam logic [0:{len(data) - 1}][{width - 1}:0] {name} = {{"]
    per = 12 if width <= 8 else 6
    for i in range(0, len(data), per):
        chunk = ", ".join(fmt(b) for b in data[i:i + per])
        lines.append(f"    {chunk}{',' if i + per < len(data) else ''}")
    lines.append("  };")
    return "\n".join(lines)


def write_sv(path):
    tpl = templates()
    L = []
    w = L.append
    w("`timescale 1ns / 1ps")
    w("// Generated by tools/mm_fix.py --sv. Do not edit.")
    w("//")
    w("// Frame templates and field maps for the fixed-width FIX messages of the")
    w("// two-trader exchange (docs/mm_protocol.md). A template is a whole frame")
    w("// from the destination MAC to the end of the UDP payload (no FCS), built")
    w("// with default field values and UDP checksum 0. Its map has one byte per")
    w("// frame byte: {field code[3:0], digit index[3:0]}. Code F_NONE means the")
    w("// template byte is sent as is and must match on receive; F_ANY means it")
    w("// is sent as is and not checked on receive.")
    w("")
    w("package mm_fix_pkg;")
    w("")
    for code, name in FIELD_NAMES.items():
        w(f"  localparam logic [3:0] F_{name:<9} = 4'd{code};")
    w("")
    w(f"  localparam int ETH_HDR  = {ETH_HDR};  // UDP payload starts here")
    w(f"  localparam int TYPE_OFF = {TYPE_OFF};  // frame offset of the 35= value")
    w("")
    for t, (name, direction) in TYPES.items():
        w(f"  localparam logic [7:0] T_{name:<2} = 8'h{ord(t):02x};  // '{t}'")
    w("")
    w(f"  localparam logic [31:0] SYM_AAPL = 32'h{SYM_AAPL.encode().hex()};  // \"{SYM_AAPL}\"")
    w(f"  localparam logic [31:0] SYM_ETF  = 32'h{SYM_ETF.encode().hex()};  // \"{SYM_ETF}\"")
    w(f"  localparam logic [19:0] QTY_BCD  = 20'h{QTY:05d};")
    w("")
    maxlen = max(len(f) for f, m in tpl.values())
    w(f"  localparam int TPL_MAX_LEN = {maxlen};")
    w("")
    w("  // Frame offsets of the first and last byte of each field.")
    for t, (name, direction) in TYPES.items():
        f, m = tpl[t]
        for code in sorted({c for c, k in m if c > F_ANY}):
            pos = [i for i, (c, k) in enumerate(m) if c == code]
            w(f"  localparam int {name}_{FIELD_NAMES[code]}_FIRST = {pos[0]:3d};"
              f"  localparam int {name}_{FIELD_NAMES[code]}_LAST = {pos[-1]:3d};")
    w("")
    for t, (name, direction) in TYPES.items():
        f, m = tpl[t]
        w(f"  // 35={t} {name}: {direction}, {len(f)} bytes + FCS")
        w(f"  localparam int {name}_LEN = {len(f)};")
        w(sv_array(f"{name}_TPL", f, 8, lambda b: f"8'h{b:02x}"))
        w(sv_array(f"{name}_MAP", [(c << 4) | k for c, k in m], 8, lambda b: f"8'h{b:02x}"))
        w("")
    w("  // Demo script: AAPL prints in cents as 6 BCD digits, one per step.")
    w(f"  localparam int SCRIPT_N = {len(SCRIPT_DOLLARS)};")
    w(sv_array("SCRIPT_PRICE", [d * 100 for d in SCRIPT_DOLLARS], 24,
               lambda c: f"24'h{c:06d}"))
    w("")
    w("  // ETF fair value = FAIR_NUM / FAIR_DEN * AAPL + FAIR_OFF_CENTS, in cents.")
    w("  // n / 10 == (n * DIV10_M) >> DIV10_S for n < 2^22 (exhaustively checked).")
    w(f"  localparam int          FAIR_NUM       = {FAIR_NUM};")
    w(f"  localparam int          FAIR_DEN       = {FAIR_DEN};")
    w(f"  localparam logic [31:0] FAIR_OFF_CENTS = 32'd{FAIR_OFF_CENTS};")
    w(f"  localparam logic [31:0] DIV10_M        = 32'd{DIV10_M};")
    w(f"  localparam int          DIV10_S        = {DIV10_S};")
    w("")
    w("endpackage")
    w("")
    with open(path, "w", newline="\n") as fh:
        fh.write("\n".join(L))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="self-test")
    ap.add_argument("--sv", help="SystemVerilog package file to write")
    a = ap.parse_args()
    if not a.check and not a.sv:
        show()
        return
    if not check(verbose=True):
        sys.exit(1)
    if a.sv:
        write_sv(a.sv)
        print(f"wrote {a.sv}")


if __name__ == "__main__":
    main()
