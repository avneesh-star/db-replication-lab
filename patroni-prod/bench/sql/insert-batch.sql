-- :batch rows in ONE statement and ONE transaction, so one commit (one WAL flush, one standby wait) covers them all.
INSERT INTO links_bench (short_code, long_url, idempotency_key) SELECT gen_random_uuid()::text, 'https://example.com/x', gen_random_uuid()::text FROM generate_series(1, :batch);
