#!/usr/bin/env python3
"""Arithmetic Brownian fair path -> lat_arb_pkg.sv arrays.

seed=1, start 10000 ticks ($100.00), 16 jumps, dt ~ U(1s, 2s),
sigma = 80 ticks per sqrt(second). Prints the localparam lines.
"""
import math
import random

random.seed(1)
N = 16
fv = 10000
sigma = 80.0
ms_list = [0]
px_list = [fv]
print(f"  0  delay_ms=0     fv={fv}  (${fv/100:.2f})")
for i in range(1, N + 1):
    dt = random.uniform(1.0, 2.0)
    jump = int(round(sigma * math.sqrt(dt) * random.gauss(0, 1)))
    if jump == 0:
        jump = 1 if random.random() < 0.5 else -1
    fv = max(5000, min(20000, fv + jump))
    ms = int(round(dt * 1000))
    ms_list.append(ms)
    px_list.append(fv)
    print(f"  {i:2d}  delay_ms={ms:4d}  fv={fv}  (${fv/100:.2f})  jump={jump:+d}")

def arr(vals):
    return ", ".join(f"32'd{v}" for v in vals)

print(f"\n  localparam int N_FAIR = {len(px_list)};")
print(f"  localparam logic [31:0] FAIR_MS [0:N_FAIR-1] = '{{")
print(f"    {arr(ms_list[:5])},")
print(f"    {arr(ms_list[5:10])},")
print(f"    {arr(ms_list[10:15])},")
print(f"    {arr(ms_list[15:])}")
print("  };")
print(f"  localparam logic [31:0] FAIR_PX [0:N_FAIR-1] = '{{")
print(f"    {arr(px_list[:5])},")
print(f"    {arr(px_list[5:10])},")
print(f"    {arr(px_list[10:15])},")
print(f"    {arr(px_list[15:])}")
print("  };")
