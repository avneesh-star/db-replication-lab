#!/bin/bash
# Takes a compressed base backup from a REPLICA (through the read endpoint), so the
# primary carries no backup load. Together with the WAL in /archive it allows
# point-in-time recovery.
#
#   docker compose run --rm backup
set -euo pipefail
dest="/backups/base-$(date -u +%Y%m%dT%H%M%SZ)"
echo "Backing up from a replica via haproxy1:5001 into $dest"
PGPASSWORD="$REPLICATION_PASSWORD" pg_basebackup \
  -h haproxy1 -p 5001 -U replicator \
  -D "$dest" -Ft -z -X fetch -c fast --checkpoint=fast -P
echo
echo "Backup written:"
ls -lh "$dest"
echo
echo "WAL segments archived so far: $(ls /archive | grep -vc history || true)"
