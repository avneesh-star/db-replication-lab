#!/usr/bin/env bash
# Durability under failure with concurrent writes: is every write the API acknowledged still in the database
# after the leader is killed mid-load?
#
#   bash bench/failover-under-load.sh                 100 writes/s for 70 s, leader killed at 15 s
#   RATE=200 bash bench/failover-under-load.sh
#
# acknowledged = requests the API answered with a success status (201 created or 200 replayed after a retry)
# present      = new rows in the table afterwards
# The test passes if present >= acknowledged. (present can be larger: a write that committed but whose reply was
# lost during the failover is in the database without having been acknowledged. That is allowed; the reverse is not.)
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
RATE=${RATE:-100}
DURATION=${DURATION:-70}
KILL_AT=${KILL_AT:-15}
PROM=localhost:9090
OUT=failover-load.json

psqlp() { docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" ${PROJECT}-pg-node1-1 psql -h haproxy1 -p 5000 -U postgres -d lab -X -tA "$@"; }
leader() { curl -s "$PROM/api/v1/query" --data-urlencode 'query=patroni_primary == 1' \
           | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['metric']['instance'].split(':')[0] if r else '')"; }

victim=$(leader); [ -n "$victim" ] || { echo "no primary; is the stack healthy?"; exit 1; }
mode=$(curl -s localhost:5101/health/db >/dev/null && docker exec $(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-api-[0-9]+$" | sort -t- -k4 -n | head -1) printenv Writes__Batch__Enabled)
before=$(psqlp -c "SELECT count(*) FROM links WHERE short_code LIKE 'ceil-%'")
echo "write batching enabled: ${mode:-unknown}   leader: $victim   rate: $RATE writes/s for ${DURATION}s, leader killed at ${KILL_AT}s"

rm -f "bench/results/$OUT"
docker run --rm --network "$NET" -v "$PWD/bench:/bench" -e RATE="$RATE" -e DURATION="${DURATION}s" -e WRITE_SHARE=1 \
  -e OUT="/bench/results/$OUT" grafana/k6:0.52.0 run --quiet /bench/k6-ceiling.js >/dev/null 2>&1 &
kpid=$!
sleep "$KILL_AT"
docker compose kill "$victim" >/dev/null 2>&1; echo "  [killed $victim at t+${KILL_AT}s]"
wait $kpid

echo "restarting $victim and letting the cluster settle ..."
docker compose start "$victim" >/dev/null 2>&1
for _ in $(seq 1 60); do
  n=$(docker compose exec -T pg-node1 patronictl -c /config/patroni.yml list 2>/dev/null | grep -cE 'Leader|Sync Standby|Replica')
  [ "$n" = 3 ] && break; sleep 3
done
sleep 5
after=$(psqlp -c "SELECT count(*) FROM links WHERE short_code LIKE 'ceil-%'")

python -I - "bench/results/$OUT" "$before" "$after" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
v = lambda n, k: m.get(n, {}).get("values", {}).get(k, 0) or 0
done = v("iterations", "count")
failed = round(v("http_req_failed", "rate") * v("http_reqs", "count"))
acked = done - failed
added = int(sys.argv[3]) - int(sys.argv[2])
print()
print(f"requests completed:          {done:,.0f}   (dropped before sending: {v('dropped_iterations','count'):,.0f})")
print(f"  acknowledged (2xx):        {acked:,.0f}")
print(f"  failed (non-2xx/timeout):  {failed:,.0f}")
print(f"new rows in the database:    {added:,}")
print(f"slowest request:             {v('http_req_duration','max')/1000:.1f} s   p95: {v('http_req_duration','p(95)')/1000:.2f} s")
if added >= acked:
    print(f"RESULT: no acknowledged write was lost" + (f"  ({added-acked:,} extra rows: committed but not acknowledged)" if added > acked else ""))
else:
    print(f"RESULT: LOST {acked-added:,} acknowledged writes")
PY
echo; docker compose exec -T pg-node1 patronictl -c /config/patroni.yml list | sed -n '1,7p'
