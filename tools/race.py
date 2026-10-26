#!/usr/bin/env python3
"""Read a two-trader exchange event dump and print the race per AAPL print.

Input: a run captured with tools/capture.py (runs/<run>/<run>.csv) or a raw
dump file. Lines are

  # mm label=A tick_ns=20 events=<n>
  <i>,<ticks>,<rx|tx>,<L|F|B>,<X|D|F|8|9>,<side>,<status>,<clordid>,<orderid>,<price>
  # steps=<n>,fills=<n>,rx_bad=<n>

(rtl/mm/mm_dump.sv). For each AAPL print (a tx of X with side 2) it reports
when the first frame from the FPGA (port F) and from the laptop (port L)
arrived, who was filled against whom, and the laptop's cancels that came
back "too late" (9 with status 0).

Usage:
  python tools/race.py runA            # runs/runA/runA.csv
  python tools/race.py path/to/dump.csv [--csv out.csv]
"""
import argparse
import os
import sys

RUNS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "runs")
NAMES = {"L": "laptop", "F": "FPGA", "B": "both"}


def load(path):
    events, meta = [], {}
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
            events.append(dict(i=int(p[0]), t=int(p[1]), dir=p[2], port=p[3], type=p[4],
                               side=p[5], status=p[6], clordid=p[7], orderid=p[8],
                               price=int(p[9])))
    return events, meta


def analyze(events, tick_ns):
    us = lambda ticks: ticks * tick_ns / 1000.0
    steps = []
    cur = None
    for e in events:
        if e["dir"] == "tx" and e["type"] == "X" and e["side"] == "2":
            cur = dict(t0=e["t"], aapl=e["price"], first={}, fills=[], too_late=[], msgs=[])
            steps.append(cur)
            continue
        if cur is None:
            continue
        cur["msgs"].append(e)
        if e["dir"] == "rx" and e["port"] not in cur["first"]:
            cur["first"][e["port"]] = e
        if e["dir"] == "tx" and e["type"] == "8" and e["status"] == "F":
            cur["fills"].append(e)
        if e["dir"] == "tx" and e["type"] == "9" and e["status"] == "0":
            cur["too_late"].append(e)
    rows = []
    for k, s in enumerate(steps):
        f = s["first"].get("F")
        l = s["first"].get("L")
        lat_f = us(f["t"] - s["t0"]) if f else None
        lat_l = us(l["t"] - s["t0"]) if l else None
        # A fill produces one report per side; the first is the taker's.
        fills = []
        for a, b in zip(s["fills"][0::2], s["fills"][1::2]):
            fills.append((a["port"], b["port"], a["price"]))
        rows.append(dict(step=k, aapl=s["aapl"], lat_f=lat_f, lat_l=lat_l,
                         first_f=f, first_l=l, fills=fills, too_late=s["too_late"]))
    return rows


def fmt_us(v):
    return "-" if v is None else f"{v:9.2f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run", help="run name under runs/, or a dump file")
    ap.add_argument("--csv", help="also write the per-step table here")
    a = ap.parse_args()

    path = a.run
    if not os.path.exists(path):
        path = os.path.join(RUNS_DIR, a.run, a.run + ".csv")
    if not os.path.exists(path):
        sys.exit(f"not found: {a.run}")
    events, meta = load(path)
    tick_ns = int(meta.get("tick_ns", "20"))
    rows = analyze(events, tick_ns)
    print(f"{path}: {len(events)} events, {len(rows)} AAPL prints, "
          f"fills={meta.get('fills', '?')}, rx_bad={meta.get('rx_bad', '?')}")
    print()
    print(f"{'step':>4} {'AAPL':>8} {'FPGA 1st msg us':>16} {'laptop 1st msg us':>18} "
          f"{'gap us':>10}  fills (taker<-maker @ price)   laptop cancels too late")
    for r in rows:
        gap = None
        if r["lat_f"] is not None and r["lat_l"] is not None:
            gap = r["lat_l"] - r["lat_f"]
        fills = ", ".join(f"{NAMES[t]}<-{NAMES[m]} @ ${p / 100:.2f}" for t, m, p in r["fills"]) or "-"
        tl = len(r["too_late"])
        print(f"{r['step']:>4} {r['aapl'] / 100:8.2f} {fmt_us(r['lat_f']):>16} {fmt_us(r['lat_l']):>18} "
              f"{fmt_us(gap):>10}  {fills:<30} {tl}")
    lf = [r["lat_f"] for r in rows if r["lat_f"] is not None]
    ll = [r["lat_l"] for r in rows if r["lat_l"] is not None]
    print()
    if lf:
        print(f"FPGA   first message: min {min(lf):.2f} us, median {sorted(lf)[len(lf) // 2]:.2f} us, max {max(lf):.2f} us")
    if ll:
        print(f"laptop first message: min {min(ll):.2f} us, median {sorted(ll)[len(ll) // 2]:.2f} us, max {max(ll):.2f} us")
    won = sum(1 for r in rows if r["lat_f"] is not None and (r["lat_l"] is None or r["lat_f"] < r["lat_l"]))
    print(f"FPGA first on {won} of {len(rows)} prints; "
          f"{sum(len(r['fills']) for r in rows)} fills, "
          f"{sum(len(r['too_late']) for r in rows)} laptop cancels too late")
    print("(times are from the print entering the exchange's TX FIFO to the reply's FCS being checked)")

    if a.csv:
        with open(a.csv, "w", newline="\n") as f:
            f.write("step,aapl_cents,fpga_first_us,laptop_first_us,fills,too_late\n")
            for r in rows:
                f.write(f"{r['step']},{r['aapl']},{r['lat_f'] if r['lat_f'] is not None else ''},"
                        f"{r['lat_l'] if r['lat_l'] is not None else ''},{len(r['fills'])},{len(r['too_late'])}\n")
        print(f"wrote {a.csv}")


if __name__ == "__main__":
    main()
