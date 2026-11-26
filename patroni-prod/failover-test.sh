#!/usr/bin/env bash
# Failover test for the production-style cluster.
#   - writes through the .NET API (:5101) once per half second
#   - stops the current primary after 5 seconds
#   - reports client errors, outage length, whether the NoPrimary alert fired, and whether any
#     acknowledged write is missing afterwards (synchronous replication should make that zero)
#
#   bash failover-test.sh
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

API=localhost:5101
PROM=localhost:9090
prom() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1"; }
leader() { prom 'patroni_primary == 1' | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['metric']['instance'].split(':')[0] if r else '')"; }
sql() { docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" "$1" psql -h haproxy2 -p 5000 -U postgres -d lab -X -tA -c "$2"; }

victim=$(leader); [ -n "$victim" ] || { echo "no primary found; is the stack healthy?"; exit 1; }
for n in pg-node1 pg-node2 pg-node3; do [ "$n" != "$victim" ] && client=$n && break; done
echo "primary: $victim"
echo "cluster before:"; docker compose exec -T "$client" patronictl -c /config/patroni.yml list | sed -n '1,7p'

tag="ft$(date +%s)"; start=$(date +%s); acked=0; failed=0; alert=no
# KILL=1 simulates a crash (SIGKILL: the leader cannot release its lock, so Patroni waits out the full ttl).
# The default is a graceful stop, which releases the lock and fails over much faster.
stopcmd=stop; [ "${KILL:-0}" = 1 ] && stopcmd=kill
( sleep 5; docker compose $stopcmd "$victim" >/dev/null 2>&1; echo "  [$stopcmd $victim at t+$(( $(date +%s)-start ))s]" ) &
n=0
while [ $(( $(date +%s)-start )) -lt 75 ]; do
  n=$((n+1))
  out=$(curl -s -m 90 -X POST "$API/links" -H 'Content-Type: application/json' -H "Idempotency-Key: $tag-$n" \
        -d "{\"url\":\"https://example.com/$tag/$n\",\"code\":\"$tag-$n\"}" -w ' HTTP%{http_code}' || echo ' HTTP000')
  code=${out##*HTTP}
  if [ "$code" = 201 ]; then acked=$((acked+1)); echo "$tag-$n" >> ".acked-$tag"; else failed=$((failed+1)); fi
  att=$(echo "$out" | grep -o '"attempts":[0-9]*' | cut -d: -f2 || true)
  [ "${att:-1}" -gt 1 ] && echo "  write $n: HTTP $code after $att attempts ($(echo "$out" | grep -o '"elapsedMs":[0-9]*' | cut -d: -f2) ms) at t+$(( $(date +%s)-start ))s"
  if prom 'ALERTS{alertname="NoPrimary",alertstate="firing"}' | grep -q '"value"'; then alert=yes; fi
  sleep 0.5
done
wait

echo; echo "writes acknowledged: $acked, failed: $failed, NoPrimary alert fired: $alert"
echo "new primary: $(leader)"
docker compose exec -T "$client" patronictl -c /config/patroni.yml list | sed -n '1,7p'
present=$(sql "$client" "SELECT count(*) FROM links WHERE short_code LIKE '$tag-%'")
echo "acknowledged writes: $acked, rows present in the database: $present"
[ "$present" -ge "$acked" ] && echo "RESULT: no acknowledged write was lost" || echo "RESULT: LOST $((acked-present)) acknowledged writes"
rm -f ".acked-$tag"

docker compose start "$victim" >/dev/null 2>&1
echo "restarted $victim; it rejoins as a replica"
