-- Run on the primary, with replica_sync configured as the synchronous standby.
--
-- For each synchronous_commit mode, commits :n inserts one at a time. After
-- each commit it asks both replicas (over persistent dblink connections)
-- whether they can see the new row, and keeps asking every millisecond until
-- they can. That is the read-after-write problem: a client writes, then reads
-- from a replica.
--
--   local         commit waits for the primary's own disk only
--   remote_write  ...and for the sync replica to receive the WAL (in memory)
--   on            ...and for the sync replica to flush it to disk
--   remote_apply  ...and for the sync replica to replay it (visible to reads)
--
--   missed        not visible on the first read after COMMIT returned
--   visible p95   95% of rows were readable on that replica within this time

CREATE OR REPLACE FUNCTION wait_visible(conn text, code text, OUT missed boolean, OUT ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    t0   timestamptz := clock_timestamp();
    seen int;
BEGIN
    missed := false;
    LOOP
        SELECT c INTO seen FROM dblink(conn,
            format('SELECT count(*)::int FROM links WHERE short_code = %L', code)) AS t(c int);
        EXIT WHEN seen > 0 OR clock_timestamp() - t0 > interval '2 seconds';
        missed := true;
        PERFORM pg_sleep(0.001);
    END LOOP;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
END $$;

CREATE OR REPLACE PROCEDURE probe_commit_mode(p_mode text, p_n int)
LANGUAGE plpgsql AS $$
DECLARE
    code    text;
    t0      timestamptz;
    commits numeric[] := '{}';
    vis_s   numeric[] := '{}';
    vis_a   numeric[] := '{}';
    miss_s  int := 0;
    miss_a  int := 0;
    r       record;
BEGIN
    PERFORM dblink_connect('rsync',
        'host=pg-replica-sync dbname=lab user=postgres password=postgres');
    PERFORM dblink_connect('rasync',
        'host=pg-replica-async dbname=lab user=postgres password=postgres');

    FOR i IN 1..p_n LOOP
        code := p_mode || '-' || i || '-' || floor(random() * 1e9)::bigint;
        -- Applies to this transaction only.
        PERFORM set_config('synchronous_commit', p_mode, true);
        t0 := clock_timestamp();
        INSERT INTO links (short_code, long_url) VALUES (code, 'https://example.com/' || code);
        COMMIT;
        commits := commits || (extract(epoch FROM clock_timestamp() - t0) * 1000)::numeric;

        SELECT * INTO r FROM wait_visible('rsync', code);
        IF r.missed THEN miss_s := miss_s + 1; END IF;
        vis_s := vis_s || r.ms;
        SELECT * INTO r FROM wait_visible('rasync', code);
        IF r.missed THEN miss_a := miss_a + 1; END IF;
        vis_a := vis_a || r.ms;
    END LOOP;

    PERFORM dblink_disconnect('rsync');
    PERFORM dblink_disconnect('rasync');

    INSERT INTO probe_results
    SELECT p_mode, p_n,
           (SELECT round(avg(x), 2) FROM unnest(commits) x),
           (SELECT round(percentile_cont(0.95) WITHIN GROUP (ORDER BY x)::numeric, 2) FROM unnest(commits) x),
           miss_s, miss_a,
           (SELECT round(percentile_cont(0.95) WITHIN GROUP (ORDER BY x)::numeric, 2) FROM unnest(vis_s) x),
           (SELECT round(percentile_cont(0.95) WITHIN GROUP (ORDER BY x)::numeric, 2) FROM unnest(vis_a) x)
    ON CONFLICT (mode) DO UPDATE SET
        commits = EXCLUDED.commits, avg_commit_ms = EXCLUDED.avg_commit_ms,
        p95_commit_ms = EXCLUDED.p95_commit_ms, missed_on_sync = EXCLUDED.missed_on_sync,
        missed_on_async = EXCLUDED.missed_on_async,
        sync_visible_p95_ms = EXCLUDED.sync_visible_p95_ms,
        async_visible_p95_ms = EXCLUDED.async_visible_p95_ms;
    COMMIT;
END $$;

TRUNCATE probe_results;
CALL probe_commit_mode('local',        :n);
CALL probe_commit_mode('remote_write', :n);
CALL probe_commit_mode('on',           :n);
CALL probe_commit_mode('remote_apply', :n);

\echo '-- Commit latency and read-after-write per synchronous_commit mode'
SELECT mode, commits, avg_commit_ms, p95_commit_ms,
       round(100.0 * missed_on_sync  / commits) || '%' AS sync_missed,
       sync_visible_p95_ms,
       round(100.0 * missed_on_async / commits) || '%' AS async_missed,
       async_visible_p95_ms
FROM probe_results
ORDER BY array_position(ARRAY['local', 'remote_write', 'on', 'remote_apply'], mode);
