#!/bin/sh
# Runs once, on the first node, right after the cluster is initialised.
# Patroni passes a connection string as $1. Replicas copy everything from this node.
set -e
psql "$1" -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE DATABASE lab;
\connect lab
CREATE TABLE failover_test (id serial PRIMARY KEY, note text, written_at timestamptz DEFAULT now());
SQL
