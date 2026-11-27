#!/usr/bin/env bash
# Breakpoint test: raise the request rate against the .NET API step by step until the stack breaks,
# and record which component is saturated at each step.
#
#   bash bench/find-ceiling.sh
#   RATES="500 1000" DURATION=10 bash bench/find-ceiling.sh        quick check
#   WRITE_SHARE=0 LABEL="reads only" OUT_FILE=bench/results/x.csv bash bench/find-ceiling.sh
#
# A step PASSES when all of these hold:
#   p95 latency < 500 ms,  errors < 1%,  fewer than 3% of requests dropped (the generator kept up).
# The test stops at the first step that fails. The ceiling is the last passing step.
#
# Columns: api / hap1 / redis are in cores used (api and haproxy have no CPU limit; redis is limited to 1);
# leader% and replica% are % of each database node's 1-CPU limit; vm% is the whole Docker VM (8 CPUs) -
# if that is near 100 the laptop, not the architecture, is the limit. hit% is the share of reads the API
# served from Redis (0 when the cache is off).
set -uo pipefail
cd "$(dirname "$0")/.."
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a

PROJECT=patroni-prod
NET=${PROJECT}_default
RATES=${RATES:-"1000 2000 3000 4000 5000 6000 7000 8000 10000 12000 15000"}
DURATION=${DURATION:-30}
WRITE_SHARE=${WRITE_SHARE:-0.15}
KEYS=${KEYS:-10000}
PROM=localhost:9090
OUT="${OUT_FILE:-bench/results/ceiling-$(date +%Y%m%d-%H%M%S).csv}"
echo "target_rps,achieved_rps,p95_ms,p99_ms,write_p95_ms,read_p95_ms,error_pct,dropped_pct,cache_hit_pct,api_cores,haproxy1_cores,redis_cores,leader_cpu_pct,replica_cpu_pct,vm_cpu_pct,db_connections,max_repl_lag_bytes,verdict" > "$OUT"

psqlp() { docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" ${PROJECT}-pg-node1-1 psql -h haproxy1 -p 5000 -U postgres -d lab -X -tA "$@"; }
leader() { curl -s "$PROM/api/v1/query" --data-urlencode 'query=patroni_primary == 1' \
           | python -I -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['metric']['instance'].split(':')[0] if r else '')"; }
usec() { local c=$1; case "$c" in ${PROJECT}-*) ;; *) c=${PROJECT}-$c-1;; esac; docker exec "$c" cat /sys/fs/cgroup/cpu.stat 2>/dev/null | awk '/^usage_usec/ {print $2}'; }
vmstat_line() { docker exec ${PROJECT}-redis-1 head -1 /proc/stat 2>/dev/null; }

# Measures CPU over ~3 s. Prints: api cores, haproxy1 cores, leader %, busiest replica %, VM busy %, redis cores.
sample() {
  local lead names n apis; lead=$(leader)
  apis=$(docker ps --format '{{.Names}}' | grep -E "^${PROJECT}-api-[0-9]+$" | tr '\n' ' ')
  names="$apis haproxy1 pg-node1 pg-node2 pg-node3 redis"
  declare -A U0 T0 U1 T1
  local vm0 vm1; vm0=$(vmstat_line)
  for n in $names; do T0[$n]=$(date +%s%N); U0[$n]=$(usec "$n"); done
  sleep 3
  for n in $names; do T1[$n]=$(date +%s%N); U1[$n]=$(usec "$n"); done
  vm1=$(vmstat_line)
  local cores_api cores_hap cores_redis l=0 r=0 pct
  cpu() { awk -v a="${U0[$1]:-0}" -v b="${U1[$1]:-0}" -v ta="${T0[$1]}" -v tb="${T1[$1]}" 'BEGIN {printf "%.2f", (b-a) / ((tb-ta)/1000)}'; }
  cores_api=0; for n in $apis; do cores_api=$(awk -v a="$cores_api" -v b="$(cpu $n)" 'BEGIN {printf "%.2f", a+b}'); done
  cores_hap=$(cpu haproxy1); cores_redis=$(cpu redis)
  for n in pg-node1 pg-node2 pg-node3; do
    pct=$(awk -v c="$(cpu $n)" 'BEGIN {printf "%.0f", c*100}')
    if [ "$n" = "$lead" ]; then l=$pct; else [ "$pct" -gt "$r" ] && r=$pct; fi
  done
  local vm; vm=$(awk -v a="$vm0" -v b="$vm1" 'BEGIN {split(a,x," "); split(b,y," "); ta=0; tb=0; for (i=2;i<=9;i++) {ta+=x[i]; tb+=y[i]}; idle=(y[5]+y[6])-(x[5]+x[6]); printf "%.0f", (1 - idle/(tb-ta))*100}')
  echo "$cores_api $cores_hap $l $r $vm $cores_redis"
}

