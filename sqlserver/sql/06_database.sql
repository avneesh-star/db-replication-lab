-- Run on sql1. Creates the database, then adds it to the availability group;
-- automatic seeding copies it to sql2 and sql3 and keeps them in sync.
USE master;
GO
CREATE DATABASE labdb;
GO
-- Availability groups need the full recovery model (every change is logged
-- and kept until shipped) and at least one full backup before joining.
ALTER DATABASE labdb SET RECOVERY FULL;
GO
USE labdb;
GO
CREATE TABLE dbo.links (
    id          bigint IDENTITY PRIMARY KEY,
    short_code  nvarchar(64)   NOT NULL UNIQUE,
    long_url    nvarchar(2048) NOT NULL,
    created_at  datetime2(6)   NOT NULL DEFAULT SYSUTCDATETIME()
);
-- A single row the primary keeps updating; a secondary's copy shows how far behind it is.
CREATE TABLE dbo.heartbeat (
    id  int          PRIMARY KEY,
    ts  datetime2(6) NOT NULL
);
INSERT INTO dbo.heartbeat VALUES (1, SYSUTCDATETIME());
INSERT INTO dbo.links (short_code, long_url)
SELECT TOP (1000) CONCAT(N'seed', n), CONCAT(N'https://example.com/seed/', n)
FROM (SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n FROM sys.all_objects) AS t;
GO
USE master;
GO
BACKUP DATABASE labdb TO DISK = N'/var/opt/mssql/data/labdb.bak' WITH INIT;
GO
ALTER AVAILABILITY GROUP lab_ag ADD DATABASE labdb;
GO
