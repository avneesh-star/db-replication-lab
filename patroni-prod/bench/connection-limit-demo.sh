#!/usr/bin/env bash
# Why PgBouncer: every API instance keeps its own connection pools, and Postgres accepts only 200 connections
# per node. Scale the API out and a burst of simultaneous users can exhaust that limit.
#
#   bash bench/connection-limit-demo.sh                       12 API instances, 1,500 simultaneous users
#   INSTANCES=6 VUS=800 bash bench/connection-limit-demo.sh
#
# The same load runs twice: API straight to Postgres (through HAProxy), then API through PgBouncer.
# The cache and batching are off so every request really uses a database connection (worst case for connections).
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
INSTANCES=${INSTANCES:-12}
VUS=${VUS:-1500}
DURATION=${DURATION:-25}
WRITE_SHARE=${WRITE_SHARE:-0.15}
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }

lb_up() { curl -s 'localhost:7003/;csv' | awk -F, '$2 ~ /^api[0-9]+$/ && $18=="UP" {n++} END {print n+0}'; }
start_api() {   # env assignments as arguments
  env "$@" CACHE_ENABLED=false WRITE_BATCHING=false L1_CACHE=false docker compose up -d --scale api="$INSTANCES" --force-recreate --no-deps api >/dev/null 2>&1
  for _ in $(seq 1 90); do [ "$(lb_up)" -ge "$INSTANCES" ] && break; sleep 2; done
  echo "API instances up behind the load balancer: $(lb_up) of $INSTANCES"
  sleep 3
}
node_conns() {
  for n in pg-node1 pg-node2 pg-node3; do
    printf '%s=%s  ' "$n" "$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" ${PROJECT}-$n-1 psql -h localhost -U postgres -d postgres -X -tA -c "SELECT count(*) FROM pg_stat_activity WHERE usename = 'app_user'")"
  done
}

run_case() {   # LABEL, env assignments...
  local label=$1; shift
  step "$label"
  start_api "$@"
  local since; since=$(date -u +%Y-%m-%dT%H:%M:%S)
  rm -f bench/results/limit-demo.json
  docker run --rm --network "$NET" -v "$PWD/bench:/bench" -e VUS="$VUS" -e DURATION="${DURATION}s" -e WRITE_SHARE="$WRITE_SHARE" \
    -e BASE=http://lb:8080 -e OUT=/bench/results/limit-demo.json grafana/k6:0.52.0 run --quiet /bench/k6-ceiling.js >/dev/null 2>&1 &
  local kpid=$!
  sleep $(( DURATION / 2 + 4 ))
  echo "database connections held by app_user, mid-load:  $(node_conns)  (each node allows 200)"
  if printf '%s' "$*" | grep -q pgbouncer; then
    echo "PgBouncer pools (db | clients active | clients waiting | server active | server idle | longest wait s):"
    docker exec -e PGPASSWORD="$APP_DB_PASSWORD" ${PROJECT}-pg-node1-1 psql -h pgbouncer -p 6432 -U app_user -d pgbouncer -X -tA -F '|' -c "SHOW POOLS" 2>/dev/null \
      | awk -F'|' '$1 ~ /^lab/ {printf "   %-7s %s | %s | %s | %s | %s\n", $1, $3, $4, $7, $10, $14}'
  fi
  wait $kpid
  python -I - bench/results/limit-demo.json "$DURATION" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
v = lambda n, k: m.get(n, {}).get("values", {}).get(k, 0) or 0
done = v("iterations", "count")
print(f"requests completed: {done:,.0f} ({done/int(sys.argv[2]):,.0f}/s)   failed: {v('http_req_failed','rate')*100:.1f}%   p95: {v('http_req_duration','p(95)'):.0f} ms   p99: {v('http_req_duration','p(99)'):.0f} ms")
PY
  echo "'too many clients' errors logged by the API instances: $(docker compose logs api --since "$since" 2>&1 | grep -ci 'too many clients')"
  echo "API instances still healthy at the end: $(lb_up) of $INSTANCES"
}

echo "$INSTANCES API instances, $VUS simultaneous users (${WRITE_SHARE} writes), ${DURATION}s, cache off, batching off"
run_case "A. API straight to Postgres (through HAProxy), pool of up to 20 + 20 connections per instance" DB_POOL=20
run_case "B. API through PgBouncer (transaction pooling, 20 real connections per database)" \
  DB_WRITER_HOST=pgbouncer DB_WRITER_PORT=6432 DB_READER_HOST=pgbouncer DB_READER_PORT=6432 DB_READER_DB=lab_ro DB_EXTRA=";No Reset On Close=true" DB_POOL=20

step "Restoring one API instance with the default settings"
CACHE_ENABLED=true docker compose up -d --scale api=1 --force-recreate --no-deps api >/dev/null 2>&1
for _ in $(seq 1 40); do curl -sf localhost:5101/healthz >/dev/null 2>&1 && break; sleep 2; done
echo "API instances: $(lb_up)"
