#!/usr/bin/env bash
# Tune the write batcher: how do the number of workers and the maximum batch size change the write ceiling?
#
#   bash bench/tune-batcher.sh                about 20 minutes
#   CONFIGS="4:100 8:100" bash bench/tune-batcher.sh
#
# Each config is workers:maxsize. For each one the API is restarted, warmed up, and the writes-only breakpoint test
# runs at 3,000 / 4,000 / 5,000 / 6,000 writes/s, stopping at the first failing step. (The default config is 4:100.)
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

CONFIGS=${CONFIGS:-"4:100 2:100 8:100 16:100 4:50 4:200"}
RATES=${RATES:-"3000 4000 5000 6000"}
DURATION=${DURATION:-25}; export DURATION
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }

for cfg in $CONFIGS; do
  w=${cfg%%:*}; m=${cfg##*:}
  step "workers=$w  max batch=$m"
  WRITE_BATCHING=true BATCH_WORKERS=$w BATCH_MAX=$m docker compose up -d --scale api=1 --force-recreate --no-deps api >/dev/null 2>&1
  for _ in $(seq 1 60); do curl -sf localhost:5101/healthz >/dev/null 2>&1 && break; sleep 2; done
  WRITE_SHARE=1 RATES="1000" DURATION=10 OUT_FILE=bench/results/warmup.csv bash bench/find-ceiling.sh >/dev/null 2>&1
  WRITE_SHARE=1 RATES="$RATES" LABEL="writes only, workers=$w max=$m" OUT_FILE="bench/results/tune-w$w-m$m.csv" bash bench/find-ceiling.sh | grep -E "^(series|[0-9]{4})"
  sleep 15
done

step "Summary: peak writes/s completed, by config"
python -I - <<'PY'
import csv, glob, re
rows = []
for f in sorted(glob.glob("bench/results/tune-w*-m*.csv")):
    w, m = re.search(r"tune-w(\d+)-m(\d+)", f).groups()
    data = list(csv.DictReader(open(f)))
    if not data:
        continue
    peak = max(float(r["achieved_rps"]) for r in data)
    last_pass = max([int(r["target_rps"]) for r in data if r["verdict"] == "PASS"], default=0)
    best = max(data, key=lambda r: float(r["achieved_rps"]))
    rows.append((peak, w, m, last_pass, best["p95_ms"], best["leader_cpu_pct"], best["api_cores"], best["db_connections"]))
print(f"{'workers':>7} {'max':>5} | {'peak completed':>14} {'last pass':>9} | {'p95 at peak':>11} {'leader%':>8} {'api cores':>9} {'db conns':>8}")
for peak, w, m, lp, p95, lead, api, conns in sorted(rows, reverse=True):
    print(f"{w:>7} {m:>5} | {peak:>14,.0f} {lp:>9,} | {p95:>9} ms {lead:>8} {api:>9} {conns:>8}")
PY
step "Leaving the API on the default settings"
docker compose up -d --scale api=1 --force-recreate --no-deps api >/dev/null 2>&1
