# Standard FIX test packet and reply

A single known-good market-data packet and its expected reply, for bring-up and
simulation. It uses minimal FIX tag=value messages instead of the binary
format in spec §4. The UDP "connection" is taken as already set up: fixed MACs,
IPs and ports from spec §3, and ARP already resolved.

Generated and checked by `tools/fix_test_packet.py`. Run it with
`--out <dir>` to write `.mem` files (one hex byte per line, for `$readmemh`)
and `.bin` files for the payloads and full frames.

## Addresses

| Direction | Src MAC | Dst MAC | Src IP:port | Dst IP:port |
| --- | --- | --- | --- | --- |
| Market data (board 1 → trader) | 02:00:00:00:00:02 | 02:00:00:00:00:01 | 192.168.10.2:5000 | 192.168.10.1:5000 |
| Reply (trader → board 1) | 02:00:00:00:00:01 | 02:00:00:00:00:02 | 192.168.10.1:5000 | 192.168.10.2:5000 |

IPv4: version/IHL 0x45, TOS 0, ID 0, flags/fragment 0, TTL 64, protocol 17.
UDP checksum is computed (non-zero).

## Fixed-width FIX

`|` below stands for SOH (0x01). Every value is fixed width, using leading zeros
where needed (FIX allows them in int and price fields). So every field is at a
constant byte offset, and the FPGA can match fields at fixed positions as it
would a binary message. It does not have to scan for `=` and SOH.

FIX header `8=FIX.4.4|9=nnn|` and trailer `10=ccc|` are kept, because they cost
little and make each message valid enough for a FIX parser to accept. BodyLength
(9) counts the bytes from the first byte after `9=nnn|` up to and including the
SOH before `10=`. CheckSum (10) is the sum of all bytes before `10=`, mod 256.

Omitted, though full FIX requires them: SenderCompID (49), TargetCompID (56),
SendingTime (52), NoMDEntries (268), MDUpdateAction (279), TransactTime (60).

## Market data: AAPL ask at $100.00 (73-byte UDP payload)

```
8=FIX.4.4|9=050|35=X|34=00001|55=AAPL|269=1|270=0100.00|271=00100|10=134|
```

| Offset | Len | Field | Meaning |
| --- | --- | --- | --- |
| 0 | 10 | `8=FIX.4.4` | BeginString |
| 10 | 6 | `9=050` | BodyLength |
| 16 | 5 | `35=X` | MsgType: Market Data Incremental Refresh |
| 21 | 9 | `34=00001` | MsgSeqNum (5 digits, covers the 16-bit `seq`) |
| 30 | 8 | `55=AAPL` | Symbol (4 chars, space-padded) |
| 38 | 6 | `269=1` | MDEntryType: 1 = Offer (ask) |
| 44 | 12 | `270=0100.00` | MDEntryPx: $100.00 |
| 56 | 10 | `271=00100` | MDEntrySize: 100 |
| 66 | 7 | `10=134` | CheckSum |

Offsets include each field's trailing SOH. Value bytes: seq at 24–28, symbol at
33–36, side at 42, price at 48–54, qty at 60–64.

Ethernet frame (119 bytes, without preamble/SFD; FCS included, as sent on the wire):

```
0000  02 00 00 00 00 01 02 00 00 00 00 02 08 00 45 00
0010  00 65 00 00 00 00 40 11 e5 34 c0 a8 0a 02 c0 a8
0020  0a 01 13 88 13 88 00 51 de 81 38 3d 46 49 58 2e
0030  34 2e 34 01 39 3d 30 35 30 01 33 35 3d 58 01 33
0040  34 3d 30 30 30 30 31 01 35 35 3d 41 41 50 4c 01
0050  32 36 39 3d 31 01 32 37 30 3d 30 31 30 30 2e 30
0060  30 01 32 37 31 3d 30 30 31 30 30 01 31 30 3d 31
0070  33 34 01 4d 73 8b b3
```

IPv4 checksum 0xE534, UDP checksum 0xDE81, FCS bytes `4d 73 8b b3`.

## Reply: buy AAPL, limit $100.00 (84-byte UDP payload)

```
8=FIX.4.4|9=061|35=D|34=00001|11=00001|55=AAPL|54=1|38=00100|40=2|44=0100.00|10=065|
```

| Offset | Len | Field | Meaning |
| --- | --- | --- | --- |
| 0 | 10 | `8=FIX.4.4` | BeginString |
| 10 | 6 | `9=061` | BodyLength |
| 16 | 5 | `35=D` | MsgType: New Order Single |
| 21 | 9 | `34=00001` | MsgSeqNum (trader's own counter) |
| 30 | 9 | `11=00001` | ClOrdID: copied from the market data's 34. Board 1 checks seq with this. |
| 39 | 8 | `55=AAPL` | Symbol |
| 47 | 5 | `54=1` | Side: 1 = Buy |
| 52 | 9 | `38=00100` | OrderQty: 100 |
| 61 | 5 | `40=2` | OrdType: 2 = Limit |
| 66 | 11 | `44=0100.00` | Price: copied from 270 |
| 77 | 7 | `10=065` | CheckSum |

Ethernet frame (130 bytes, without preamble/SFD):

```
0000  02 00 00 00 00 02 02 00 00 00 00 01 08 00 45 00
0010  00 70 00 00 00 00 40 11 e5 29 c0 a8 0a 01 c0 a8
0020  0a 02 13 88 13 88 00 5c 67 23 38 3d 46 49 58 2e
0030  34 2e 34 01 39 3d 30 36 31 01 33 35 3d 44 01 33
0040  34 3d 30 30 30 30 31 01 31 31 3d 30 30 30 30 31
0050  01 35 35 3d 41 41 50 4c 01 35 34 3d 31 01 33 38
0060  3d 30 30 31 30 30 01 34 30 3d 32 01 34 34 3d 30
0070  31 30 30 2e 30 30 01 31 30 3d 30 36 35 01 dc 70
0080  87 9d
```

IPv4 checksum 0xE529, UDP checksum 0x6723, FCS bytes `dc 70 87 9d`.

## Building the reply in hardware

The reply only depends on the market data through seq and price, so it is a
fixed template with three patches:

- Copy the 5 seq digits (MD bytes 24–28) to reply bytes 24–28 (34) and 33–37 (11).
- Copy the 7 price characters (MD bytes 48–54) to reply bytes 69–75.
- Recompute CheckSum (reply bytes 80–82). It is the template's constant
  byte sum plus the copied bytes, mod 256, as 3 ASCII digits.

BodyLength stays 061, because the widths are fixed.

## Decision for this packet

Buy, because type is market data, symbol = AAPL, side = offer, and
$100.00 ≤ limit. The limit must be at least $100.00:

- **Board 2:** the §5 switch range tops out at $80.95, so with the default
  `LIMIT_BASE` this packet gives no trade. For this test, raise `LIMIT_BASE`
  (e.g. 600000 = $60.00, giving a range of $60.00–$100.95), or hard-wire a
  limit of 1000000.
- **Laptop:** `trader --ticker AAPL --limit 100`.
