#!/usr/bin/env bash
# Before/after benchmark for the Redis cache: the same breakpoint test, with the cache off and then on.
#
#   bash bench/compare-redis.sh                      three workloads, about 30 minutes
#   SERIES="reads" DURATION=15 bash bench/compare-redis.sh        one workload, quicker
#
# The API is switched with CACHE_ENABLED (same build, same data, same test script).
# For each workload and each mode:
#   1. recreate the API container in that mode
#   2. empty Redis (a cold cache), then warm up for 10 s so both modes start from a steady state
#   3. run find-ceiling.sh: step the request rate up until p95 >= 500 ms, errors >= 1% or >= 3% dropped
# Modes are alternated per workload so that slow drift in the laptop's disk does not favour one side.
#
# Workloads (all reads pick from 10,000 links, 80% of reads going to the hottest 20% of them):
#   reads   100% reads
#   mix99   99% reads / 1% writes   (typical for a link shortener)
#   mix85   85% reads / 15% writes  (write-heavy; the cache cannot help the writes)
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
SERIES=${SERIES:-"reads mix99 mix85"}
DURATION=${DURATION:-25}
KEYS=${KEYS:-10000}
export DURATION KEYS

declare -A WRITE_SHARE=( [reads]=0 [mix99]=0.01 [mix85]=0.15 )
declare -A RATES=(
  [reads]="2000 4000 6000 8000 10000 12000 14000 16000 20000"
  [mix99]="2000 4000 6000 8000 10000 12000 14000 16000 20000"
  [mix85]="1000 2000 3000 4000 5000 6000"
)

redis_cli() { docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"; }
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }

set_cache() {   # $1 = true | false
  CACHE_ENABLED=$1 docker compose up -d --force-recreate --no-deps api >/dev/null 2>&1
  for _ in $(seq 1 60); do
    curl -sf localhost:5101/health/db >/dev/null 2>&1 && break
    sleep 2
  done
  local enabled; enabled=$(curl -s localhost:5101/health/db | python -I -c "import sys,json; print(json.load(sys.stdin)['cache'].get('enabled'))")
  echo "API restarted with the cache enabled = $enabled"
  [ "$enabled" = "$( [ "$1" = true ] && echo True || echo False )" ] || { echo "cache switch did not take effect"; exit 1; }
}

step "Preparing: rebuild the API, seed $KEYS links"
docker compose up -d --build --no-deps api >/dev/null 2>&1
set_cache false
have=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" ${PROJECT}-pg-node1-1 psql -h haproxy1 -p 5000 -U postgres -d lab -X -tA -c "SELECT count(*) FROM links WHERE short_code LIKE 'bench-key-%'")
if [ "${have:-0}" -lt "$KEYS" ]; then
  echo "seeding ($have of $KEYS exist)..."
  docker run --rm --network "$NET" -v "$PWD/bench:/bench" -e SEED=1 -e KEYS="$KEYS" -e RATE=1 -e DURATION=2s -e OUT=/bench/results/seed.json \
    grafana/k6:0.52.0 run --quiet /bench/k6-ceiling.js >/dev/null 2>&1
fi
echo "links available to read: $(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" ${PROJECT}-pg-node1-1 psql -h haproxy1 -p 5000 -U postgres -d lab -X -tA -c "SELECT count(*) FROM links WHERE short_code LIKE 'bench-key-%'")"
sleep 20   # let replicas replay the seed

for series in $SERIES; do
  for mode in false true; do
    label=$([ "$mode" = true ] && echo "Redis ON " || echo "Redis OFF")
    step "$series: $label"
    set_cache "$mode"
    redis_cli FLUSHALL >/dev/null
    WRITE_SHARE=${WRITE_SHARE[$series]} RATES="1000" DURATION=10 OUT_FILE=bench/results/warmup.csv bash bench/find-ceiling.sh >/dev/null 2>&1
    WRITE_SHARE=${WRITE_SHARE[$series]} RATES="${RATES[$series]}" LABEL="$series, $label" \
      OUT_FILE="bench/results/redis-$([ "$mode" = true ] && echo on || echo off)-$series.csv" bash bench/find-ceiling.sh
    sleep 20
  done
done

step "Summary"
python -I bench/summarize-redis.py bench/results $SERIES
step "Leaving the API with the cache enabled"
set_cache true
