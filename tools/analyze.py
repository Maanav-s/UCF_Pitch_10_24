#!/usr/bin/env python3
"""Analyze exchange latency runs captured with tools/capture.py.

For each CSV: converts ticks to microseconds (tick_ns from the dump header,
20 ns for the RMII exchange), leaves out timeouts (4294967295) and reports
their count, and prints min, p50, p90, p99, p99.9, max, max - min, mean and
standard deviation. The statistics need only the Python standard library.

A run is given by its name under runs/ (as written by capture.py), by its
folder, or by a CSV file. Results go to an output folder:
  one run       that run's folder, runs/<run>/
  several runs  runs/compare_<run1>_<run2>.../ (or --out)
holding report.txt (the table printed here) and, with matplotlib installed
(python -m pip install matplotlib), for all the runs together:
  latency_hist.png    histograms, log-scale counts
  latency_cdf.png     cumulative distributions (latency percentile view)
  latency_series.png  latency against sample index (shows warm-up and spikes)

Usage:
  python tools/analyze.py runA [runB ...] [--names "FPGA,USB laptop"]
         [--out DIR] [--no-plots]

Each run is named after its folder (or CSV file) unless --names is given; the
dump's run label (A-D, from SW[14:13]) is shown next to it.
"""
import argparse
import math
import os
import statistics
import sys

TIMEOUT_TICKS = 0xFFFFFFFF
RUNS_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         os.pardir, "runs"))


def resolve(arg, runs_dir):
    """Run name, run folder or CSV file -> (name, csv path, run folder)."""
    for d in (arg, os.path.join(runs_dir, arg)):
        if os.path.isdir(d):
            name = os.path.basename(os.path.normpath(d))
            csv = os.path.join(d, name + ".csv")
            if not os.path.isfile(csv):
                found = sorted(f for f in os.listdir(d) if f.endswith(".csv"))
                if len(found) != 1:
                    sys.exit(f"{d}: expected {name}.csv or a single CSV file")
                csv = os.path.join(d, found[0])
            return name, csv, d
    if os.path.isfile(arg):
        return os.path.splitext(os.path.basename(arg))[0], arg, os.path.dirname(arg) or "."
    sys.exit(f"{arg}: not a run in {runs_dir}, a folder or a CSV file")


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


def report(runs, out=sys.stdout):
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
    print("latency in us", file=out)
    print("  ".join(c.rjust(w) for c, w in zip(cols, widths)), file=out)
    for row in rows:
        print("  ".join(c.rjust(w) for c, w in zip(row, widths)), file=out)
    for name, r in runs:
        if r["summary"]:
            print(f"{name}: {r['summary']}", file=out)


def plot(runs, out_dir):
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
    fig.savefig(os.path.join(out_dir, "latency_hist.png"), dpi=150)
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
    fig.savefig(os.path.join(out_dir, "latency_cdf.png"), dpi=150)
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
    fig.savefig(os.path.join(out_dir, "latency_series.png"), dpi=150)
    plt.close(fig)

    print(f"saved latency_hist.png, latency_cdf.png, latency_series.png in {out_dir}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="run names under runs/, run folders or CSV files")
    ap.add_argument("--names", help="comma-separated run names, one per run")
    ap.add_argument("--out", help="output folder (default: the run's folder, or "
                                  "runs/compare_<runs> for several)")
    ap.add_argument("--runs-dir", default=RUNS_DIR, help="folder holding the runs (default runs/)")
    ap.add_argument("--no-plots", action="store_true")
    a = ap.parse_args()

    found = [resolve(r, a.runs_dir) for r in a.runs]
    names = a.names.split(",") if a.names else [n for n, _, _ in found]
    if len(names) != len(found):
        sys.exit("--names needs one name per run")
    if a.out:
        out_dir = a.out
    elif len(found) == 1:
        out_dir = found[0][2]
    else:
        out_dir = os.path.join(a.runs_dir, "compare_" + "_".join(n for n, _, _ in found))
    os.makedirs(out_dir, exist_ok=True)

    runs = [(n, load(csv)) for n, (_, csv, _) in zip(names, found)]
    report(runs)
    with open(os.path.join(out_dir, "report.txt"), "w", newline="\n") as f:
        f.write("runs: " + ", ".join(csv for _, csv, _ in found) + "\n")
        report(runs, f)
    print(f"saved report.txt in {out_dir}")
    if not a.no_plots:
        plot(runs, out_dir)


if __name__ == "__main__":
    main()
