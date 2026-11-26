-- Run on a replica: its own view of replication.
--   received: WAL position streamed from the primary and written locally.
--   replayed: WAL position applied to the tables; reads see data up to here.
--   replay_queue: received but not yet applied.
SELECT pg_is_in_recovery()                                                   AS is_replica,
       pg_last_wal_receive_lsn()                                             AS received,
       pg_last_wal_replay_lsn()                                              AS replayed,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                                      pg_last_wal_replay_lsn()))             AS replay_queue,
       (SELECT round(extract(epoch FROM clock_timestamp() - ts) * 1000)
        FROM heartbeat WHERE id = 1)                                         AS heartbeat_age_ms,
       (SELECT count(*) FROM links)                                          AS links;
