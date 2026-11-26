#!/usr/bin/env bash
# Control-plane failure tests for the production-style cluster.
#
#   1. Lose one HAProxy      -> the API should keep working through the other one
#   2. Lose one etcd member  -> nothing should change (2 of 3 is still a quorum)
#   3. Lose etcd quorum      -> the leader is demoted to read-only, writes fail; recovery when etcd returns
#
#   bash failure-tests.sh
# Each test restores what it broke. Test 3 causes a real write outage (about a minute).
set -uo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

API=localhost:5101
PROM=localhost:9090
tag="ft$(date +%s)"

step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }
write() { local id="$tag-$RANDOM$RANDOM"   # unique per call: a counter would not survive the $(...) subshell
          curl -s -m "${1:-20}" -o /dev/null -w '%{http_code}' -X POST "$API/links"             -H 'Content-Type: application/json' -H "Idempotency-Key: $id"             -d "{\"url\":\"https://example.com/$id\",\"code\":\"$id\"}" || true; }
lookup() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$API/links/$1" || true; }
firing() { curl -s "$PROM/api/v1/query" --data-urlencode "query=ALERTS{alertname=\"$1\",alertstate=\"firing\"}" | grep -q '"value"' && echo yes || echo no; }
roles() { for node in pg-node1 pg-node2 pg-node3; do
            r=$(docker compose exec -T pg-node1 curl -s -m 3 "http://$node:8008/" | python -I -c "import sys,json; print(json.load(sys.stdin).get('role','?'))" 2>/dev/null)
            printf '%s=%s  ' "$node" "${r:-unreachable}"; done; echo; }
batch() { local ok=0 bad=0 c; for _ in $(seq 1 "$1"); do c=$(write "${2:-20}"); [ "$c" = 201 ] && ok=$((ok+1)) || bad=$((bad+1)); done; echo "$ok ok, $bad failed"; }

first=$(write); echo "baseline write: HTTP $first"; echo "roles: $(roles)"
[ "$first" = 201 ] || { echo "stack is not healthy; aborting"; exit 1; }

# -------------------------------------------------------------------------------------
step "1. Kill haproxy1"
docker compose kill haproxy1 >/dev/null 2>&1
echo "10 writes with haproxy1 dead:  $(batch 10)"
echo "read of an existing row:       HTTP $(lookup manual-post)   (200 expected)"
echo "waiting 30 s for the alert..."; sleep 30
echo "HaproxyDown alert firing: $(firing HaproxyDown)"
docker compose start haproxy1 >/dev/null 2>&1; sleep 10
echo "after restart, 10 writes:      $(batch 10)"

# -------------------------------------------------------------------------------------
step "2. Stop etcd3 (2 of 3 members left: quorum holds)"
before=$(roles)
docker compose stop etcd3 >/dev/null 2>&1
echo "10 writes with etcd3 down:     $(batch 10)"
echo "waiting 30 s for the alert..."; sleep 30
echo "roles before: $before"
echo "roles after:  $(roles)"
echo "EtcdMemberDown alert firing: $(firing EtcdMemberDown)"
echo "5 more writes:                 $(batch 5)"

# -------------------------------------------------------------------------------------
step "3. Stop etcd2 as well (only etcd1 left: NO quorum)"
docker compose stop etcd2 >/dev/null 2>&1
t0=$(date +%s)
echo "Probing a write every 3 s for 75 s. Patroni demotes the leader once its 30 s lock expires."
for i in $(seq 1 25); do
  c=$(write 4); printf '  t+%02ds write HTTP %s\n' $(( $(date +%s)-t0 )) "${c:-000}"
  sleep 3
done
echo "roles during the outage: $(roles)"
echo "EtcdNoLeader alert firing: $(firing EtcdNoLeader)"

step "3b. Restore etcd2 and etcd3"
docker compose start etcd2 etcd3 >/dev/null 2>&1
t1=$(date +%s)
until [ "$(write 6)" = 201 ]; do
  [ $(( $(date +%s)-t1 )) -gt 120 ] && { echo "writes did not recover within 120 s"; break; }
  sleep 2
done
echo "writes recovered $(( $(date +%s)-t1 )) s after etcd quorum returned"
sleep 10
echo "roles after recovery: $(roles)"
echo "5 writes:                      $(batch 5)"

step "Done"
