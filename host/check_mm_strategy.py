#!/usr/bin/env python3
"""Check the C++ strategy (host/mm_strategy.h) byte-exact against the Python
reference (class MarketMaker in tools/mm_model.py).

Builds host/mm_strategy_check with the local C++ compiler, then plays the
demo script and random AAPL scripts through mm_model.demo(). Every payload a
trader receives there is fed to the C++ strategy configured like that trader,
and its replies must equal the model's, byte for byte, as must its
buy, sell and fill counters at the end. Runs on any OS with a
C++17 compiler (set CXX to choose one; default c++, or cl on Windows).

Usage (from the repo root):  python host/check_mm_strategy.py [--seeds 50]
"""
import argparse
import os
import random
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, "..", "tools"))
import mm_fix as fx            # noqa: E402
import mm_model as mdl         # noqa: E402


def build():
    src = os.path.join(here, "mm_strategy_check.cpp")
    exe = os.path.join(here, "mm_strategy_check" + (".exe" if os.name == "nt" else ""))
    cxx = os.environ.get("CXX") or ("cl" if os.name == "nt" and shutil.which("cl") else "c++")
    if os.path.basename(cxx).lower() in ("cl", "cl.exe"):
        cmd = [cxx, "/nologo", "/O2", "/EHsc", "/std:c++17", "/W4", src, f"/Fe:{exe}",
               f"/Fo:{os.path.join(here, '')}"]
    else:
        cmd = [cxx, "-O2", "-std=c++17", "-Wall", "-Wextra", "-Werror", src, "-o", exe]
    subprocess.run(cmd, check=True)
    return exe


def check_run(exe, fpga_hs, laptop_hs, script, name):
    """Plays one script through the model; returns the number of payloads checked."""
    log, _ = mdl.demo(verbose=False, fpga_hs=fpga_hs, laptop_hs=laptop_hs, script=script)
    checked = 0
    # Each trader's input stream, replayed into a quoting and a no-quote
    # strategy (the no-quote one sees a stream it did not shape, which is
    # fine: model and C++ get the same one).
    for port, hs, quoting in ((mdl.F, fpga_hs, True), (mdl.L, laptop_hs, True),
                              (mdl.F, fpga_hs, False), (mdl.L, laptop_hs, False)):
        ref = mdl.MarketMaker(hs, quoting=quoting)
        rx = [p for kind, prt, p in log if kind == "rx" and prt == port]
        want = [ref.on_payload(p) for p in rx]
        r = subprocess.run([exe, str(hs), "1" if quoting else "0"],
                           input="".join(p.hex() + "\n" for p in rx),
                           capture_output=True, text=True, check=True)
        got = r.stdout.split("\n")
        if len(got) != len(rx) + 2 or got[-1] != "":
            print(f"MISMATCH {name}: {len(rx)} inputs, {len(got) - 2} output lines")
            return -1
        counts = f"# {ref.n_buys} {ref.n_sells} {ref.n_fills}"
        if got[-2] != counts:
            print(f"MISMATCH {name}, trader hs={hs} quoting={quoting}: counters (buys sells fills)")
            print(f"  model {counts}")
            print(f"  c++   {got[-2]}")
            return -1
        for i, (p, w, g) in enumerate(zip(rx, want, got)):
            g = [bytes.fromhex(h) for h in g.split()]
            if g != w:
                print(f"MISMATCH {name}, trader hs={hs} quoting={quoting}, input {i}: {fx.parse(p)}")
                for k in range(max(len(w), len(g))):
                    print(f"  model {w[k] if k < len(w) else None}")
                    print(f"  c++   {g[k] if k < len(g) else None}")
                return -1
        checked += len(rx)
    return checked


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--seeds", type=int, default=50, help="random scripts to play")
    a = ap.parse_args()

    exe = build()
    runs = [("demo script", 200, 100, list(fx.SCRIPT_DOLLARS))]
    for seed in range(a.seeds):
        rng = random.Random(seed)
        script = [rng.randint(50, 400) for _ in range(rng.randint(5, 40))]
        runs.append((f"seed {seed}", rng.choice((100, 200, 300)), rng.choice((50, 100, 150)), script))
    total = 0
    for name, fpga_hs, laptop_hs, script in runs:
        n = check_run(exe, fpga_hs, laptop_hs, script, name)
        if n < 0:
            print("FAIL")
            return 1
        total += n
    print(f"PASS: {len(runs)} scripts, {total} payloads, C++ replies byte-exact with mm_model")
    return 0


if __name__ == "__main__":
    sys.exit(main())
