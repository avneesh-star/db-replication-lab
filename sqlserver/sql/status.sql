-- Run on the primary: what it knows about each replica.
--   connected     whether the replica's log-shipping session is up
--   sync_state    SYNCHRONIZED: a sync replica that has hardened all log
--                 SYNCHRONIZING: catching up, or async (async never reports SYNCHRONIZED)
--   send_queue_kb log the primary has not yet sent to the replica
--   redo_queue_kb log the replica has received but not yet applied (redone)
--   lag_s         how far behind the replica's applied data is, in seconds
SET NOCOUNT ON;
SELECT CAST(ar.replica_server_name AS varchar(8))           AS replica,
       CAST(ars.role_desc AS varchar(10))                   AS role,
       CAST(ar.availability_mode_desc AS varchar(20))       AS commit_mode,
       CAST(ars.connected_state_desc AS varchar(13))        AS connected,
       CAST(drs.synchronization_state_desc AS varchar(18))  AS sync_state,
       drs.log_send_queue_size                              AS send_queue_kb,
       drs.redo_queue_size                                  AS redo_queue_kb,
       drs.secondary_lag_seconds                            AS lag_s
FROM sys.availability_replicas AS ar
JOIN sys.dm_hadr_availability_replica_states AS ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_database_replica_states AS drs
       ON drs.replica_id = ar.replica_id AND drs.database_id = DB_ID('labdb')
ORDER BY ar.replica_server_name;
