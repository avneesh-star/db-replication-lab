#!/usr/bin/env bash
# What do clients see when one API instance dies behind the load balancer?
#
#   bash bench/api-failure-test.sh                   4 instances, 2,000 req/s (85% reads), one killed at 15 s
#   INSTANCES=6 RATE=3000 bash bench/api-failure-test.sh
#
# Reports: how long the load balancer took to stop sending traffic to the dead instance, how many requests failed,
# and how long the instance took to rejoin after being started again.
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
INSTANCES=${INSTANCES:-4}
RATE=${RATE:-2000}
DURATION=${DURATION:-40}
KILL_AT=${KILL_AT:-15}

lb_up() { curl -s 'localhost:7003/;csv' | awk -F, '$2 ~ /^api[0-9]+$/ && $18=="UP" {n++} END {print n+0}'; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

docker compose up -d --scale api="$INSTANCES" --force-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 90); do [ "$(lb_up)" -ge "$INSTANCES" ] && break; sleep 2; done
echo "API instances up: $(lb_up) of $INSTANCES   (load balancer config: $(grep -E 'retries|redispatch' config/haproxy-lb.cfg | tr -s ' ' | tr '\n' ',' | sed 's/,$//;s/^$/none/'))"

rm -f bench/results/api-failure.json
docker run --rm --network "$NET" -v "$PWD/bench:/bench" -e RATE="$RATE" -e DURATION="${DURATION}s" -e WRITE_SHARE=0.15 \
  -e BASE=http://lb:8080 -e OUT=/bench/results/api-failure.json grafana/k6:0.52.0 run --quiet /bench/k6-ceiling.js >/dev/null 2>&1 &
kpid=$!
sleep "$KILL_AT"
victim=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-api-[0-9]+$" | sort -t- -k4 -n | tail -1)
docker update --restart=no "$victim" >/dev/null 2>&1   # otherwise Docker restarts it within seconds and it never stays dead
t0=$(now_ms)
docker kill "$victim" >/dev/null 2>&1
while [ "$(lb_up)" -ge "$INSTANCES" ]; do sleep 0.2; [ $(( $(now_ms) - t0 )) -gt 30000 ] && break; done
echo "killed $victim at t+${KILL_AT}s; the load balancer stopped using it after $(( $(now_ms) - t0 )) ms"
wait $kpid

python -I - bench/results/api-failure.json "$DURATION" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
v = lambda n, k: m.get(n, {}).get("values", {}).get(k, 0) or 0
reqs = v("http_reqs", "count"); failed = round(v("http_req_failed", "rate") * reqs)
print(f"requests: {reqs:,.0f}   failed: {failed:,} ({v('http_req_failed','rate')*100:.2f}%)   dropped by generator: {v('dropped_iterations','count'):,.0f}")
print(f"latency p95: {v('http_req_duration','p(95)'):.0f} ms   p99: {v('http_req_duration','p(99)'):.0f} ms   max: {v('http_req_duration','max')/1000:.1f} s")
PY

t1=$(now_ms)
docker compose up -d --scale api="$INSTANCES" --no-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 60); do [ "$(lb_up)" -ge "$INSTANCES" ] && break; sleep 1; done
echo "the replacement instance was back in rotation after $(( ($(now_ms) - t1) / 1000 )) s ($(lb_up) of $INSTANCES up)"
