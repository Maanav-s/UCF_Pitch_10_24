#!/usr/bin/env python3
"""Analyze exchange latency runs captured with tools/capture.py.

For each CSV: converts ticks to microseconds (tick_ns from the dump header,
20 ns for the RMII exchange), leaves out timeouts (4294967295) and reports
their count, and prints min, p50, p90, p99, p99.9, max, max - min, mean and
standard deviation. The statistics need only the Python standard library.

With matplotlib installed (python -m pip install matplotlib) it also saves,
for all runs together:
  <prefix>_hist.png    histograms, log-scale counts
  <prefix>_cdf.png     cumulative distributions (latency percentile view)
  <prefix>_series.png  latency against sample index (shows warm-up and spikes)

Usage:
  python tools/analyze.py runA.csv runB.csv [runC.csv ...] [--prefix latency]
         [--names "FPGA,USB laptop"] [--no-plots]

Each run is named after its file unless --names is given; the dump's run
label (A-D, from SW[14:13]) is shown next to it.
"""
import argparse
import math
import os
import statistics
import sys

TIMEOUT_TICKS = 0xFFFFFFFF


def load(path):
    label, tick_ns, summary = "?", 20, ""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("# run "):
                for kv in line[2:].split()[1:]:
                    k, _, v = kv.partition("=")
                    if k == "label":
                        label = v
                    elif k == "tick_ns":
                        tick_ns = int(v)
            elif line.startswith("# min="):
                summary = line[2:]
            elif not line.startswith("#"):
                vals.append(int(line.split(",")[1]))
    us = [v * tick_ns / 1000.0 for v in vals if v != TIMEOUT_TICKS]
    return {"label": label, "tick_ns": tick_ns, "summary": summary,
            "n": len(vals), "timeouts": len(vals) - len(us), "us": us}


def pct(sorted_us, p):
    """Percentile with linear interpolation between closest ranks."""
    if not sorted_us:
        return math.nan
    k = (len(sorted_us) - 1) * p / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    return sorted_us[lo] + (sorted_us[hi] - sorted_us[lo]) * (k - lo)


def report(runs):
    cols = ["run", "label", "samples", "timeouts", "min", "p50", "p90", "p99",
            "p99.9", "max", "max-min", "mean", "stdev"]
    rows = []
    for name, r in runs:
        s = sorted(r["us"])
        if s:
            nums = [s[0], pct(s, 50), pct(s, 90), pct(s, 99), pct(s, 99.9), s[-1],
                    s[-1] - s[0], statistics.fmean(s),
                    statistics.pstdev(s) if len(s) > 1 else 0.0]
            cells = [f"{x:.2f}" for x in nums]
        else:
            cells = ["-"] * 9
        rows.append([name, r["label"], str(r["n"]), str(r["timeouts"])] + cells)
    widths = [max(len(c), *(len(row[i]) for row in rows)) for i, c in enumerate(cols)]
    print("latency in us")
    print("  ".join(c.rjust(w) for c, w in zip(cols, widths)))
    for row in rows:
        print("  ".join(c.rjust(w) for c, w in zip(row, widths)))
    for name, r in runs:
        if r["summary"]:
            print(f"{name}: {r['summary']}")


def plot(runs, prefix):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib not installed; skipping plots (python -m pip install matplotlib)")
        return

    data = [(f"{name} ({r['label']})", r["us"]) for name, r in runs if r["us"]]
    if not data:
        return

    # Histograms on a shared log-spaced axis, since runs can differ by 100x.
    lo = min(min(us) for _, us in data)
    hi = max(max(us) for _, us in data)
    lo, hi = max(lo * 0.9, 1e-3), hi * 1.1
    nb = 120
    edges = [lo * (hi / lo) ** (i / nb) for i in range(nb + 1)]
    fig, ax = plt.subplots(figsize=(9, 5))
    for name, us in data:
        ax.hist(us, bins=edges, histtype="step", linewidth=1.5, label=name)
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlabel("round-trip latency (us)")
    ax.set_ylabel("count")
    ax.set_title("Latency histogram")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(f"{prefix}_hist.png", dpi=150)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 5))
    for name, us in data:
        s = sorted(us)
        ax.plot(s, [100.0 * (i + 1) / len(s) for i in range(len(s))], label=name)
    ax.set_xscale("log")
    ax.set_xlabel("round-trip latency (us)")
    ax.set_ylabel("percent of samples at or below")
    ax.set_title("Latency CDF")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(f"{prefix}_cdf.png", dpi=150)
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(9, 5))
    for name, us in data:
        ax.plot(range(len(us)), us, ".", markersize=2, label=name)
    ax.set_yscale("log")
    ax.set_xlabel("sample (timeouts left out)")
    ax.set_ylabel("round-trip latency (us)")
    ax.set_title("Latency over the run")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(markerscale=6)
    fig.tight_layout()
    fig.savefig(f"{prefix}_series.png", dpi=150)
    plt.close(fig)

    print(f"saved {prefix}_hist.png, {prefix}_cdf.png, {prefix}_series.png")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help="CSV files from capture.py")
    ap.add_argument("--names", help="comma-separated run names, one per file")
    ap.add_argument("--prefix", default="latency", help="plot file prefix (default latency)")
    ap.add_argument("--no-plots", action="store_true")
    a = ap.parse_args()

    names = a.names.split(",") if a.names else [os.path.splitext(os.path.basename(f))[0]
                                                for f in a.files]
    if len(names) != len(a.files):
        sys.exit("--names needs one name per file")
    runs = [(n, load(f)) for n, f in zip(names, a.files)]
    report(runs)
    if not a.no_plots:
        plot(runs, a.prefix)


if __name__ == "__main__":
    main()
