-- Run on the primary. Everything here reaches the replicas through the WAL,
-- including the DDL: replicas get no SQL of their own.

CREATE TABLE IF NOT EXISTS links (
    id          bigserial   PRIMARY KEY,
    short_code  text        NOT NULL UNIQUE,
    long_url    text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- A single row the primary keeps updating; a replica's copy shows how far behind it is.
CREATE TABLE IF NOT EXISTS heartbeat (
    id  int         PRIMARY KEY,
    ts  timestamptz NOT NULL
);
INSERT INTO heartbeat VALUES (1, clock_timestamp())
ON CONFLICT (id) DO UPDATE SET ts = EXCLUDED.ts;

INSERT INTO links (short_code, long_url)
SELECT 'seed' || g, 'https://example.com/seed/' || g
FROM generate_series(1, 1000) AS g
ON CONFLICT (short_code) DO NOTHING;

-- Results of the commit-mode probe (03_commit_modes.sql).
CREATE TABLE IF NOT EXISTS probe_results (
    mode            text    PRIMARY KEY,
    commits         int     NOT NULL,
    avg_commit_ms   numeric NOT NULL,
    p95_commit_ms   numeric NOT NULL,
    missed_on_sync  int     NOT NULL,
    missed_on_async int     NOT NULL,
    sync_visible_p95_ms  numeric NOT NULL,
    async_visible_p95_ms numeric NOT NULL
);
