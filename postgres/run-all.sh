#!/usr/bin/env bash
# PostgreSQL streaming replication lab. Starts a primary with two replicas and
# runs each scenario in turn, printing what the databases report.
#
#   bash run-all.sh            run everything (starts the stack if needed)
#   bash run-all.sh --reset    wipe all data first
#
# Requires Docker. In Git Bash on Windows this works as is.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1   # keep Git Bash from rewriting /sql/... paths

P=pg-primary; S=pg-replica-sync; A=pg-replica-async

q()    { local node=$1; shift; docker compose exec -T "$node" psql -U postgres -d lab -X -v ON_ERROR_STOP=1 "$@"; }
qv()   { local node=$1; shift; docker compose exec -T "$node" psql -U postgres -d lab -X -tA "$@"; }
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }

wait_healthy() {
  for svc in "$@"; do
    for _ in $(seq 1 120); do
      [ "$(docker inspect -f '{{.State.Health.Status}}' "pg-replication-lab-$svc-1" 2>/dev/null)" = healthy ] && break
      sleep 1
    done
  done
}

# Waits until a replica has replayed everything the primary has written.
wait_caught_up() {
  local target
  target=$(qv $P -c "SELECT pg_current_wal_lsn()")
  for node in "$@"; do
    for _ in $(seq 1 120); do
      [ "$(qv "$node" -c "SELECT pg_last_wal_replay_lsn() >= '$target'::pg_lsn")" = t ] && break
      sleep 0.5
    done
  done
}

set_sync() { # $1: value for synchronous_standby_names
  q $P -q -c "ALTER SYSTEM SET synchronous_standby_names = '$1'" -c "SELECT pg_reload_conf()" >/dev/null
  sleep 1
}

if [ "${1:-}" = --reset ]; then docker compose down -v >/dev/null 2>&1 || true; fi

# ---------------------------------------------------------------------------
step "1. Start: the primary, then two replicas that clone it with pg_basebackup"
docker compose up -d >/dev/null 2>&1
wait_healthy $P $S $A
q $P -q -f /sql/01_schema.sql
wait_caught_up $S $A
note "Both replicas connect and stream. With synchronous_standby_names empty, both are async."
set_sync ''
q $P -f /sql/status_primary.sql

# ---------------------------------------------------------------------------
step "2. Writes on the primary appear on the replicas; replicas refuse writes"
code="hello-$RANDOM$RANDOM"
q $P -q -c "INSERT INTO links (short_code, long_url) VALUES ('$code', 'https://example.com/hello')"
wait_caught_up $S $A
for node in $S $A; do
  printf '%-18s sees %s: %s\n' "$node" "$code" "$(qv $node -c "SELECT count(*) FROM links WHERE short_code = '$code'")"
done
printf 'INSERT on %s: ' $S
q $S -q -c "INSERT INTO links (short_code, long_url) VALUES ('x', 'y')" 2>&1 | grep -o 'ERROR.*' || true
note "Each replica's own view of replication:"
for node in $S $A; do echo "-- $node"; q $node -f /sql/status_replica.sql; done

# ---------------------------------------------------------------------------
step "3. Make replica_sync synchronous: FIRST 1 (replica_sync)"
set_sync 'FIRST 1 (replica_sync)'
q $P -f /sql/status_primary.sql
note "sync_state is now 'sync' for replica_sync and 'async' for replica_async."

# ---------------------------------------------------------------------------
step "4. Commit latency and read-after-write per synchronous_commit mode (300 commits each)"
q $P -q -v n=300 -f /sql/03_commit_modes.sql
note "missed: not visible on the first read after COMMIT. visible_p95_ms: 95% were readable within this time."
note "Expected: only remote_apply guarantees the sync replica sees the row when COMMIT returns."
note "'on' (the default) guarantees the row is on the sync replica's disk, not that it's visible."
note "The async replica is never guaranteed to have it."

# ---------------------------------------------------------------------------
step "5. Lag under a bulk load: insert 300,000 rows and watch the replicas catch up"
q $P -q -c "INSERT INTO links (short_code, long_url) SELECT 'bulk-' || g || '-' || now()::text, 'https://example.com/bulk/' || g FROM generate_series(1, 300000) g" &
loader=$!
for i in 1 2 3 4 5 6; do
  sleep 0.7
  echo "-- t+$(( i * 7 / 10 )).$(( i * 7 % 10 ))s"
  qv $P -F ' | ' -c "SELECT application_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS behind, coalesce(replay_lag::text, '-') FROM pg_stat_replication ORDER BY 1"
done
wait $loader
wait_caught_up $S $A
note "Caught up:"
q $P -f /sql/status_primary.sql | sed -n '1,6p'