# How fast the leader's disk can flush right now (fdatasync operations per second): this is what limits writes.
disk_probe() {
  local lead; lead=$(leader)
  docker exec "${PROJECT}-${lead}-1" /usr/lib/postgresql/16/bin/pg_test_fsync -s 1 -f /data/pg/fsync_probe 2>&1 | awk '/^ *fdatasync/ {print $2; exit}'
  docker exec "${PROJECT}-${lead}-1" rm -f /data/pg/fsync_probe
}

echo "series: ${LABEL:-mixed}  (write share $WRITE_SHARE, ${DURATION}s per step, $KEYS keys)"
echo "disk before: $(disk_probe) fdatasync ops/s on the leader"
printf '%-7s %8s %6s %6s %7s %7s %6s %6s %5s | %4s %5s %5s %7s %8s %4s | %5s %8s  %s\n' \
  target achieved p95ms p99ms wr_p95 rd_p95 err% drop% hit% api hap1 redis leader% replica% vm% conns lag_B verdict
for rate in $RATES; do
  rm -f "bench/results/k6-rate-$rate.json"
  docker run --rm --network "$NET" -v "$PWD/bench:/bench" -e RATE="$rate" -e DURATION="${DURATION}s" \
    -e WRITE_SHARE="$WRITE_SHARE" -e KEYS="$KEYS" -e BASE="${BASE:-http://lb:8080}" \
    grafana/k6:0.52.0 run --quiet /bench/k6-ceiling.js >/dev/null 2>&1 &
  kpid=$!
  sleep $(( DURATION / 2 + 4 ))
  cpu=$(sample)
  conns=$(psqlp -c "SELECT count(*) FROM pg_stat_activity WHERE datname = 'lab'" 2>/dev/null)
  lag=$(psqlp -c "SELECT coalesce(max(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)),0)::bigint FROM pg_stat_replication" 2>/dev/null)
  wait $kpid
  row=$(python -I - "bench/results/k6-rate-$rate.json" "$rate" "$DURATION" <<'PY'
import json, sys
path, target, duration = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    m = json.load(open(path))["metrics"]
except Exception:
    print("NA " * 8); sys.exit()
def v(name, key, default=0):
    return m.get(name, {}).get("values", {}).get(key, default) or 0
dropped = v("dropped_iterations", "count")
achieved = v("iterations", "count") / duration       # completed requests per second of the step
total = v("iterations", "count") + dropped
c, rep, pri = v("read_from_cache", "count") + v("read_from_memory", "count"), v("read_from_replica", "count"), v("read_from_primary", "count")
hit = (c / (c + rep + pri) * 100) if (c + rep + pri) else 0
print(f"{achieved:.0f} {v('http_req_duration','p(95)'):.0f} {v('http_req_duration','p(99)'):.0f} "
      f"{v('http_req_duration{kind:write}','p(95)'):.0f} {v('http_req_duration{kind:read}','p(95)'):.0f} "
      f"{v('http_req_failed','rate')*100:.2f} {(dropped/total*100 if total else 0):.1f} {hit:.0f}")
PY
)
  set -- $row
  if [ "$1" = "NA" ]; then echo "step $rate: no result (generator failed to run)"; break; fi
  achieved=$1; p95=$2; p99=$3; wp95=$4; rp95=$5; err=$6; drop=$7; hit=$8
  set -- $cpu; api=$1; hap=$2; lead=$3; rep=$4; vm=$5; redis=$6
  verdict=PASS
  awk -v p="$p95" -v e="$err" -v d="$drop" 'BEGIN {exit !(p>=500 || e>=1 || d>=3)}' && verdict=FAIL
  printf '%-7s %8s %6s %6s %7s %7s %6s %6s %5s | %4s %5s %5s %7s %8s %4s | %5s %8s  %s\n' \
    "$rate" "$achieved" "$p95" "$p99" "$wp95" "$rp95" "$err" "$drop" "$hit" "$api" "$hap" "$redis" "$lead" "$rep" "$vm" "${conns:-?}" "${lag:-?}" "$verdict"
  echo "$rate,$achieved,$p95,$p99,$wp95,$rp95,$err,$drop,$hit,$api,$hap,$redis,$lead,$rep,$vm,${conns:-},${lag:-},$verdict" >> "$OUT"
  if [ "$verdict" = FAIL ]; then echo; echo "Stopped: the stack could not sustain ${rate} req/s (see thresholds in the script header)."; break; fi
  sleep 5
done
echo; echo "disk after:  $(disk_probe) fdatasync ops/s on the leader"
echo "results: $OUT"
