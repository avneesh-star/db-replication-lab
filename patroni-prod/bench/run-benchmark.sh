#!/usr/bin/env bash
# Database-level load and stress test for the patroni-prod cluster, using pgbench.
#
#   bash bench/run-benchmark.sh                                   full run (about 8 minutes)
#   DURATION=10 LEVELS="1 8 32" bash bench/run-benchmark.sh       quicker
#
# Phases:
#   A  writes        TPC-B-like read+write transactions through the primary endpoint (:5000)
#   B  reads         SELECT-only through the replica endpoint (:5001)
#   C  mixed         reads on the replicas and writes on the primary at the same time
#   D  commit modes  the same write load with synchronous_commit off / local / on / remote_apply
#   E  stress        more clients than the server accepts, to see how it fails
#
# The load generator runs in a container on the same Docker network, so it competes with the
# database for the host's CPUs. Treat results as a lower bound for this machine, not as
# production numbers.
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
IMG=patroni-lab-node:pg16
PGBIN=/usr/lib/postgresql/16/bin
SCALE=${SCALE:-10}                       # pgbench scale: 10 = 1,000,000 account rows (about 150 MB)
DUR=${DURATION:-20}                      # seconds per measurement
LEVELS=${LEVELS:-"1 4 8 16 32 64 128"}   # client counts to ramp through
PROM=localhost:9090
OUT="bench/results/$(date +%Y%m%d-%H%M%S).csv"
echo "phase,clients,tps,avg_latency_ms,failed,leader_cpu_pct,replica_cpu_pct" > "$OUT"

step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }
psqlp() { docker run --rm --network "$NET" -e PGPASSWORD="$POSTGRES_PASSWORD" --entrypoint $PGBIN/psql "$IMG" \
            -h haproxy1 -p 5000 -U postgres -X -tA "$@"; }
# bench HOST PORT [pgbench args]: runs pgbench in a throwaway container against database "bench"
bench() { local host=$1 port=$2; shift 2
          docker run --rm --network "$NET" -e PGPASSWORD="$POSTGRES_PASSWORD" ${PGOPTIONS:+-e PGOPTIONS="$PGOPTIONS"} \
            --entrypoint $PGBIN/pgbench "$IMG" -h "$host" -p "$port" -U postgres "$@" bench; }
leader() { curl -s "$PROM/api/v1/query" --data-urlencode 'query=patroni_primary == 1' \
           | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['metric']['instance'].split(':')[0] if r else '')"; }
# CPU use of each node over a 3 s window, from the container's own cgroup counters (cpu.stat usage_usec).
# 100% = one full core, which is also each node's limit, so a reading near 100 means that node is saturated.
# Prints: leader CPU%, then the busiest replica's CPU%.
cpu_usage() { docker exec "${PROJECT}-$1-1" awk '/^usage_usec/ {print $2}' /sys/fs/cgroup/cpu.stat 2>/dev/null; }
sample_cpu() {
  local lead n t0 t1 u0 u1 pct m=0 l="?"
  lead=$(leader)
  declare -A U0 T0
  for n in pg-node1 pg-node2 pg-node3; do T0[$n]=$(date +%s%N); U0[$n]=$(cpu_usage $n); done
  sleep 3
  for n in pg-node1 pg-node2 pg-node3; do
    t1=$(date +%s%N); u1=$(cpu_usage $n)
    pct=$(awk -v a="${U0[$n]:-0}" -v b="${u1:-0}" -v ta="${T0[$n]}" -v tb="$t1" 'BEGIN {printf "%.0f", (b-a) / ((tb-ta)/1000) * 100}')
    if [ "$n" = "$lead" ]; then l=$pct; else [ "$pct" -gt "$m" ] && m=$pct; fi
  done
  echo "$l $m"
}
# run_level PHASE HOST PORT CLIENTS [pgbench flags]: one measurement, prints one table row
run_level() {
  local phase=$1 host=$2 port=$3 c=$4; shift 4
  local j=$(( c < 4 ? c : 4 )) tmp cpu tps lat failed
  tmp=$(mktemp)
  settle                                  # replicas caught up and dirty pages flushed, so runs start level
  bench "$host" "$port" -c "$c" -j "$j" -T "$DUR" "$@" > "$tmp" 2>&1 &
  local pid=$!
  sleep $(( DUR / 2 ))                    # sample CPU in the middle, once the load has settled
  cpu=$(sample_cpu)
  wait $pid
  tps=$(awk '/^tps =/ {print $3}' "$tmp"); lat=$(awk '/^latency average =/ {print $4}' "$tmp")
  failed=$(awk '/^number of failed transactions:/ {print $5}' "$tmp")
  if [ -z "$tps" ]; then
    printf '%-22s %7s   FAILED: %s\n' "$phase" "$c" "$(grep -o 'FATAL:.*' "$tmp" | head -1 | cut -c1-90)"
    echo "$phase,$c,,,,," >> "$OUT"
  else
    printf '%-22s %7s %10.0f %12.2f %8s %12s %12s\n' "$phase" "$c" "$tps" "$lat" "${failed:-0}" "${cpu% *}" "${cpu#* }"
    echo "$phase,$c,$tps,$lat,${failed:-0},${cpu% *},${cpu#* }" >> "$OUT"
  fi
  rm -f "$tmp"
}
header() { printf '%-22s %7s %10s %12s %8s %12s %12s\n' phase clients tps "avg_lat_ms" failed "leader_cpu%" "replica_cpu%"; }
wait_replicas() {
  for _ in $(seq 1 60); do
    [ "$(psqlp -d bench -c "SELECT coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0)::bigint FROM pg_stat_replication")" = 0 ] && return
    sleep 2
  done
}
settle() { wait_replicas; psqlp -d bench -c "CHECKPOINT" >/dev/null; }

