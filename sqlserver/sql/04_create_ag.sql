-- Run on sql1. Creates the availability group with sql1 as primary,
-- sql2 as a synchronous-commit secondary and sql3 as asynchronous-commit.
--
--   SYNCHRONOUS_COMMIT   a commit on the primary waits until the secondary has
--                        hardened (written to disk) the log records
--   ASYNCHRONOUS_COMMIT  the primary ships log records without waiting
--   SEEDING_MODE = AUTOMATIC  the primary copies the database to the
--                        secondaries itself, no manual backup and restore
--   ALLOW_CONNECTIONS = ALL  secondaries accept read-only queries
USE master;
GO
CREATE AVAILABILITY GROUP lab_ag
    WITH (CLUSTER_TYPE = NONE)
    FOR REPLICA ON
        N'sql1' WITH (
            ENDPOINT_URL = N'tcp://sql1:5022',
            AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
            FAILOVER_MODE = MANUAL,
            SEEDING_MODE = AUTOMATIC,
            SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)),
        N'sql2' WITH (
            ENDPOINT_URL = N'tcp://sql2:5022',
            AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
            FAILOVER_MODE = MANUAL,
            SEEDING_MODE = AUTOMATIC,
            SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL)),
        N'sql3' WITH (
            ENDPOINT_URL = N'tcp://sql3:5022',
            AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
            FAILOVER_MODE = MANUAL,
            SEEDING_MODE = AUTOMATIC,
            SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL));
GO
-- Lets automatic seeding create the database on this replica after a failover.
ALTER AVAILABILITY GROUP lab_ag GRANT CREATE ANY DATABASE;
GO
