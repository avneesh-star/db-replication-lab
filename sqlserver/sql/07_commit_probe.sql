-- Run on sql1 (the primary). Creates linked servers to both secondaries and a
-- procedure that commits inserts one at a time, then asks each secondary
-- whether it can see the new row, and keeps asking every millisecond until it
-- can: the read-after-write problem. The same experiment as the Postgres lab's
-- 03_commit_modes.sql.
--
--   missed      the row was not visible on the first read after COMMIT returned
--   visible p95 95% of rows were readable on that secondary within this time
--
-- SQL Server has no equivalent of Postgres's remote_apply: a synchronous
-- commit waits for the secondary to harden the log, not to redo it, so even a
-- synchronous secondary can briefly lag for reads.
USE master;
GO
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'SQL2_LINK')
BEGIN
    EXEC sp_addlinkedserver @server = N'SQL2_LINK', @srvproduct = N'', @provider = N'MSOLEDBSQL',
        @datasrc = N'sql2', @provstr = N'TrustServerCertificate=yes;';
    EXEC sp_addlinkedsrvlogin @rmtsrvname = N'SQL2_LINK', @useself = N'FALSE',
        @rmtuser = N'sa', @rmtpassword = N'Lab_Passw0rd!';
END
IF NOT EXISTS (SELECT 1 FROM sys.servers WHERE name = N'SQL3_LINK')
BEGIN
    EXEC sp_addlinkedserver @server = N'SQL3_LINK', @srvproduct = N'', @provider = N'MSOLEDBSQL',
        @datasrc = N'sql3', @provstr = N'TrustServerCertificate=yes;';
    EXEC sp_addlinkedsrvlogin @rmtsrvname = N'SQL3_LINK', @useself = N'FALSE',
        @rmtuser = N'sa', @rmtpassword = N'Lab_Passw0rd!';
END
GO
CREATE OR ALTER PROCEDURE dbo.probe_commits @setup nvarchar(60), @n int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @i int = 0, @code nvarchar(64), @t0 datetime2(7), @t1 datetime2(7), @seen int,
            @first bit, @miss2 int = 0, @miss3 int = 0, @server sysname, @k int;
    DECLARE @commit TABLE (us float);
    DECLARE @visible TABLE (server sysname, us float);

    WHILE @i < @n
    BEGIN
        SET @i += 1;
        SET @code = CONCAT(N'probe-', @i, N'-', ABS(CHECKSUM(NEWID())));
        SET @t0 = SYSDATETIME();
        -- Autocommit: the INSERT is its own transaction and returns after commit.
        INSERT INTO labdb.dbo.links (short_code, long_url) VALUES (@code, N'https://example.com/' + @code);
        SET @t1 = SYSDATETIME();
        INSERT INTO @commit VALUES (DATEDIFF_BIG(microsecond, @t0, @t1));

        SET @k = 2;
        WHILE @k <= 3
        BEGIN
            SET @first = 1;
            SET @t1 = SYSDATETIME();
            WHILE 1 = 1
            BEGIN
                IF @k = 2 SELECT @seen = COUNT(*) FROM SQL2_LINK.labdb.dbo.links WHERE short_code = @code;
                ELSE      SELECT @seen = COUNT(*) FROM SQL3_LINK.labdb.dbo.links WHERE short_code = @code;
                IF @seen = 0 AND @first = 1
                BEGIN
                    IF @k = 2 SET @miss2 += 1; ELSE SET @miss3 += 1;
                END
                SET @first = 0;
                IF @seen > 0 OR DATEDIFF(millisecond, @t1, SYSDATETIME()) > 2000 BREAK;
                WAITFOR DELAY '00:00:00.001';
            END
            INSERT INTO @visible VALUES (CONCAT(N'sql', @k), DATEDIFF_BIG(microsecond, @t1, SYSDATETIME()));
            SET @k += 1;
        END
    END

    DECLARE @avg float, @p95 float, @v2 float, @v3 float;
    SELECT TOP (1) @avg = AVG(us) OVER (), @p95 = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY us) OVER () FROM @commit;
    SELECT TOP (1) @v2 = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY us) OVER () FROM @visible WHERE server = N'sql2';
    SELECT TOP (1) @v3 = PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY us) OVER () FROM @visible WHERE server = N'sql3';

    SELECT CAST(@setup AS varchar(26))                                     AS setup,
           @n                                                              AS commits,
           CAST(@avg / 1000 AS decimal(8, 2))                              AS avg_commit_ms,
           CAST(@p95 / 1000 AS decimal(8, 2))                              AS p95_commit_ms,
           CAST(CONCAT(100 * @miss2 / @n, '%') AS varchar(5))              AS sql2_missed,
           CAST(@v2 / 1000 AS decimal(8, 2))                               AS sql2_visible_p95_ms,
           CAST(CONCAT(100 * @miss3 / @n, '%') AS varchar(5))              AS sql3_missed,
           CAST(@v3 / 1000 AS decimal(8, 2))                               AS sql3_visible_p95_ms;
END
GO
