-- Run on the primary: what it knows about each replica.
--   sent / write / flush / replay: how far the replica has received, written,
--   flushed to disk, and applied the WAL. replay_behind is the distance from
--   the primary's current WAL position to what the replica has applied.
\echo '-- pg_stat_replication (one row per connected replica)'
SELECT application_name                                              AS replica,
       state,
       sync_state,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)) AS replay_behind,
       coalesce(write_lag::text,  '-')                               AS write_lag,
       coalesce(flush_lag::text,  '-')                               AS flush_lag,
       coalesce(replay_lag::text, '-')                               AS replay_lag
FROM pg_stat_replication
ORDER BY application_name;

\echo '-- pg_replication_slots (WAL the primary is keeping for each replica)'
SELECT slot_name,
       active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained
FROM pg_replication_slots
ORDER BY slot_name;

SELECT current_setting('synchronous_standby_names') AS synchronous_standby_names,
       current_setting('synchronous_commit')        AS synchronous_commit;
