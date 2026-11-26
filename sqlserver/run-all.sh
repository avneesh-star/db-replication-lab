#!/usr/bin/env bash
# SQL Server Always On availability group lab. Builds the group on three empty
# instances, then runs each scenario in turn, printing what SQL Server reports.
#
#   bash run-all.sh            run everything (starts the instances if needed)
#   bash run-all.sh --reset    wipe all data first
#
# Requires Docker with about 3-4 GB of memory free. Works as is in Git Bash on Windows.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1   # keep Git Bash from rewriting /sql/... and /opt/... paths

PW='Lab_Passw0rd!'
SQLCMD=/opt/mssql-tools18/bin/sqlcmd

# s NODE [sqlcmd args]: tabular output.  sv NODE QUERY: bare values, one per line.
s()    { local node=$1; shift; docker compose exec -T "$node" $SQLCMD -S localhost -U sa -P "$PW" -C -b -W -s ' | ' "$@"; }
sv()   { local node=$1; shift; docker compose exec -T "$node" $SQLCMD -S localhost -U sa -P "$PW" -C -W -h -1 -Q "SET NOCOUNT ON; $1" 2>/dev/null | tr -d '\r' | sed '/^$/d'; }
step() { printf '\n\033[1;36m=== %s\033[0m\n' "$*"; }
note() { printf '\033[2m%s\033[0m\n' "$*"; }

wait_healthy() {
  for svc in "$@"; do
    for _ in $(seq 1 150); do
      [ "$(docker inspect -f '{{.State.Health.Status}}' "mssql-replication-lab-$svc-1" 2>/dev/null)" = healthy ] && break
      sleep 2
    done
  done
}

# local_state NODE: this replica's synchronization state for labdb.
local_state() {
  sv "$1" "SELECT synchronization_state_desc FROM sys.dm_hadr_database_replica_states WHERE database_id = DB_ID('labdb') AND is_local = 1"
}

wait_state() { # NODE STATE
  for _ in $(seq 1 120); do [ "$(local_state "$1")" = "$2" ] && return 0; sleep 1; done
  echo "timed out waiting for $1 to reach $2 (now: $(local_state "$1"))" >&2
}

wait_row() { # NODE CODE
  for _ in $(seq 1 120); do
    [ "$(sv "$1" "SELECT COUNT(*) FROM labdb.dbo.links WHERE short_code = N'$2'")" = 1 ] && return 0
    sleep 0.5
  done
}

if [ "${1:-}" = --reset ]; then docker compose down -v >/dev/null 2>&1 || true; fi

# ---------------------------------------------------------------------------
step "1. Start three instances and build the availability group"
docker compose up -d >/dev/null 2>&1
wait_healthy sql1 sql2 sql3
# Cap the buffer pool: the lab's data is small, and three instances share one laptop.
for n in sql1 sql2 sql3; do
  s $n -Q "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure 'max server memory (MB)', 512; RECONFIGURE;" >/dev/null
done
if [ "$(sv sql1 "SELECT COUNT(*) FROM sys.availability_groups WHERE name = 'lab_ag'")" = 0 ]; then
  note "certificate on sql1, imported on sql2 and sql3; an endpoint on each"
  s sql1 -i /sql/01_certificate_primary.sql >/dev/null
  for n in sql2 sql3; do s $n -i /sql/02_certificate_secondary.sql >/dev/null; done
  for n in sql1 sql2 sql3; do s $n -i /sql/03_endpoint.sql >/dev/null; done
  note "availability group on sql1 (sql2 synchronous, sql3 asynchronous); secondaries join"
  s sql1 -i /sql/04_create_ag.sql >/dev/null
  for n in sql2 sql3; do s $n -i /sql/05_join_secondary.sql >/dev/null; done
  note "labdb created on sql1 and added; automatic seeding copies it to the secondaries"
  s sql1 -i /sql/06_database.sql >/dev/null
fi
wait_state sql2 SYNCHRONIZED
wait_state sql3 SYNCHRONIZING
s sql1 -i /sql/status.sql
note "sql3 shows SYNCHRONIZING, not SYNCHRONIZED: that is normal for an asynchronous replica."

# ---------------------------------------------------------------------------
step "2. Writes on the primary appear on the secondaries; secondaries refuse writes"
code="hello-$RANDOM$RANDOM"
s sql1 -Q "SET NOCOUNT ON; INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (N'$code', N'https://example.com/hello')" >/dev/null
for n in sql2 sql3; do wait_row $n "$code"; printf '%-5s sees %s: %s\n' $n "$code" "$(sv $n "SELECT COUNT(*) FROM labdb.dbo.links WHERE short_code = N'$code'")"; done
printf 'INSERT on sql2: '
s sql2 -Q "INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (N'x', N'y')" 2>&1 | grep -oE 'Msg [0-9]+.*|.*read-only.*' | tail -1 || true

