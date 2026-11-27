#!/usr/bin/env bash
# Reads with Redis only vs Redis plus the in-process (L1) cache, at the same fixed rates.
# The load generator cannot go much past about 9,700 req/s on this machine, so the useful comparison is
# what each side spends at the same rate: API CPU, Redis CPU, latency and where reads were served from.
#
#   bash bench/compare-l1.sh            about 6 minutes
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a
DURATION=${DURATION:-25}; export DURATION
RATES=${RATES:-"4000 8000 10000"}

set_l1() {
  L1_CACHE=$1 docker compose up -d --force-recreate --no-deps api >/dev/null 2>&1
  for _ in $(seq 1 60); do curl -sf localhost:5101/healthz >/dev/null 2>&1 && break; sleep 2; done
  echo "API restarted with the L1 cache = $1"
}

for mode in false true; do
  name=$([ "$mode" = true ] && echo l1 || echo redis-only)
  printf '\n\033[1;36m=== %s\033[0m\n' "reads: $name"
  set_l1 "$mode"
  docker compose exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning FLUSHALL >/dev/null
  WRITE_SHARE=0 RATES="3000" DURATION=15 OUT_FILE=bench/results/warmup.csv bash bench/find-ceiling.sh >/dev/null 2>&1
  WRITE_SHARE=0 RATES="$RATES" LABEL="reads, $name" OUT_FILE="bench/results/l1-$name.csv" bash bench/find-ceiling.sh
  sleep 15
done
printf '\n\033[1;36m=== %s\033[0m\n' "Leaving the API with the L1 cache on"
set_l1 true
