#!/usr/bin/env bash
# How many reads and writes per second can the final configuration handle, measured end to end?
# Configuration: Redis cache + in-process cache + write batching, one API instance behind the load balancer,
# each database node limited to 1 CPU. Four workloads, each stepped up until it fails.
#
#   bash bench/final-capacity.sh              about 15 minutes
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a
DURATION=${DURATION:-20}; export DURATION

CACHE_ENABLED=true L1_CACHE=true WRITE_BATCHING=true docker compose up -d --scale api=1 --force-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 60); do curl -sf localhost:5101/healthz >/dev/null 2>&1 && break; sleep 2; done
echo "API config: cache=$(docker exec $(docker ps --format '{{.Names}}' | grep -E '^patroni-prod-api-[0-9]+$' | head -1) printenv Cache__Enabled) l1=$(docker exec $(docker ps --format '{{.Names}}' | grep -E '^patroni-prod-api-[0-9]+$' | head -1) printenv Cache__L1__Enabled) batching=$(docker exec $(docker ps --format '{{.Names}}' | grep -E '^patroni-prod-api-[0-9]+$' | head -1) printenv Writes__Batch__Enabled)"

run() {  # name write_share rates
  docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning FLUSHALL >/dev/null
  WRITE_SHARE=$2 RATES="1000" DURATION=10 OUT_FILE=bench/results/warmup.csv bash bench/find-ceiling.sh >/dev/null 2>&1
  WRITE_SHARE=$2 RATES="$3" LABEL="$1" OUT_FILE="bench/results/final-$1.csv" bash bench/find-ceiling.sh | grep -E "^(series|[0-9]{4} |Stopped)"
  sleep 15
}
run reads-only  0    "4000 6000 8000 10000 12000"
run mix-99-1    0.01 "4000 6000 8000 10000 12000"
run mix-85-15   0.15 "2000 3000 4000 5000 6000"
run writes-only 1    "2000 3000 4000 5000 6000"

echo; echo "=== Summary: peak completed (reads/s and writes/s at that point)"
python -I - <<'PY'
import csv
ws = {"reads-only": 0, "mix-99-1": 0.01, "mix-85-15": 0.15, "writes-only": 1}
print(f"{'workload':<13} {'last step passed':>16} {'peak total/s':>12} {'reads/s':>9} {'writes/s':>9} {'p95 at peak':>12} {'vm%':>4}")
for name, w in ws.items():
    try:
        rows = list(csv.DictReader(open(f"bench/results/final-{name}.csv")))
    except FileNotFoundError:
        continue
    if not rows:
        continue
    best = max(rows, key=lambda r: float(r["achieved_rps"]))
    peak = float(best["achieved_rps"])
    passed = max([int(r["target_rps"]) for r in rows if r["verdict"] == "PASS"], default=0)
    print(f"{name:<13} {passed:>16,} {peak:>12,.0f} {peak*(1-w):>9,.0f} {peak*w:>9,.0f} {best['p95_ms']:>10} ms {best['vm_cpu_pct']:>4}")
PY
