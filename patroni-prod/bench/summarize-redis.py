"""Summarise the Redis before/after runs written by compare-redis.sh.

usage: python -I bench/summarize-redis.py bench/results reads mix99 mix85
"""
import csv
import os
import sys

results_dir, series = sys.argv[1], sys.argv[2:]
NAMES = {"reads": "100% reads", "mix99": "99% reads / 1% writes", "mix85": "85% reads / 15% writes"}


def load(mode, name):
    path = os.path.join(results_dir, f"redis-{mode}-{name}.csv")
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def ceiling(rows):
    """(last passing target rate, first failing target rate or None)."""
    passed = [int(r["target_rps"]) for r in rows if r["verdict"] == "PASS"]
    failed = [int(r["target_rps"]) for r in rows if r["verdict"] == "FAIL"]
    return (max(passed) if passed else 0), (min(failed) if failed else None)


for name in series:
    off, on = load("off", name), load("on", name)
    print(f"\n### {NAMES.get(name, name)}")
    c_off, f_off = ceiling(off)
    c_on, f_on = ceiling(on)
    print(f"ceiling (last step that passed):  Redis OFF {c_off:>6,} req/s   Redis ON {c_on:>6,} req/s"
          + (f"   ({c_on / c_off:.1f}x)" if c_off else ""))
    print(f"first failing step:               Redis OFF {f_off or 'none reached':>6}         Redis ON {f_on or 'none reached':>6}")
    rates = sorted({int(r["target_rps"]) for r in off + on})
    print(f"\n{'rate':>6} | {'p95 off':>8} {'p95 on':>7} | {'replica% off':>12} {'replica% on':>11} | {'api cores off':>13} {'on':>5} | {'redis cores':>11} {'hit%':>5} | {'vm% off':>7} {'on':>4}")
    by = lambda rows: {int(r["target_rps"]): r for r in rows}
    o, n = by(off), by(on)
    for rate in rates:
        a, b = o.get(rate), n.get(rate)
        g = lambda r, k: (r[k] if r else "-")
        print(f"{rate:>6} | {g(a,'p95_ms'):>8} {g(b,'p95_ms'):>7} | {g(a,'replica_cpu_pct'):>12} {g(b,'replica_cpu_pct'):>11} | "
              f"{g(a,'api_cores'):>13} {g(b,'api_cores'):>5} | {g(b,'redis_cores'):>11} {g(b,'cache_hit_pct'):>5} | {g(a,'vm_cpu_pct'):>7} {g(b,'vm_cpu_pct'):>4}")
