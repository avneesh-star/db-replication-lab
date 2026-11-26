-- Run on every instance. The endpoint is the TCP port replicas use to ship
-- log records to each other (the analogue of a Postgres walsender connection).
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints)
    CREATE ENDPOINT hadr_endpoint
        STATE = STARTED
        AS TCP (LISTENER_PORT = 5022)
        FOR DATABASE_MIRRORING (
            ROLE = ALL,
            AUTHENTICATION = CERTIFICATE ag_cert,
            ENCRYPTION = REQUIRED ALGORITHM AES);
GO
GRANT CONNECT ON ENDPOINT::hadr_endpoint TO dbm_login;
GO
