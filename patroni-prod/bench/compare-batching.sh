#!/usr/bin/env bash
# Before/after benchmark for write batching: the writes-only breakpoint test with batching off, then on,
# repeated for PASSES passes (alternating) because write numbers are noisy on a shared laptop.
#
#   bash bench/compare-batching.sh                about 25 minutes
#   PASSES=1 DURATION=15 bash bench/compare-batching.sh
#
# Same API build, same data; only WRITE_BATCHING changes. Each run: recreate the API in that mode, 10 s warm-up,
# then find-ceiling.sh with 100% writes, stopping at the first failing step (p95 >= 500 ms, errors >= 1%, or >= 3% dropped).
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PASSES=${PASSES:-2}
DURATION=${DURATION:-25}
RATES=${RATES:-"200 400 600 800 1000 1500 2000 3000 4000 6000 8000"}
export DURATION
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }

set_batching() {   # $1 = true | false
  WRITE_BATCHING=$1 docker compose up -d --force-recreate --no-deps api >/dev/null 2>&1
  for _ in $(seq 1 60); do curl -sf localhost:5101/health/db >/dev/null 2>&1 && break; sleep 2; done
  echo "API restarted with write batching = $(docker exec patroni-prod-api-1 printenv Writes__Batch__Enabled)"
}

for pass in $(seq 1 "$PASSES"); do
  for mode in false true; do
    name=$([ "$mode" = true ] && echo on || echo off)
    step "pass $pass: write batching $name"
    set_batching "$mode"
    WRITE_SHARE=1 RATES="200" DURATION=10 OUT_FILE=bench/results/warmup.csv bash bench/find-ceiling.sh >/dev/null 2>&1
    WRITE_SHARE=1 RATES="$RATES" LABEL="writes only, batching $name, pass $pass" OUT_FILE="bench/results/batching-$name-pass$pass.csv" bash bench/find-ceiling.sh
    sleep 20
  done
done

step "Summary"
python -I bench/summarize-batching.py bench/results "$PASSES"
step "Leaving the API with batching ON"
set_batching true
