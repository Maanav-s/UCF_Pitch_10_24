#!/usr/bin/env python3
"""Capture one UART dump from the FPGA exchange (board 1) into a CSV file.

Start this, then press BTNR on the exchange. The dump (rtl/board1/exchange_dump.sv)
is written as received to runs/<run>/<run>.csv, one folder per run:

  # run label=B tick_ns=20 samples=4096
  0,75163
  1,74980
  ...
  # min=...,max=...,replies=...,timeouts=...,other=...,stale=...

Sample lines are <index>,<ticks>; 4294967295 marks a timeout. A comment
line with the capture time and port is added at the top. At 115200 baud a
4096-entry dump takes about 5 s.

Needs pyserial:  python -m pip install pyserial

Usage:
  python tools/capture.py --list
  python tools/capture.py --port COM5 [--run runB] [--baud 115200] [--wait 60]

Without --run the folder is named run<label>_<date>-<time>, e.g.
runB_20261021-200335, with the label from the dump header (SW[14:13]). An
existing run is not overwritten unless --force is given. Afterwards,
"python tools/analyze.py <run>" writes that run's statistics and plots into
the same folder.

On Windows the Basys3 shows up as "USB Serial Port (COMn)"; it has two
channels (JTAG and UART), so pick the one --list shows as the serial port.
Programming from Vivado and capturing can happen with both connected.
"""
import argparse
import datetime
import os
import sys
import time

TIMEOUT_TICKS = 0xFFFFFFFF
RUNS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "runs")


def run_csv(runs_dir, run):
    return os.path.normpath(os.path.join(runs_dir, run, run + ".csv"))


def list_ports():
    from serial.tools import list_ports as lp
    ports = list(lp.comports())
    if not ports:
        print("no serial ports found")
    for p in ports:
        print(f"{p.device:8s} {p.description}  [{p.hwid}]")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial port, e.g. COM5 or /dev/ttyUSB1")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--run", help="run name, the folder under runs/ (default run<label>_<date>-<time>)")
    ap.add_argument("--runs-dir", default=RUNS_DIR, help="folder holding the runs (default runs/)")
    ap.add_argument("--force", action="store_true", help="overwrite an existing run")
    ap.add_argument("--wait", type=float, default=60.0,
                    help="seconds to wait for the dump to start (default 60)")
    ap.add_argument("--list", action="store_true", help="list serial ports and exit")
    a = ap.parse_args()

    try:
        import serial
    except ImportError:
        sys.exit("pyserial is not installed: python -m pip install pyserial")

    if a.list:
        list_ports()
        return
    if not a.port:
        ap.error("--port is required (or use --list)")
    if a.run and os.path.exists(run_csv(a.runs_dir, a.run)) and not a.force:
        sys.exit(f"{run_csv(a.runs_dir, a.run)} exists; pick another --run or add --force")

    ser = serial.Serial(a.port, a.baud, timeout=0.5)
    ser.reset_input_buffer()
    print(f"listening on {a.port} at {a.baud} baud; press BTNR on the exchange")

    lines = []
    header = None
    n_expected = None
    deadline = time.monotonic() + a.wait
    buf = b""
    while True:
        chunk = ser.read(4096)
        if not chunk:
            if header is None and time.monotonic() > deadline:
                sys.exit(f"no dump within {a.wait:.0f} s")
            if header is not None and time.monotonic() > deadline:
                sys.exit(f"dump stopped after {len(lines)} lines")
            continue
        deadline = time.monotonic() + (a.wait if header is None else 5.0)
        buf += chunk
        while b"\n" in buf:
            raw, buf = buf.split(b"\n", 1)
            line = raw.decode("ascii", errors="replace").strip()
            if header is None:
                if not line.startswith("# run "):
                    continue  # partial line from before the dump
                header = line
                fields = dict(kv.split("=", 1) for kv in line[2:].split()[1:] if "=" in kv)
                n_expected = int(fields.get("samples", "0"))
                print(f"  {line}")
            lines.append(line)
            if line.startswith("# min="):
                break
            if len(lines) % 512 == 1 and len(lines) > 1:
                print(f"  {len(lines) - 1} / {n_expected} samples", end="\r")
        else:
            continue
        break
    ser.close()

    samples = [l for l in lines if l and not l.startswith("#")]
    if len(samples) != n_expected:
        print(f"warning: header says {n_expected} samples, got {len(samples)}")

    now = datetime.datetime.now()
    stamp = now.isoformat(timespec="seconds")
    run = a.run or f"run{fields.get('label', 'X')}_{now:%Y%m%d-%H%M%S}"
    base, k = run, 2
    while os.path.exists(run_csv(a.runs_dir, run)) and not a.force:
        run, k = f"{base}_{k}", k + 1  # don't lose a dump that is already in
    out = run_csv(a.runs_dir, run)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", newline="\n") as f:
        f.write(f"# captured {stamp} from {a.port} at {a.baud} baud\n")
        for l in lines:
            f.write(l + "\n")

    ticks_ns = 20
    for kv in header[2:].split()[1:]:
        if kv.startswith("tick_ns="):
            ticks_ns = int(kv.split("=", 1)[1])
    vals = [int(l.split(",")[1]) for l in samples]
    ok = sorted(v for v in vals if v != TIMEOUT_TICKS)
    n_to = len(vals) - len(ok)
    print(f"  {lines[-1]}")
    print(f"wrote {len(samples)} samples to {out}  ({n_to} timeouts)")
    if ok:
        us = lambda t: t * ticks_ns / 1000.0
        print(f"  min {us(ok[0]):.2f} us, median {us(ok[len(ok) // 2]):.2f} us, "
              f"max {us(ok[-1]):.2f} us")
    print(f"next: python tools/analyze.py {run}")


if __name__ == "__main__":
    main()
