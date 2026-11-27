#!/usr/bin/env bash
# What limits read throughput once Redis is on? The database and Redis are nearly idle at the limit, so the
# suspects are the API process and the load generator. This runs the same read load four ways:
#
#   A  one generator, one API                        baseline
#   B  as A, but many more pre-allocated virtual users in the generator
#   C  two generators, each at half the rate, one API
#   D  two generators, two API instances (one each)
#
#   bash bench/diagnose-limit.sh                     tests 10,000 req/s total
#   TARGET=12000 DURATION=30 bash bench/diagnose-limit.sh
#
# Reading the result: if B > A the generator was dropping requests while starting virtual users; if C > A one
# generator was the limit; if D > C one API process was the limit; if none move, something shared is.
# Requires the stack up with the cache enabled (the default).
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
TARGET=${TARGET:-10000}
DURATION=${DURATION:-25}
API1=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-api-[0-9]+$" | sort -t- -k4 -n | head -1)
API2=${PROJECT}-api2
REDIS=${PROJECT}-redis-1
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }

wait_api() { for _ in $(seq 1 60); do docker exec "$1" sh -c 'true' >/dev/null 2>&1 && \
               docker run --rm --network "$NET" --entrypoint sh grafana/k6:0.52.0 -c "wget -qO- http://$1:8080/health/db" >/dev/null 2>&1 && return 0; sleep 2; done; return 1; }

# start_k6 NAME TARGET_API RATE PREALLOC OUTFILE
start_k6() {
  docker run --rm --name "$1" --network "$NET" -v "$PWD/bench:/bench" \
    -e BASE="http://$2:8080" -e RATE="$3" -e DURATION="${DURATION}s" -e WRITE_SHARE=0 -e PREALLOC="$4" -e OUT="/bench/results/$5" \
    grafana/k6:0.52.0 run --quiet /bench/k6-ceiling.js >/dev/null 2>&1 &
}

usec() { docker exec "$1" cat /sys/fs/cgroup/cpu.stat 2>/dev/null | awk '/^usage_usec/ {print $2}'; }
vmline() { docker exec "$API1" head -1 /proc/stat; }
# sample_cores "container ..." : CPU cores used by each over ~3 s, then VM busy %
sample_cores() {
  local c; declare -A U0 T0
  local v0 v1; v0=$(vmline)
  for c in $1; do T0[$c]=$(date +%s%N); U0[$c]=$(usec "$c"); done
  sleep 3
  local out=""
  for c in $1; do
    local t1 u1; t1=$(date +%s%N); u1=$(usec "$c")
    out+=" $(awk -v a="${U0[$c]:-0}" -v b="${u1:-0}" -v ta="${T0[$c]}" -v tb="$t1" 'BEGIN {printf "%.2f", (b-a)/((tb-ta)/1000)}')"
  done
  v1=$(vmline)
  local vm; vm=$(awk -v a="$v0" -v b="$v1" 'BEGIN {split(a,x," "); split(b,y," "); ta=0; tb=0; for (i=2;i<=9;i++) {ta+=x[i]; tb+=y[i]}; idle=(y[5]+y[6])-(x[5]+x[6]); printf "%.0f", (1-idle/(tb-ta))*100}')
  echo "$out | vm=$vm%"
}

# summarize OUT1 [OUT2]: total completed req/s, dropped %, worst p95 across generators
summarize() {
  python -I - "$DURATION" "$@" <<'PY'
import json, sys
dur = int(sys.argv[1]); done = dropped = 0; p95 = []; fail = 0
for p in sys.argv[2:]:
    m = json.load(open("bench/results/" + p))["metrics"]
    v = lambda n, k: m.get(n, {}).get("values", {}).get(k, 0) or 0
    done += v("iterations", "count"); dropped += v("dropped_iterations", "count")
    p95.append(v("http_req_duration", "p(95)")); fail += v("http_req_failed", "rate")
print(f"completed {done/dur:,.0f} req/s | dropped {dropped/(done+dropped)*100:.1f}% | p95 {max(p95):.0f} ms | failed {fail/len(p95)*100:.2f}%")
PY
}

step "Checking the stack"
curl -sf localhost:5101/health/db | python -I -c "import sys,json; c=json.load(sys.stdin)['cache']; print('cache:', c); sys.exit(0 if c.get('ok') else 1)" || { echo "Redis cache must be enabled and healthy"; exit 1; }
docker rm -f "$API2" >/dev/null 2>&1
echo "warming the cache (all 10,000 keys) ..."
start_k6 k6-warm "$API1" 3000 400 warm.json; wait
echo "warm."

step "A. one generator ($TARGET req/s), one API"
start_k6 k6-a "$API1" "$TARGET" 400 diag-a.json
sleep $(( DURATION / 2 + 4 ))
echo "cores:  api=$(sample_cores "$API1 k6-a $REDIS")   (order: api, k6, redis)"
wait; echo "result: $(summarize diag-a.json)"

step "B. one generator, but 3,000 virtual users pre-allocated"
start_k6 k6-a "$API1" "$TARGET" 3000 diag-b.json
sleep $(( DURATION / 2 + 6 ))
echo "cores:  $(sample_cores "$API1 k6-a $REDIS")   (order: api, k6, redis)"
wait; echo "result: $(summarize diag-b.json)"

step "C. two generators ($((TARGET/2)) req/s each), one API"
start_k6 k6-a "$API1" $((TARGET/2)) 1500 diag-c1.json
start_k6 k6-b "$API1" $((TARGET/2)) 1500 diag-c2.json
sleep $(( DURATION / 2 + 6 ))
echo "cores:  $(sample_cores "$API1 k6-a k6-b $REDIS")   (order: api, k6-a, k6-b, redis)"
wait; echo "result: $(summarize diag-c1.json diag-c2.json)"

step "D. two generators, two API instances"
docker compose run -d --no-deps --name "$API2" api >/dev/null 2>&1
if wait_api "$API2"; then
  start_k6 k6-a "$API1" $((TARGET/2)) 1500 diag-d1.json
  start_k6 k6-b "$API2" $((TARGET/2)) 1500 diag-d2.json
  sleep $(( DURATION / 2 + 6 ))
  echo "cores:  $(sample_cores "$API1 $API2 k6-a k6-b $REDIS")   (order: api1, api2, k6-a, k6-b, redis)"
  wait; echo "result: $(summarize diag-d1.json diag-d2.json)"
else
  echo "second API instance did not start"
fi
docker rm -f "$API2" >/dev/null 2>&1
step "Done (second API instance removed)"
