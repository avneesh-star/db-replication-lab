#!/bin/sh
# Turns an empty data directory into a streaming replica of $PRIMARY_HOST, then
# runs it as a hot standby (it replays the primary's WAL and serves reads).
set -eu
export PGPASSWORD=replicator_pw

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "replica $APP_NAME: waiting for $PRIMARY_HOST"
  until pg_isready -h "$PRIMARY_HOST" -U replicator -q; do sleep 1; done

  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA"
  chmod 700 "$PGDATA"

  # 1. Copy the primary's data files, streaming the WAL written during the copy
  #    so the result is consistent. The slot keeps that WAL on the primary.
  echo "replica $APP_NAME: cloning $PRIMARY_HOST"
  su-exec postgres pg_basebackup -h "$PRIMARY_HOST" -U replicator -D "$PGDATA" \
    -X stream -S "$SLOT_NAME" -c fast

  # 2. standby.signal makes the server start in recovery and stay there,
  #    continuously replaying WAL instead of becoming a second primary.
  su-exec postgres touch "$PGDATA/standby.signal"

  # 3. Where to stream WAL from. application_name is how the primary's
  #    synchronous_standby_names refers to this replica.
  cat >> "$PGDATA/postgresql.auto.conf" <<EOF
primary_conninfo = 'host=$PRIMARY_HOST port=5432 user=replicator password=replicator_pw application_name=$APP_NAME'
primary_slot_name = '$SLOT_NAME'
EOF
fi

# hot_standby: allow read-only queries during replay.
# hot_standby_feedback: tell the primary which rows replica queries still need,
# so vacuum on the primary doesn't cancel them.
exec su-exec postgres postgres -c hot_standby=on -c hot_standby_feedback=on