# ---------------------------------------------------------------- environment
step "Environment"
roles=$(docker compose exec -T pg-node1 patronictl -c /config/patroni.yml list)
echo "date:           $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "docker host:    $(docker info --format '{{.NCPU}} CPUs, {{.MemTotal}} bytes memory')"
echo "db nodes:       1 CPU and 1 GB each (docker-compose limits), shared_buffers 256MB, max_connections 200"
echo "replication:    $(echo "$roles" | grep -c 'Sync Standby') synchronous standby, $(echo "$roles" | grep -c ' Replica ') async replica"
echo "pgbench scale:  $SCALE ($((SCALE*100000)) account rows), ${DUR}s per measurement, client levels: $LEVELS"
echo "results file:   $OUT"

step "Preparing database 'bench' (scale $SCALE)"
psqlp -d postgres -c "DROP DATABASE IF EXISTS bench WITH (FORCE)" >/dev/null
psqlp -d postgres -c "CREATE DATABASE bench" >/dev/null
docker run --rm --network "$NET" -e PGPASSWORD="$POSTGRES_PASSWORD" --entrypoint $PGBIN/pgbench "$IMG" \
  -h haproxy1 -p 5000 -U postgres -i -q -s "$SCALE" bench 2>&1 | tail -2
wait_replicas
echo "data loaded and replicated to both standbys"

step "Warm-up (results discarded): fills caches and gets the first checkpoints out of the way"
bench haproxy1 5000 -c 16 -j 4 -T 15 >/dev/null 2>&1
bench haproxy1 5001 -c 16 -j 4 -T 10 -S -n >/dev/null 2>&1

# ---------------------------------------------------------------- A
step "A. Write throughput: read+write transactions via the primary endpoint (:5000)"
header
for c in $LEVELS; do run_level "A writes" haproxy1 5000 "$c"; done

# ---------------------------------------------------------------- B
step "B. Read throughput: SELECT-only via the replica endpoint (:5001)"
header
for c in $LEVELS; do run_level "B reads" haproxy1 5001 "$c" -S -n; done

# ---------------------------------------------------------------- C
step "C. Mixed: 32 read clients on the replicas and 8 write clients on the primary at the same time"
header
tmpw=$(mktemp)
bench haproxy1 5000 -c 8 -j 2 -T "$DUR" > "$tmpw" 2>&1 &
wpid=$!
run_level "C reads (mixed)" haproxy1 5001 32 -S -n
wait $wpid
printf '%-22s %7s %10.0f %12.2f %8s   (run alongside the reads above)\n' "C writes (mixed)" 8 \
  "$(awk '/^tps =/ {print $3}' "$tmpw")" "$(awk '/^latency average =/ {print $4}' "$tmpw")" "$(awk '/^number of failed transactions:/ {print $5}' "$tmpw")"
rm -f "$tmpw"

# ---------------------------------------------------------------- D
step "D. Cost of durability: the same 16-client write load under each synchronous_commit mode"
header
for pass in 1 2; do                       # two passes, in the same order, to show how noisy the numbers are
  for mode in off local on remote_apply; do
    PGOPTIONS="-c synchronous_commit=$mode" run_level "D $mode (pass $pass)" haproxy1 5000 16
  done
done
echo "off: no flush wait | local: primary's own disk | on: also the sync standby's disk (cluster default) | remote_apply: standby has replayed it"

# ---------------------------------------------------------------- E
step "E. Stress: more clients than max_connections (200) allows"
header
run_level "E stress" haproxy1 5000 260

step "After the run"
wait_replicas
echo "replication status on the primary:"
psqlp -d bench -F ' | ' -c "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS replay_lag_bytes FROM pg_stat_replication ORDER BY 1"
echo "alerts firing now: $(curl -s "$PROM/api/v1/query" --data-urlencode 'query=count(ALERTS{alertstate="firing"})' | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)")"
[ "${KEEP_DB:-0}" = 1 ] || psqlp -d postgres -c "DROP DATABASE IF EXISTS bench WITH (FORCE)" >/dev/null
echo "results saved to $OUT"
