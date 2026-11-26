# patroni-prod: a production-style PostgreSQL HA cluster

The same idea as `../patroni`, built the way a real deployment is shaped: no single point of failure in the control plane, no data loss on failover, secrets out of config files, a locked-down application role, backups, and monitoring.

It runs on one Docker host, so it shows the architecture and the failure behaviour, not real hardware or network separation. See [What this is not](#what-this-is-not).

```
                    .NET API  (least-privilege role "app_user")
                        |  Host=haproxy1,haproxy2  (driver tries the next one if a host is down)
              +---------+---------+
              v                   v
          haproxy1            haproxy2          :5000 -> the primary    :5001 -> replicas
              \                   /             each checks Patroni's REST API on every node
               +--------+--------+
                        v
        pg-node1     pg-node2     pg-node3      Postgres 16 + Patroni, synchronous replication
            \            |            /         WAL archived to a shared volume
             +-----------+-----------+
                         |
              etcd1    etcd2    etcd3           leader lock; needs 2 of 3 for quorum

   Prometheus  <- Patroni, etcd, HAProxy, postgres-exporter      Grafana dashboard + alert rules
   backup job  -> base backup taken from a replica
```

## What is different from `../patroni`

| Area | Dev lab | This lab |
|---|---|---|
| etcd | 1 node | **3 nodes**: survives losing one |
| HAProxy | 1 | **2**: the API lists both, so one failing is not an outage |
| Replication | async | **synchronous** (`synchronous_mode`, 1 sync standby): an acknowledged commit exists on two nodes |
| Passwords | in config files | **`.env`**, passed as environment variables; none in the YAML |
| Authentication | md5 | **scram-sha-256** |
| App database role | superuser | **`app_user`**: can read and write rows, cannot change the schema |
| Monitoring role | none | **`monitor`**: `pg_monitor` only, no table access |
| Database ports | published | **not published**: reachable only through HAProxy |
| Failover timing | `ttl` 20 s | `ttl` 30 s, `loop_wait` 10 s (typical production values) |
| Backups | none | **WAL archiving + base backups from a replica** |
| Monitoring | HAProxy stats page | **Prometheus, Grafana dashboard, alert rules** |
| Containers | no limits | CPU and memory limits, `restart: unless-stopped`, `stop_grace_period` |
| HAProxy read balancing | round robin | `leastconn` |

## Requirements

Docker Desktop, running. About 4 GB of free memory for the whole stack. If the dev lab (`../patroni`) is also running, that is a lot of containers; stop one lab first with `docker compose down`.

## Start

```bash
cp .env.example .env         # then replace every "change-me" (this repo's .env already has random lab values)
docker compose up -d --build
docker compose ps            # wait until the three pg-node containers are (healthy)
```

The first start takes a few minutes: one node initialises the cluster, the others clone it, and the images build.

Reset everything, including data and backups: `docker compose down -v`

## Addresses

| What | Address | Notes |
|---|---|---|
| Primary via HAProxy 1 / 2 | `localhost:5460` / `localhost:5462` | always the current leader |
| Replicas via HAProxy 1 / 2 | `localhost:5461` / `localhost:5463` | healthy replicas, `leastconn` |
| HAProxy stats | http://localhost:7001 / http://localhost:7002 | which nodes each HAProxy sends traffic to |
| **Grafana** | http://localhost:3001 | user `admin`, password `GRAFANA_PASSWORD` from `.env` |
| Prometheus | http://localhost:9090 | `/alerts` shows alert rules and state |
| .NET API | http://localhost:5101 | see `../dotnet/README.md` |

Postgres users and where their passwords live:

| User | Purpose | Password in `.env` |
|---|---|---|
| `postgres` | superuser, for administration | `POSTGRES_PASSWORD` |
| `replicator` | replication and backups | `REPLICATION_PASSWORD` |
| `app_user` | the application | `APP_DB_PASSWORD` |
| `monitor` | metrics exporter | `MONITOR_PASSWORD` |
| `patroni` | Patroni REST API actions (switchover, restart) | `PATRONI_API_PASSWORD` |

Connect with pgAdmin to `localhost:5460` (database `lab`, user `postgres`). Connect as `app_user` to see what the application can and cannot do: `CREATE TABLE` fails.

## Use it

### Check the cluster

```bash
MSYS_NO_PATHCONV=1 docker compose exec pg-node1 patronictl -c /config/patroni.yml list
```

In Git Bash on Windows, keep `MSYS_NO_PATHCONV=1` or `/config/...` is rewritten into a Windows path.

You should see one `Leader`, one `Sync Standby` and one `Replica`.

### Send traffic

```bash
curl -X POST localhost:5101/links -H 'Content-Type: application/json' \
     -H 'Idempotency-Key: demo-1' -d '{"url":"https://example.com/hello"}'
curl localhost:5101/health/db
```

### The Grafana dashboard

Open http://localhost:3001. Top to bottom:

1. **Cluster at a glance:** primaries (must be exactly 1), sync standbys, replicas, etcd members up, HAProxy up, timeline, firing alerts. Red means act.
2. **Node roles:** a tile per node (PRIMARY, SYNC STANDBY, REPLICA, DOWN) and a role history timeline. This is where you watch the primary move during a failover.
3. **Roles and replication:** primary per node, replication lag in bytes, streaming state, timeline.
4. **HAProxy:** which servers each HAProxy considers up, and sessions per server.
5. **PostgreSQL:** transactions per second, connections by state, cache hit ratio, database size, WAL archiving, inserts per second.
6. **etcd:** members with a leader, leader changes, WAL fsync latency.
7. **Alerts:** anything currently firing.

### Run the failover test

```bash
bash failover-test.sh            # graceful stop of the primary
KILL=1 bash failover-test.sh     # crash (SIGKILL), the realistic case
```

It writes through the API twice a second, takes down the primary after about 5 seconds, then reports acknowledged writes, failed writes, the new primary, and whether every acknowledged write is in the database.

Measured results on this machine:

| Run | Writes acknowledged | Client errors | Rows present | Longest write |
|---|---|---|---|---|
| Graceful stop | 77 | 1 (a bug in the retry code, since fixed) | 77 | not recorded |
| Crash (`KILL=1`) | 49 | 0 | 49 | 35 s (13 attempts) |
| Crash (`KILL=1`), second run | 57 | 0 | 57 | 29 s (10 attempts) |

The crash case is slower because a killed leader cannot release its lock, so Patroni waits out the full `ttl`. A graceful stop releases the lock and the standby is promoted within seconds.

Watch the dashboard while it runs. Known limitation: the "NoPrimary alert fired" line the script prints is unreliable, because the script only checks between writes and writes are blocked during the outage. Check http://localhost:9090/alerts instead.

### Other failures worth trying

```bash
bash failure-tests.sh        # about 6 minutes; restores everything it breaks
```

Results from running it on this stack (writes go through the .NET API):

| Failure | Observed |
|---|---|
| `docker compose kill haproxy1` | 10 of 10 writes succeeded through `haproxy2`, reads worked, `HaproxyDown` fired. After restarting `haproxy1`, 10 of 10 writes succeeded |
| `docker compose stop etcd3` (2 of 3 left) | 10 of 10 writes succeeded, roles unchanged (same primary), `EtcdMemberDown` fired |
| also stop `etcd2` (no quorum) | writes worked for about 10 s, then began timing out. About 20 s in, the API returned a 500. All three nodes reported `replica`: the leader was **demoted to read-only** because it could not renew its lock, even though Postgres was healthy. `EtcdNoLeader` fired. Writes stayed down for the whole outage (about 160 s in this run) |
| restore `etcd2` and `etcd3` | writes succeeded **6 s** after quorum returned, with the **same** primary (pg-node2); no failover was needed |

Reading these results:

- Losing one HAProxy or one etcd member is invisible to clients. That is what the second HAProxy and the third etcd member buy you.
- Losing etcd quorum is a full write outage, even though every Postgres node is up. Patroni prefers refusing writes to risking two primaries. The dashboard's role tiles all turn to REPLICA, and `NoPrimary` and `EtcdNoLeader` fire.
- Because each probe used a 4 s client timeout, the `HTTP 000` lines are client timeouts, not server errors. The API was retrying inside its 60 s window.

Not run on this stack: stopping the sync standby, `patronictl switchover`, and restoring from a backup. Expected behaviour for the first two, from how Patroni works: `NoSynchronousStandby` fires and Patroni promotes the other replica to sync standby; a switchover is a planned, near-instant leader change.

## Backups

WAL archiving is on: every completed WAL segment is copied to the `wal-archive` volume (a stand-in for S3 or GCS), and a base backup is taken on demand from a **replica**, so the primary carries no backup load.

```bash
docker compose run --rm backup
```

Tested: it wrote a compressed base backup (about 4 MB) into the `backups` volume and reported the number of archived WAL segments.

What is **not** built: automated restore, scheduled backups, retention, and verification. The pieces for point-in-time recovery exist (a base backup plus the WAL archive and a `restore_command`), but I have not tested a restore. Treat a backup you have not restored as unproven. In production, use pgBackRest or WAL-G with object storage, which handle scheduling, retention, encryption and restore.

The WAL archive grows without limit in this lab.

## Alerts

Rules are in `prometheus/alerts.yml`:

| Alert | Fires when |
|---|---|
| `NoPrimary` | no node is primary for 20 s |
| `SplitBrain` | more than one node is primary |
| `PatroniNodeDown` / `PostgresNotRunning` | a node stops responding for 15 s |
| `NoSynchronousStandby` | no sync standby for 30 s: a failover now could lose commits |
| `EtcdNoLeader` / `EtcdMemberDown` | etcd member lost its leader, or is down |
| `HaproxyDown` | an HAProxy instance is down |

There is no Alertmanager, so alerts only appear in Prometheus and in the dashboard's alerts table. In production, add Alertmanager and route them to a pager.

## Things that will trip you up

- **Changing environment variables restarts the database nodes.** `docker compose up -d` recreates any container whose config changed, which can trigger a failover.
- **Prometheus does not reload its config on its own.** After editing `prometheus.yml` or `alerts.yml`, run `docker compose restart prometheus`.
- **`REVOKE ALL ON DATABASE lab FROM PUBLIC` is in `post_bootstrap.sh`**, so every role that needs access needs an explicit `GRANT CONNECT`. A role without it fails with "permission denied for database". `post_bootstrap.sh` only runs when the cluster is first created, so a change there needs `docker compose down -v` to take effect.
- **Long writes during failover.** The API retries for up to 60 s, so a write caught in a crash can hold its HTTP request open for 30 s or more. Clients and load balancers in front of it need timeouts longer than that, or the client sees an error even though the write succeeds.
- **etcd is the weak link.** If it loses quorum, healthy Postgres nodes are demoted to read-only. Keep its disks fast; the dashboard shows etcd fsync latency for this reason.

## What this is not

- **Not geographically separated.** All nodes share one Docker host. A real deployment spreads Postgres and etcd nodes across availability zones.
- **No TLS.** Traffic between app, HAProxy, Postgres, etcd and Patroni is unencrypted. Production needs TLS on all of it.
- **No connection pooler.** Put PgBouncer between the app and HAProxy once you have many clients, since Postgres handles thousands of connections poorly.
- **No Alertmanager, log aggregation or tracing.**
- **Backups are on the same host** as the data they protect, and restore is untested.
- **Secrets are in a `.env` file.** Use a secret manager.
- **The Postgres exporter connects through HAProxy to the primary**, so it reports on the primary only, not on replicas.

## Files

| Path | Purpose |
|---|---|
| `docker-compose.yml` | the whole stack |
| `.env` / `.env.example` | secrets (lab values / template) |
| `config/patroni.yml` | Patroni and PostgreSQL settings: timings, sync mode, archiving, authentication |
| `config/post_bootstrap.sh` | creates the database, schema and the `app_user` and `monitor` roles |
| `config/haproxy.cfg` | health-checked routing for :5000 and :5001, plus metrics on :8405 |
| `prometheus/prometheus.yml`, `alerts.yml` | scrape targets and alert rules |
| `grafana/provisioning/` | data source and dashboard loader |
| `grafana/dashboards/postgres-ha.json` | the dashboard (generated by a script; edit the JSON or Grafana's UI copy) |
| `scripts/backup.sh` | base backup from a replica |
| `failover-test.sh` | primary failure test (graceful stop, or crash with `KILL=1`) |
| `failure-tests.sh` | HAProxy loss, etcd member loss, and etcd quorum loss |