# ---------------------------------------------------------------------------
step "3. Commit latency and read-after-write, sql2 synchronous vs all asynchronous (300 commits each)"
s sql1 -i /sql/07_commit_probe.sql >/dev/null
s sql1 -Q "EXEC dbo.probe_commits @setup = N'sql2 SYNCHRONOUS_COMMIT', @n = 300"
s sql1 -Q "ALTER AVAILABILITY GROUP lab_ag MODIFY REPLICA ON N'sql2' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT)" >/dev/null
s sql1 -Q "EXEC dbo.probe_commits @setup = N'all ASYNCHRONOUS_COMMIT', @n = 300" | tail -n +3
note "missed: not visible on the first read after COMMIT returned."
note "visible_p95_ms: 95% of rows were readable on that secondary within this time."
s sql1 -Q "ALTER AVAILABILITY GROUP lab_ag MODIFY REPLICA ON N'sql2' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT)" >/dev/null
# A replica reports SYNCHRONIZED only once new log flows to it, so write something.
s sql1 -Q "SET NOCOUNT ON; UPDATE labdb.dbo.heartbeat SET ts = SYSUTCDATETIME() WHERE id = 1" >/dev/null
wait_state sql2 SYNCHRONIZED
note "A synchronous commit waits for sql2 to harden the log on disk, not to redo it into the tables,"
note "so a read on sql2 right after COMMIT can still miss. SQL Server has no equivalent of Postgres's"
note "remote_apply. (Polling waits at least 1 ms between reads, so small visibility times round up.)"

# ---------------------------------------------------------------------------
step "4. Lag under a bulk load: insert 300,000 rows and watch the secondaries catch up"
s sql1 -Q "SET NOCOUNT ON; INSERT INTO labdb.dbo.links (short_code, long_url)
  SELECT TOP (300000) CONCAT(N'bulk-', n, N'-', CONVERT(nvarchar(30), SYSDATETIME(), 126)), CONCAT(N'https://example.com/bulk/', n)
  FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b) AS t" >/dev/null &
loader=$!
for i in 1 2 3 4 5 6; do
  sleep 1
  echo "-- sample $i"
  sv sql1 "SELECT CONCAT(ar.replica_server_name, ' | send_queue_kb=', drs.log_send_queue_size, ' | redo_queue_kb=', drs.redo_queue_size, ' | lag_s=', drs.secondary_lag_seconds)
           FROM sys.dm_hadr_database_replica_states drs JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
           WHERE drs.database_id = DB_ID('labdb') AND drs.is_local = 0 ORDER BY ar.replica_server_name"
done
wait $loader
wait_state sql2 SYNCHRONIZED
note "Caught up:"
s sql1 -i /sql/status.sql

# ---------------------------------------------------------------------------
step "5. The synchronous secondary goes down"
docker compose stop sql2 >/dev/null 2>&1
note "The first commit waits until the primary gives up on sql2 (SESSION_TIMEOUT, 10 s by default):"
s sql1 -Q "SET NOCOUNT ON; DECLARE @t0 datetime2 = SYSDATETIME();
  INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (N'while-sql2-down', N'https://example.com/x');
  SELECT DATEDIFF(millisecond, @t0, SYSDATETIME()) AS commit_ms"
note "After that, commits no longer wait for sql2:"
s sql1 -Q "SET NOCOUNT ON; DECLARE @t0 datetime2 = SYSDATETIME();
  INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (N'while-sql2-down-2', N'https://example.com/x');
  SELECT DATEDIFF(millisecond, @t0, SYSDATETIME()) AS commit_ms"
s sql1 -i /sql/status.sql
note "Unlike Postgres, which blocks until a synchronous standby returns, SQL Server carries on after"
note "the timeout, and new data is on the primary only (sql3 is async and may lag)."
note "REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1 refuses that trade-off:"
s sql1 -Q "ALTER AVAILABILITY GROUP lab_ag SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1)" >/dev/null
printf 'INSERT on sql1: '
s sql1 -t 5 -Q "INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (N'required-sync', N'https://example.com/r')" 2>&1 | tr -d '\r' | grep -vE '^Msg|^$' | head -1 || true
printf 'SELECT on sql1: '
s sql1 -t 5 -Q "SELECT COUNT(*) FROM labdb.dbo.links" 2>&1 | tr -d '\r' | grep -vE '^Msg|^$' | head -1 || true
note "With no synchronized secondary, the database stops serving entirely, reads included."
s sql1 -Q "ALTER AVAILABILITY GROUP lab_ag SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0)" >/dev/null
docker compose start sql2 >/dev/null 2>&1
wait_healthy sql2
wait_state sql2 SYNCHRONIZED
wait_row sql2 while-sql2-down
printf 'sql2 is back and SYNCHRONIZED, and has the row written while it was down: %s\n' \
  "$(sv sql2 "SELECT COUNT(*) FROM labdb.dbo.links WHERE short_code = N'while-sql2-down'")"

