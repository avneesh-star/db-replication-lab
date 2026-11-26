#!/usr/bin/env bash
# Patroni failover demo: kill the leader, watch the write endpoint recover by itself.
#
#   bash failover-demo.sh
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }

cluster() { docker compose exec -T "$1" patronictl -c /config/patroni.yml list; }
leader()  { for i in 1 2 3; do
              [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "localhost:810$i/primary" || true)" = 200 ] && { echo "pg-node$i"; return; }
            done; }
# Run SQL through HAProxy from inside a node: $1 = node to run from, $2 = port (5000 write, 5001 read)
sql() { local from=$1 port=$2; shift 2
        docker compose exec -T "$from" psql "host=haproxy port=$port dbname=lab user=postgres password=postgres connect_timeout=2" -X -tA "$@"; }

old=$(leader); [ -n "$old" ] || { echo "No leader yet. Wait for the cluster to form: docker compose ps"; exit 1; }
for n in pg-node1 pg-node2 pg-node3; do [ "$n" != "$old" ] && client=$n && break; done

step "1. The cluster: one leader, two replicas"
cluster "$client"

step "2. Write through :5000 (always the leader), read through :5001 (replicas)"
sql "$client" 5000 -c "INSERT INTO failover_test (note) VALUES ('before failover')" >/dev/null
sleep 1
printf 'Write endpoint is served by: %s\n' "$(sql "$client" 5000 -c "SELECT inet_server_addr(), pg_is_in_recovery()")"
printf 'Read endpoint is served by:  %s\n' "$(sql "$client" 5001 -c "SELECT inet_server_addr(), pg_is_in_recovery()")"
printf 'Row visible on the read endpoint: %s\n' "$(sql "$client" 5001 -c "SELECT count(*) FROM failover_test WHERE note = 'before failover'")"

step "3. Stop the leader ($old)"
start=$(date +%s)
docker compose stop "$old" >/dev/null 2>&1
note "Keep writing through :5000 until it works again. The app's connection string never changes."
while true; do
  if sql "$client" 5000 -c "INSERT INTO failover_test (note) VALUES ('after failover')" >/dev/null 2>&1; then break; fi
  printf '  t+%ss: write failed, retrying\n' $(( $(date +%s) - start ))
  sleep 1
  [ $(( $(date +%s) - start )) -gt 90 ] && { echo "Gave up after 90s"; exit 1; }
done
printf 'Writes work again after %s s\n' $(( $(date +%s) - start ))
new=$(leader)
printf 'New leader: %s (was %s)\n' "$new" "$old"

step "4. Cluster after failover"
cluster "$client"
printf 'Rows written before and after failover: %s\n' "$(sql "$client" 5000 -c "SELECT count(*) FROM failover_test")"

step "5. Bring the old leader back: it rejoins as a replica (pg_rewind if needed)"
docker compose start "$old" >/dev/null 2>&1
for _ in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "localhost:810${old: -1}/replica" || true)" = 200 ] && break
  sleep 2
done
cluster "$client"
note "The old primary is now a replica of $new. Open http://localhost:7000 to see HAProxy's view."

step "Done"
