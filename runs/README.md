# Runs

One folder per exchange run, written by the tools:

```
runs/<run>/<run>.csv          the UART dump (tools/capture.py)
runs/<run>/report.txt         statistics table (tools/analyze.py <run>)
runs/<run>/latency_*.png      histogram, CDF and time series of that run
runs/compare_<a>_<b>/         analyze.py with several runs: combined report and plots
```

```
python tools/capture.py --port COM9 --run runB     # or no --run: run<label>_<date>-<time>
python tools/analyze.py runB
python tools/analyze.py runA runB --names "FPGA,Laptop"
```