# ---------------------------------------------------------------------------
step "6. A secondary that is down: the primary keeps the log it will need"
docker compose stop sql3 >/dev/null 2>&1
s sql1 -Q "SET NOCOUNT ON; INSERT INTO labdb.dbo.links (short_code, long_url)
  SELECT TOP (200000) CONCAT(N'while-sql3-down-', n), CONCAT(N'https://example.com/', n)
  FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects a CROSS JOIN sys.all_objects b) AS t" >/dev/null
s sql1 -Q "BACKUP LOG labdb TO DISK = N'/var/opt/mssql/data/labdb_1.trn' WITH INIT" >/dev/null
note "Even after a log backup, the log can't be truncated while sql3 is down:"
sv sql1 "SELECT CONCAT('log_reuse_wait=', d.log_reuse_wait_desc, ' | log used=', CAST(u.used_log_space_in_bytes / 1048576.0 AS decimal(8,1)), ' MB')
         FROM sys.databases d CROSS APPLY labdb.sys.dm_db_log_space_usage u WHERE d.name = 'labdb'"
docker compose start sql3 >/dev/null 2>&1
wait_healthy sql3
for _ in $(seq 1 120); do
  [ "$(sv sql3 "SELECT COUNT(*) FROM labdb.dbo.links WHERE short_code LIKE N'while-sql3-down-%'")" = 200000 ] && break
  sleep 1
done
s sql1 -Q "BACKUP LOG labdb TO DISK = N'/var/opt/mssql/data/labdb_2.trn' WITH INIT" >/dev/null
note "After sql3 catches up and the next log backup:"
sv sql1 "SELECT CONCAT('log_reuse_wait=', d.log_reuse_wait_desc, ' | log used=', CAST(u.used_log_space_in_bytes / 1048576.0 AS decimal(8,1)), ' MB')
         FROM sys.databases d CROSS APPLY labdb.sys.dm_db_log_space_usage u WHERE d.name = 'labdb'"
printf 'sql3 has the rows written while it was down: %s of 200000\n' \
  "$(sv sql3 "SELECT COUNT(*) FROM labdb.dbo.links WHERE short_code LIKE N'while-sql3-down-%'")"
note "AVAILABILITY_REPLICA is the counterpart of a Postgres replication slot holding WAL."

# ---------------------------------------------------------------------------
step "7. Planned failover to sql2 without data loss (CLUSTER_TYPE = NONE: manual)"
note "a) require a synchronized secondary for every commit, so nothing is in flight"
s sql1 -Q "ALTER AVAILABILITY GROUP lab_ag SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1)" >/dev/null
wait_state sql2 SYNCHRONIZED
note "b) demote sql1 and wait until it reports SECONDARY"
s sql1 -Q "ALTER AVAILABILITY GROUP lab_ag SET (ROLE = SECONDARY)" >/dev/null
role() { sv "$1" "SELECT role_desc FROM sys.dm_hadr_availability_replica_states WHERE is_local = 1"; }
for _ in $(seq 1 60); do [ "$(role sql1)" = SECONDARY ] && break; sleep 1; done
printf 'sql1 is now %s\n' "$(role sql1)"
note "c) promote sql2 (retried: it accepts once it has seen the demotion)"
promoted=no
for _ in $(seq 1 30); do
  if err=$(s sql2 -Q "ALTER AVAILABILITY GROUP lab_ag FORCE_FAILOVER_ALLOW_DATA_LOSS" 2>&1); then promoted=yes; break; fi
  sleep 1
done
[ $promoted = yes ] || { echo "promotion failed: $err" >&2; exit 1; }
printf 'sql2 is now %s\n' "$(role sql2)"
note "d) resume data movement on the other replicas, which now follow sql2"
for n in sql1 sql3; do
  for _ in $(seq 1 30); do s $n -Q "ALTER DATABASE labdb SET HADR RESUME" >/dev/null 2>&1 && break; sleep 1; done
done
s sql2 -Q "ALTER AVAILABILITY GROUP lab_ag SET (REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0)" >/dev/null
s sql2 -Q "SET NOCOUNT ON; INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (N'after-failover', N'https://example.com/new-primary')" >/dev/null
for n in sql1 sql3; do wait_row $n after-failover; printf '%s sees the row written on the new primary: %s\n' $n "$(sv $n "SELECT COUNT(*) FROM labdb.dbo.links WHERE short_code = N'after-failover'")"; done
note "Status from the new primary:"
s sql2 -i /sql/status.sql
note "sql1 was demoted cleanly before the switch, so it simply resumes as a secondary. In the Postgres"
note "lab the primary was stopped abruptly instead, which is why it needed pg_rewind or a fresh clone."
note "To reset the whole lab: docker compose down -v"

step "Done"
