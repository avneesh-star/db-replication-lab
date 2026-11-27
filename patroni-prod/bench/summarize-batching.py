"""Summarise write-batching runs written by compare-batching.sh.

usage: python -I bench/summarize-batching.py bench/results 2
"""
import csv
import os
import sys

results_dir, passes = sys.argv[1], int(sys.argv[2])


def load(mode, n):
    path = os.path.join(results_dir, f"batching-{mode}-pass{n}.csv")
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def stats(rows):
    passed = [int(r["target_rps"]) for r in rows if r["verdict"] == "PASS"]
    failed = [int(r["target_rps"]) for r in rows if r["verdict"] == "FAIL"]
    peak = max((float(r["achieved_rps"]) for r in rows), default=0)
    return (max(passed) if passed else 0), (min(failed) if failed else None), peak


print(f"{'pass':>4} | {'last pass OFF':>13} {'peak OFF':>9} | {'last pass ON':>12} {'peak ON':>8} | {'gain (peak)':>11}")
peaks = {"off": [], "on": []}
for n in range(1, passes + 1):
    off, on = load("off", n), load("on", n)
    po, fo, ko = stats(off)
    pn, fn, kn = stats(on)
    peaks["off"].append(ko)
    peaks["on"].append(kn)
    print(f"{n:>4} | {po:>13,} {ko:>9,.0f} | {pn:>12,} {kn:>8,.0f} | {(kn / ko if ko else 0):>10.1f}x")

for n in range(1, passes + 1):
    off, on = load("off", n), load("on", n)
    print(f"\n--- pass {n}: rate | p95 off -> on | leader% off -> on | api cores off -> on | vm% off -> on | conns off -> on")
    by = lambda rows: {int(r["target_rps"]): r for r in rows}
    o, b = by(off), by(on)
    for rate in sorted(set(o) | set(b)):
        a, c = o.get(rate), b.get(rate)
        g = lambda r, k: (r[k] if r else "-")
        print(f"{rate:>6} | {g(a,'p95_ms'):>6} -> {g(c,'p95_ms'):<6} | {g(a,'leader_cpu_pct'):>4} -> {g(c,'leader_cpu_pct'):<4} | "
              f"{g(a,'api_cores'):>5} -> {g(c,'api_cores'):<5} | {g(a,'vm_cpu_pct'):>3} -> {g(c,'vm_cpu_pct'):<3} | {g(a,'db_connections'):>3} -> {g(c,'db_connections')}")

avg = lambda xs: sum(xs) / len(xs) if xs else 0
print(f"\naverage peak throughput over {passes} passes: OFF {avg(peaks['off']):,.0f} writes/s, ON {avg(peaks['on']):,.0f} writes/s "
      f"({avg(peaks['on']) / avg(peaks['off']):.1f}x)" if avg(peaks['off']) else "")
