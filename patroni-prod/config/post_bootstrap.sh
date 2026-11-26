#!/bin/sh
# Runs once on the first node. Creates the application database, the schema, and a
# least-privilege role for the app. Replicas copy all of this.
# Patroni passes a connection string as $1. APP_DB_PASSWORD comes from the environment.
set -e
psql "$1" -X -v ON_ERROR_STOP=1 -v app_pw="$APP_DB_PASSWORD" -v monitor_pw="$MONITOR_PASSWORD" <<'SQL'
CREATE DATABASE lab;
CREATE ROLE app_user LOGIN PASSWORD :'app_pw';
-- Read-only access to statistics for the metrics exporter; no access to table data.
CREATE ROLE monitor LOGIN PASSWORD :'monitor_pw' IN ROLE pg_monitor;
\connect lab

-- The application owns no objects and cannot run DDL: only data access.
REVOKE ALL ON DATABASE lab FROM PUBLIC;
GRANT CONNECT ON DATABASE lab TO app_user, monitor;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_user;

CREATE TABLE links (
    id              bigserial PRIMARY KEY,
    short_code      text NOT NULL UNIQUE,
    long_url        text NOT NULL,
    idempotency_key text UNIQUE,
    created_at      timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON links TO app_user;
GRANT USAGE, SELECT ON SEQUENCE links_id_seq TO app_user;
SQL
