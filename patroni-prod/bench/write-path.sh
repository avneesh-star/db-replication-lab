#!/usr/bin/env bash
# Where does a write's time go, and what would batching buy? Raw INSERTs into a table shaped like `links`
# (primary key + two unique indexes), through the primary endpoint, varying one thing at a time.
#
#   bash bench/write-path.sh                 about 6 minutes
#   DURATION=10 bash bench/write-path.sh     quicker
#
# Questions it answers:
#   - Is a single-row write limited by CPU or by waiting for the commit flush?   (rows 1-3: synchronous_commit)
#   - Does more concurrency help?                                                (row 4)
#   - How much does putting many rows in one transaction help?                   (rows 5-8)
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
IMG=patroni-lab-node:pg16
PGBIN=/usr/lib/postgresql/16/bin
DUR=${DURATION:-20}
PROM=localhost:9090

psqlp() { docker run --rm --network "$NET" -e PGPASSWORD="$POSTGRES_PASSWORD" --entrypoint $PGBIN/psql "$IMG" -h haproxy1 -p 5000 -U postgres -X -tA "$@"; }
leader() { curl -s "$PROM/api/v1/query" --data-urlencode 'query=patroni_primary == 1' \
           | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['metric']['instance'].split(':')[0] if r else '')"; }
usec() { docker exec "${PROJECT}-$1-1" cat /sys/fs/cgroup/cpu.stat 2>/dev/null | awk '/^usage_usec/ {print $2}'; }
cpu_of() { # NODE -> % of one core over 3 s
  local t0 t1 u0 u1; t0=$(date +%s%N); u0=$(usec "$1"); sleep 3; t1=$(date +%s%N); u1=$(usec "$1")
  awk -v a="${u0:-0}" -v b="${u1:-0}" -v ta="$t0" -v tb="$t1" 'BEGIN {printf "%.0f", (b-a)/((tb-ta)/1000)*100}'
}
wait_replicas() { for _ in $(seq 1 60); do
  [ "$(psqlp -d bench -c "SELECT coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0)::bigint FROM pg_stat_replication")" = 0 ] && return; sleep 2; done; }

printf '%-34s %7s %9s %10s %9s %9s %9s\n' "case" clients "txn/s" "rows/s" "avg_ms" "leader%" "standby%"
# run_case LABEL CLIENTS BATCH SYNC_MODE
run_case() {
  local label=$1 c=$2 batch=$3 mode=$4 tmp script lead sync
  tmp=$(mktemp)
  script=insert-single.sql; [ "$batch" -gt 1 ] && script=insert-batch.sql
  wait_replicas; psqlp -d bench -c "CHECKPOINT" >/dev/null
  docker run --rm --network "$NET" -v "$PWD/bench/sql:/sql:ro" -e PGPASSWORD="$POSTGRES_PASSWORD" -e PGOPTIONS="-c synchronous_commit=$mode" \
    --entrypoint $PGBIN/pgbench "$IMG" -h haproxy1 -p 5000 -U postgres -n -f "/sql/$script" -D batch="$batch" -c "$c" -j 4 -T "$DUR" bench > "$tmp" 2>&1 &
  local pid=$!
  sleep $(( DUR / 2 + 2 ))
  lead=$(leader)
  local lcpu scpu
  lcpu=$(cpu_of "$lead")
  scpu=$(for n in pg-node1 pg-node2 pg-node3; do [ "$n" != "$lead" ] && echo "$(cpu_of "$n")"; done | sort -n | tail -1)
  wait $pid
  local tps lat
  tps=$(awk '/^tps =/ {print $3}' "$tmp"); lat=$(awk '/^latency average =/ {print $4}' "$tmp")
  if [ -z "$tps" ]; then printf '%-34s %7s  FAILED: %s\n' "$label" "$c" "$(grep -o 'FATAL:.*\|error:.*' "$tmp" | head -1 | cut -c1-80)"
  else printf '%-34s %7s %9.0f %10.0f %9.2f %9s %9s\n' "$label" "$c" "$tps" "$(awk -v t="$tps" -v b="$batch" 'BEGIN {printf "%.0f", t*b}')" "$lat" "$lcpu" "$scpu"; fi
  rm -f "$tmp"
}

echo "preparing table links_bench (same indexes as links) ..."
psqlp -d postgres -c "DROP DATABASE IF EXISTS bench WITH (FORCE)" >/dev/null
psqlp -d postgres -c "CREATE DATABASE bench" >/dev/null
psqlp -d bench -c "CREATE TABLE links_bench (id bigserial PRIMARY KEY, short_code text NOT NULL UNIQUE, long_url text NOT NULL, idempotency_key text UNIQUE, created_at timestamptz NOT NULL DEFAULT now())" >/dev/null
echo "disk: $(docker exec ${PROJECT}-$(leader)-1 /usr/lib/postgresql/16/bin/pg_test_fsync -s 1 -f /data/pg/fsync_probe 2>&1 | awk '/^ *fdatasync/ {print $2; exit}') fdatasync ops/s on the leader"
docker exec ${PROJECT}-$(leader)-1 rm -f /data/pg/fsync_probe
echo "(durations: ${DUR}s each; 'rows/s' = transactions/s x rows per transaction)"
echo

run_case "single row, sync_commit=on (default)"   16   1  on
run_case "single row, sync_commit=local"          16   1  local
run_case "single row, sync_commit=off"            16   1  off
run_case "single row, 64 clients, on"             64   1  on
run_case "10 rows / txn, on"                      16  10  on
run_case "50 rows / txn, on"                      16  50  on
run_case "200 rows / txn, on"                     16 200  on
run_case "200 rows / txn, 4 clients, on"           4 200  on

echo; echo "rows in table: $(psqlp -d bench -c 'SELECT count(*) FROM links_bench')"
psqlp -d postgres -c "DROP DATABASE IF EXISTS bench WITH (FORCE)" >/dev/null
echo "test database dropped"