# ---------------------------------------------------------------------------
step "6. The synchronous replica goes down: commits on the primary wait for it"
docker compose stop $S >/dev/null 2>&1
note "Insert in the background. statement_timeout would not help: the statement itself"
note "finishes, and the wait happens at commit, which no timeout covers."
q $P -c "SET statement_timeout = '3s'" -c "INSERT INTO links (short_code, long_url) VALUES ('while-sync-down', 'https://example.com/x')" > /tmp/pg-lab-insert.log 2>&1 &
writer=$!
sleep 3
note "3 s later, the insert is still waiting:"
qv $P -F ' | ' -c "SELECT state, wait_event_type, wait_event, round(extract(epoch FROM now() - query_start), 1) || ' s' FROM pg_stat_activity WHERE wait_event = 'SyncRep'"
note "Cancelling it, as an application's own timeout would:"
qv $P -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE wait_event = 'SyncRep'" >/dev/null
wait $writer || true
grep -E 'WARNING|DETAIL' /tmp/pg-lab-insert.log || true
printf 'Row exists on the primary anyway? %s\n' "$(qv $P -c "SELECT count(*) FROM links WHERE short_code = 'while-sync-down'")"
note "Cancelling the wait does not undo the commit: it is already durable on the primary, just not yet on a replica."
note "Fix: let either replica satisfy the requirement, ANY 1 (replica_sync, replica_async)."
set_sync 'ANY 1 (replica_sync, replica_async)'
start=$(date +%s%N)
q $P -q -c "INSERT INTO links (short_code, long_url) VALUES ('quorum-commit', 'https://example.com/q')"
printf 'Commit with the async replica now counting: %s ms\n' $(( ($(date +%s%N) - start) / 1000000 ))
q $P -f /sql/status_primary.sql | sed -n '1,5p'
docker compose start $S >/dev/null 2>&1
wait_healthy $S
wait_caught_up $S
set_sync 'FIRST 1 (replica_sync)'
note "replica_sync is back, caught up, and synchronous again."

# ---------------------------------------------------------------------------
step "7. A replica that is down: its slot keeps the WAL it will need"
docker compose stop $A >/dev/null 2>&1
q $P -q -c "INSERT INTO links (short_code, long_url) SELECT 'while-async-down-' || g, 'https://example.com/' || g FROM generate_series(1, 200000) g"
note "While replica_async is down:"
qv $P -F ' | ' -c "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots ORDER BY 1"
docker compose start $A >/dev/null 2>&1
wait_healthy $A
wait_caught_up $A
note "After it reconnects and catches up:"
qv $P -F ' | ' -c "SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) FROM pg_replication_slots ORDER BY 1"
printf 'replica_async has the rows written while it was down: %s of 200000\n' \
  "$(qv $A -c "SELECT count(*) FROM links WHERE short_code LIKE 'while-async-down-%'")"
note "Without the slot, the primary could have recycled that WAL and the replica would need a fresh clone."

# ---------------------------------------------------------------------------
step "8. Failover: the primary dies, replica_sync is promoted, replica_async follows it"
before=$(qv $P -c "SELECT count(*) FROM links")
docker compose stop $P >/dev/null 2>&1
note "Primary stopped. Promoting replica_sync:"
q $S -q -c "SELECT pg_promote(wait => true)" >/dev/null
# The timeline is read from the last checkpoint; force one so it shows the new timeline.
q $S -q -c "CHECKPOINT" >/dev/null
printf 'replica_sync is_replica=%s, timeline=%s\n' \
  "$(qv $S -c "SELECT pg_is_in_recovery()")" "$(qv $S -c "SELECT timeline_id FROM pg_control_checkpoint()")"
q $S -q -c "INSERT INTO links (short_code, long_url) VALUES ('after-failover', 'https://example.com/new-primary')"
printf 'Writes accepted on the new primary. Rows before failover: %s, now: %s\n' "$before" "$(qv $S -c "SELECT count(*) FROM links")"

note "Re-pointing replica_async at the new primary (it needs a slot there too):"
q $S -q -c "SELECT pg_create_physical_replication_slot('slot_replica_async', true)" >/dev/null
q $A -q -c "ALTER SYSTEM SET primary_conninfo = 'host=pg-replica-sync port=5432 user=replicator password=replicator_pw application_name=replica_async'" -c "SELECT pg_reload_conf()" >/dev/null
for _ in $(seq 1 60); do
  [ "$(qv $A -c "SELECT count(*) FROM links WHERE short_code = 'after-failover'")" = 1 ] && break
  sleep 0.5
done
printf 'replica_async sees the row written after failover: %s\n' "$(qv $A -c "SELECT count(*) FROM links WHERE short_code = 'after-failover'")"
note "New primary's replicas:"
qv $S -F ' | ' -c "SELECT application_name, state, sync_state FROM pg_stat_replication"
note "The old primary can't simply restart as a replica: its WAL may contain commits the new primary never saw."
note "It would need pg_rewind or a fresh clone. To reset the whole lab: docker compose down -v"

step "Done"
