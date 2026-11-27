-- One row per transaction, like one API POST: random unique code and idempotency key.
INSERT INTO links_bench (short_code, long_url, idempotency_key) VALUES (gen_random_uuid()::text, 'https://example.com/x', gen_random_uuid()::text);
