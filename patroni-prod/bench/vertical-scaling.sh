#!/usr/bin/env bash
# Does giving the database nodes more CPU raise the ceiling? Runs the same three breakpoint tests with each
# database node limited to 1 CPU and then to 2 CPUs (DB_CPUS in docker-compose.yml).
#
#   bash bench/vertical-scaling.sh                  about 30 minutes
#   CPUS="1.0 2.0" DURATION=15 bash bench/vertical-scaling.sh
#
# Series:
#   writes, batching OFF   one transaction per write: the leader's CPU is the limit (it reached ~90% at 600 writes/s)
#   writes, batching ON    many rows per commit: a different limit
#   reads, cache OFF       every read goes to a replica, so replica CPU is the limit
# Changing the limit recreates the three database nodes, which causes a short failover; the script waits for the
# cluster to settle. NOTE: the load generator, API and databases share this machine's 8 CPUs, so more CPU for the
# databases can be partly or wholly eaten by CPU contention. The vm% column shows how much headroom the machine had.
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

CPUS=${CPUS:-"1.0 2.0"}
DURATION=${DURATION:-20}; export DURATION
PROM=localhost:9090
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }

wait_cluster() {
  for _ in $(seq 1 60); do
    healthy=$(docker compose ps --format '{{.Name}} {{.Health}}' | grep -c 'pg-node.*healthy')
    prim=$(curl -s "$PROM/api/v1/query" --data-urlencode 'query=sum(patroni_primary)' | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)")
    [ "$healthy" = 3 ] && [ "$prim" = 1 ] && break
    sleep 5
  done
  sleep 25
  docker compose exec -T pg-node1 patronictl -c /config/patroni.yml list | sed -n '4,6p'
}

set_api() {   # env assignments
  env "$@" docker compose up -d --scale api=1 --force-recreate --no-deps api >/dev/null 2>&1
  for _ in $(seq 1 60); do curl -sf localhost:5101/healthz >/dev/null 2>&1 && break; sleep 2; done
}

series() {   # name, write share, rates, env assignments for the API
  local name=$1 ws=$2 rates=$3 cpus=$4; shift 4
  set_api "$@"
  docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning FLUSHALL >/dev/null
  WRITE_SHARE=$ws RATES="1000" DURATION=10 OUT_FILE=bench/results/warmup.csv bash bench/find-ceiling.sh >/dev/null 2>&1
  WRITE_SHARE=$ws RATES="$rates" LABEL="$name, node CPUs=$cpus" OUT_FILE="bench/results/vertical-$cpus-$name.csv" bash bench/find-ceiling.sh | grep -E "^(series|[0-9]{3,5} )"
  sleep 15
}

for cpus in $CPUS; do
  step "database nodes limited to $cpus CPU"
  DB_CPUS=$cpus docker compose up -d --force-recreate --no-deps pg-node1 pg-node2 pg-node3 >/dev/null 2>&1
  wait_cluster
  series "writes-batching-off" 1 "200 400 600 800 1000 1500 2000 3000" "$cpus" CACHE_ENABLED=true WRITE_BATCHING=false
  series "writes-batching-on"  1 "1000 2000 3000 4000 5000 6000" "$cpus" CACHE_ENABLED=true WRITE_BATCHING=true
  series "reads-cache-off"     0 "2000 3000 4000 5000 6000 8000" "$cpus" CACHE_ENABLED=false WRITE_BATCHING=false
done

step "Summary: peak completed req/s"
python -I - <<'PY'
import csv, glob, re, collections
res = collections.defaultdict(dict)
for f in glob.glob("bench/results/vertical-*-*.csv"):
    cpus, name = re.search(r"vertical-([\d.]+)-(.+)\.csv", f).groups()
    rows = list(csv.DictReader(open(f)))
    if rows:
        best = max(rows, key=lambda r: float(r["achieved_rps"]))
        res[name][cpus] = (float(best["achieved_rps"]), best["p95_ms"], best["leader_cpu_pct"], best["replica_cpu_pct"], best["vm_cpu_pct"])
cpus_all = sorted({c for d in res.values() for c in d})
print(f"{'series':<22}" + "".join(f" | {c+' CPU':>34}" for c in cpus_all))
print(f"{'':<22}" + "".join(f" | {'peak  p95  leader% replica% vm%':>34}" for c in cpus_all))
for name in sorted(res):
    line = f"{name:<22}"
    for c in cpus_all:
        v = res[name].get(c)
        line += " | " + (f"{v[0]:>6,.0f} {v[1]:>4}ms {v[2]:>6} {v[3]:>8} {v[4]:>4}" if v else f"{'-':>34}")
    print(line)
PY
step "Restoring 1 CPU per database node"
DB_CPUS=1.0 docker compose up -d --force-recreate --no-deps pg-node1 pg-node2 pg-node3 >/dev/null 2>&1
wait_cluster
set_api CACHE_ENABLED=true
