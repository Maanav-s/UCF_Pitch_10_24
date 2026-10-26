#!/usr/bin/env python3
"""Read two-trader exchange event dumps and score the race between the FPGA
trader (port F) and the laptop trader (port L).

Input: runs captured with tools/capture.py (runs/<run>/<run>.csv) or raw
dump files. Lines are

  # mm label=A tick_ns=20 events=<n>
  <i>,<ticks>,<rx|tx>,<L|F|B>,<X|D|F|8|9>,<side>,<status>,<clordid>,<orderid>,<price>
  # steps=<n>,fills=<n>,rx_bad=<n>

(rtl/mm/mm_dump.sv). Everything is computed from the exchange's own log, so
both traders are measured on the same clock. Several runs (BTNU, BTND, BTNR,
capture, repeated) are pooled for the statistics; each run starts flat.

Per AAPL print (a tx of X with side 2):
  - first msg: print to the trader's first message accepted by the exchange
  - cancel in: print to the trader's last cancel accepted (prints where it
    had quotes to cancel)
  - last msg: print to the trader's last message accepted; when quoting this
    is its new quote, so it is the requote time
  Times are from the print entering the exchange's TX FIFO to the reply's
  FCS being checked, the same for both ports.

Stale quotes: after a print, a trader's resting quote is stale if the new
fair (3/10 AAPL + $20) makes it a free trade for the other side: a bid above
fair or an ask below fair. Each stale quote ends picked off (filled), or
canceled in time (canceled, or displaced by a better quote); the stale
window is from the print to that end.

Fills, PnL, markout: every fill is one order of fx.QTY (100) shares, at the
resting order's price. The first fill report is the taker's, the second the
maker's. PnL is cash plus position marked to the fair of the run's last
print. Markout of a fill = (fair - price) for a buy, (price - fair) for a
sell, times the quantity, with fair taken at the fill (the fair of the print
it followed) and at the next print. Negative markout means the fill lost
money against fair: for a maker, it was picked off.

Usage:
  python tools/race.py mmA                  # runs/mmA/mmA.csv
  python tools/race.py mmA mmB mmC          # pooled
  python tools/race.py path/to/dump.csv [--csv out.csv]
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mm_fix as fx                 # noqa: E402
from mm_model import fair_cents     # noqa: E402

RUNS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "runs")
NAMES = {"L": "laptop", "F": "FPGA", "B": "both"}
TRADERS = ("F", "L")
PCTS = (50, 90, 95, 99)


def load(path):
    """Events in log order. The exchange's timestamp is 32 bits of 20 ns
    ticks, so it wraps every 86 s; it is unwrapped here, since a run of
    prints 2 s apart can cross a wrap."""
    events, meta = [], {}
    wrap, prev = 0, None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                for kv in line[1:].replace("mm ", "").split(","):
                    for part in kv.split():
                        if "=" in part:
                            k, v = part.split("=", 1)
                            meta[k] = v
                continue
            p = line.split(",")
            if len(p) != 10:
                continue
            t = int(p[1])
            if prev is not None and t < prev:
                wrap += 1 << 32
            prev = t
            events.append(dict(i=int(p[0]), t=t + wrap, dir=p[2], port=p[3], type=p[4],
                               side=p[5], status=p[6], clordid=p[7], orderid=p[8],
                               price=int(p[9])))
    return events, meta


def find_run(name):
    if os.path.exists(name):
        return name
    path = os.path.join(RUNS_DIR, name, name + ".csv")
    if os.path.exists(path):
        return path
    sys.exit(f"not found: {name}")


def analyze(events, tick_ns, run=""):
    """One run. Returns (rows, stale, fills, pnl): per-print rows, stale
    quotes, fills, and per-trader PnL."""
    us = lambda ticks: ticks * tick_ns / 1000.0

    # Split into prints; each print's window runs to the next print.
    steps = []
    for e in events:
        if e["dir"] == "tx" and e["type"] == "X" and e["side"] == "2":
            steps.append(dict(t0=e["t"], aapl=e["price"], fair=fair_cents(e["price"]), ev=[]))
        elif steps:
            steps[-1]["ev"].append(e)

    resting = {p: {} for p in TRADERS}   # clordid -> (side, price), from the exchange's reports
    stale, fills, rows = [], [], []
    pending = {}                         # (port, clordid) -> stale record awaiting its end
    for k, s in enumerate(steps):
        fair_next = steps[k + 1]["fair"] if k + 1 < len(steps) else None
        for p in TRADERS:
            for clordid, (side, price) in resting[p].items():
                if (p, clordid) in pending:
                    continue  # still stale from an earlier print: same exposure
                if (side == "1" and price > s["fair"]) or (side == "2" and price < s["fair"]):
                    rec = dict(run=run, step=k, t0=s["t0"], port=p, side=side, price=price,
                               fair=s["fair"], end=None, window=None)
                    stale.append(rec)
                    pending[(p, clordid)] = rec

        lat = {p: dict(first=None, cancel=None, last=None) for p in TRADERS}
        step_fills = []
        fill_reports = []
        for e in s["ev"]:
            p = e["port"]
            if e["dir"] == "rx" and p in TRADERS:
                dt = us(e["t"] - s["t0"])
                if lat[p]["first"] is None:
                    lat[p]["first"] = dt
                lat[p]["last"] = dt
                if e["type"] == "F":
                    lat[p]["cancel"] = dt
            if e["dir"] != "tx" or e["type"] != "8" or p not in TRADERS:
                continue
            st, key = e["status"], (p, e["clordid"])
            if st == "0":
                resting[p][e["clordid"]] = (e["side"], e["price"])
                continue
            if st not in ("4", "F"):
                continue
            resting[p].pop(e["clordid"], None)
            rec = pending.pop(key, None)
            if rec is not None:
                rec["end"] = "picked off" if st == "F" else "canceled"
                rec["window"] = us(e["t"] - rec["t0"])
            if st == "F":
                fill_reports.append(e)
        # Fill reports come in pairs: taker, then maker.
        for a, b in zip(fill_reports[0::2], fill_reports[1::2]):
            f = dict(run=run, step=k, taker=a["port"], maker=b["port"], price=a["price"],
                     taker_side=a["side"], fair=s["fair"], fair_next=fair_next)
            fills.append(f)
            step_fills.append(f)
        rows.append(dict(run=run, step=k, aapl=s["aapl"], fair=s["fair"], lat=lat,
                         fills=step_fills,
                         stale={p: [r for r in stale if r["step"] == k and r["run"] == run
                                    and r["port"] == p] for p in TRADERS},
                         too_late=sum(1 for e in s["ev"] if e["dir"] == "tx" and e["type"] == "9"
                                      and e["status"] == "0" and e["port"] == "L")))

    # PnL, marked to the fair of the last print.
    pnl = {}
    final_fair = steps[-1]["fair"] if steps else 0
    for p in TRADERS:
        pos = cash = 0
        for f in fills:
            for who, side in ((f["taker"], f["taker_side"]), (f["maker"], opposite(f["taker_side"]))):
                if who != p:
                    continue
                sign = 1 if side == "1" else -1
                pos += sign
                cash -= sign * f["price"]
        pnl[p] = dict(pos=pos, cents=cash + pos * final_fair)
    return rows, stale, fills, pnl


def opposite(side):
    return "2" if side == "1" else "1"


def markout(f, port, fair):
    """Markout in cents per share for the trader on port, or None if it was not in the fill."""
    if fair is None:
        return None
    if f["taker"] == port:
        side = f["taker_side"]
    elif f["maker"] == port:
        side = opposite(f["taker_side"])
    else:
        return None
    return (fair - f["price"]) if side == "1" else (f["price"] - fair)


def dollars(cents_per_share):
    return cents_per_share * fx.QTY / 100.0


def pct(v, p):
    """Nearest-rank percentile."""
    s = sorted(v)
    return s[max(0, math.ceil(p / 100.0 * len(s)) - 1)]


def fmt_us(v, w=9):
    return f"{'-':>{w}}" if v is None else f"{v:{w}.2f}"


def print_latency(rows):
    print("Latency from the AAPL print, us (exchange clock)")
    print(f"  {'':26} {'n':>5} " + " ".join(f"{'p' + str(q):>9}" for q in PCTS) + f" {'max':>9}")
    series = []
    for p in TRADERS:
        for key, what in (("first", "first msg"), ("cancel", "cancel in"), ("last", "last msg (requote)")):
            series.append((f"{NAMES[p]} {what}", [r["lat"][p][key] for r in rows]))
    series.append(("laptop - FPGA, first msg",
                   [r["lat"]["L"]["first"] - r["lat"]["F"]["first"] for r in rows
                    if r["lat"]["L"]["first"] is not None and r["lat"]["F"]["first"] is not None]))
    for name, v in series:
        v = [x for x in v if x is not None]
        if not v:
            print(f"  {name:26} {0:>5}")
            continue
        print(f"  {name:26} {len(v):>5} " + " ".join(fmt_us(pct(v, q)) for q in PCTS) + f" {fmt_us(max(v))}")
    if len(rows) < 20:
        print(f"  ({len(rows)} prints: p90 and up are close to the max; pool more runs for real tails)")


def print_stale(stale):
    print("Stale quotes (resting on the wrong side of the new fair after a print)")
    print(f"  {'':8} {'stale':>6} {'picked off':>11} {'canceled':>9} {'other':>6} {'pick-off rate':>14} "
          f"{'median window us':>17} {'max window us':>14}")
    for p in TRADERS:
        mine = [r for r in stale if r["port"] == p]
        po = [r for r in mine if r["end"] == "picked off"]
        cx = [r for r in mine if r["end"] == "canceled"]
        other = len(mine) - len(po) - len(cx)
        rate = f"{100.0 * len(po) / len(mine):.0f}%" if mine else "-"
        w = [r["window"] for r in mine if r["window"] is not None]
        med = fmt_us(pct(w, 50), 17) if w else f"{'-':>17}"
        mx = fmt_us(max(w), 14) if w else f"{'-':>14}"
        print(f"  {NAMES[p]:8} {len(mine):>6} {len(po):>11} {len(cx):>9} {other:>6} {rate:>14} {med} {mx}")
    print("  (other: still resting at the end of the run)")


def print_pnl(fills, pnls):
    print(f"Fills, PnL and markout ({fx.QTY} shares per fill; $ against fair)")
    print(f"  {'':8} {'fills':>6} {'taker':>6} {'maker':>6} {'adverse':>8} {'position':>9} {'PnL $':>9} "
          f"{'markout@fill $':>15} {'per fill':>9} {'markout@next $':>15} {'per fill':>9}")
    for p in TRADERS:
        mine = [f for f in fills if p in (f["taker"], f["maker"])]
        taker = sum(1 for f in mine if f["taker"] == p)
        m0 = [markout(f, p, f["fair"]) for f in mine]
        m1 = [m for m in (markout(f, p, f["fair_next"]) for f in mine) if m is not None]
        adverse = sum(1 for m in m0 if m < 0)
        pos = sum(x[p]["pos"] for x in pnls)
        cents = sum(x[p]["cents"] for x in pnls)
        per0 = f"{dollars(sum(m0)) / len(m0):9.2f}" if m0 else f"{'-':>9}"
        per1 = f"{dollars(sum(m1)) / len(m1):9.2f}" if m1 else f"{'-':>9}"
        print(f"  {NAMES[p]:8} {len(mine):>6} {taker:>6} {len(mine) - taker:>6} {adverse:>8} {pos * fx.QTY:>9} "
              f"{dollars(cents):9.2f} {dollars(sum(m0)):15.2f} {per0} {dollars(sum(m1)):15.2f} {per1}")
    print("  (adverse: fills with negative markout at the fill; position in shares;"
          " markout@next uses the next print's fair, so a run's last print has none)")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="run names under runs/, or dump files")
    ap.add_argument("--csv", help="also write the per-print table here")
    a = ap.parse_args()

    rows, stale, fills, pnls = [], [], [], []
    for name in a.runs:
        path = find_run(name)
        events, meta = load(path)
        tick_ns = int(meta.get("tick_ns", "20"))
        run = os.path.splitext(os.path.basename(path))[0]
        r, s, f, pnl = analyze(events, tick_ns, run)
        rows += r
        stale += s
        fills += f
        pnls.append(pnl)
        print(f"{path}: {len(events)} events, {len(r)} AAPL prints, "
              f"fills={meta.get('fills', '?')}, rx_bad={meta.get('rx_bad', '?')}")
    print()

    print(f"{'run':>8} {'step':>4} {'AAPL':>8} {'fair':>6} {'FPGA 1st us':>12} {'laptop 1st us':>14} "
          f"{'gap us':>9} {'stale F/L':>9} {'picked F/L':>10}  fills (taker<-maker @ price)   laptop too late")
    for r in rows:
        lf, ll = r["lat"]["F"]["first"], r["lat"]["L"]["first"]
        gap = ll - lf if lf is not None and ll is not None else None
        fl = ", ".join(f"{NAMES[f['taker']]}<-{NAMES[f['maker']]} @ ${f['price'] / 100:.2f}"
                       for f in r["fills"]) or "-"
        st = f"{len(r['stale']['F'])}/{len(r['stale']['L'])}"
        po = "/".join(str(sum(1 for x in r["stale"][p] if x["end"] == "picked off")) for p in TRADERS)
        print(f"{r['run'][-8:]:>8} {r['step']:>4} {r['aapl'] / 100:8.2f} {r['fair'] / 100:6.2f} "
              f"{fmt_us(lf, 12)} {fmt_us(ll, 14)} {fmt_us(gap)} {st:>9} {po:>10}  {fl:<30} {r['too_late']}")
    won = sum(1 for r in rows if r["lat"]["F"]["first"] is not None
              and (r["lat"]["L"]["first"] is None or r["lat"]["F"]["first"] < r["lat"]["L"]["first"]))
    print(f"\nFPGA first on {won} of {len(rows)} prints; {len(fills)} fills; "
          f"{sum(r['too_late'] for r in rows)} laptop cancels too late\n")

    print_latency(rows)
    print()
    print_stale(stale)
    print()
    print_pnl(fills, pnls)

    if a.csv:
        with open(a.csv, "w", newline="\n") as f:
            f.write("run,step,aapl_cents,fair_cents,fpga_first_us,fpga_cancel_us,fpga_last_us,"
                    "laptop_first_us,laptop_cancel_us,laptop_last_us,fills,"
                    "fpga_stale,fpga_picked_off,laptop_stale,laptop_picked_off,laptop_too_late\n")
            for r in rows:
                v = lambda x: "" if x is None else f"{x:.2f}"
                lat = [v(r["lat"][p][k]) for p in TRADERS for k in ("first", "cancel", "last")]
                st = []
                for p in TRADERS:
                    st += [str(len(r["stale"][p])),
                           str(sum(1 for x in r["stale"][p] if x["end"] == "picked off"))]
                f.write(",".join([r["run"], str(r["step"]), str(r["aapl"]), str(r["fair"])] + lat +
                                 [str(len(r["fills"]))] + st + [str(r["too_late"])]) + "\n")
        print(f"\nwrote {a.csv}")


if __name__ == "__main__":
    main()
