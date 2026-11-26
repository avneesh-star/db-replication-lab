#!/bin/sh
# Runs once, when the primary's data directory is first created.

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<'SQL'
-- The account replicas connect as. REPLICATION lets it stream WAL; it can't read tables.
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pw';

-- One slot per replica. A slot makes the primary keep WAL until that replica
-- has received it, so a replica that is down for a while can catch up instead
-- of needing a fresh copy. "true" reserves WAL from now, before first use.
SELECT pg_create_physical_replication_slot('slot_replica_sync', true);
SELECT pg_create_physical_replication_slot('slot_replica_async', true);

-- Lets one session on the primary query the replicas, to test read-after-write.
CREATE EXTENSION IF NOT EXISTS dblink;
SQL

# Replication connections need their own pg_hba line: "all" doesn't cover them.
echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"
