# Patroni lab: automatic PostgreSQL failover

A three-node PostgreSQL cluster that elects its own leader and recovers from a dead primary without anyone running `pg_promote()`.

```
                       app / pgAdmin
                    |                  |
        :5450 (writes)            :5451 (reads)
                    |                  |
                 +--------- HAProxy ---------+     :7000 stats page
                 | checks each node's REST API |
                 +-----+-------+-------+-----+
                       |       |       |
                  pg-node1 pg-node2 pg-node3      Postgres + Patroni each
                       \       |       /
                            etcd                  holds the leader lock

                  dashboard  :8088                web UI to test failover
```

- **etcd** stores the leader lock. The node that holds it is the primary.
- **Patroni** runs next to each Postgres. It renews the lock while healthy. If the leader stops renewing, a replica takes the lock and is promoted.
- **HAProxy** asks each node `GET /primary` and `GET /replica` on port 8008. Port 5000 goes only to the node answering 200 on `/primary`. Port 5001 goes to the nodes answering 200 on `/replica`.
- **Dashboard** shows the cluster, runs a write test, and has Stop/Start buttons for each node.

## Requirements

Docker Desktop, running. Nothing else is installed on the host.

## Start

```bash
docker compose up -d --build
docker compose ps          # wait until the three pg-node containers show (healthy)
```

The first start takes a minute or two: one node initialises the cluster, the other two clone it.

Reset everything, including data: `docker compose down -v`

## Ports

| What | Host address | Notes |
|---|---|---|
| Write endpoint (primary) | `localhost:5450` | always the current leader |
| Read endpoint (replicas) | `localhost:5451` | round robin over healthy replicas |
| Dashboard | http://localhost:8088 | |
| HAProxy stats | http://localhost:7000 | green row = node HAProxy sends traffic to |
| Patroni REST, node1/2/3 | `localhost:8101` / `8102` / `8103` | e.g. `/cluster`, `/primary`, `/replica` |

Database `lab`, user `postgres`, password `postgres`. The table `failover_test` is created at bootstrap.

If you also have PostgreSQL installed on the host, it keeps port 5432 and these ports avoid it. If something else already uses one of these ports, change the left side of the mapping in `docker-compose.yml`.

## Connecting from pgAdmin

Register two servers, both with maintenance database `lab`, user `postgres`, password `postgres` (tick **Save password**):

- `localhost:5450` for writes
- `localhost:5451` for reads

Do not register the individual nodes. They are not published, and the point is that the app never needs to know which node is the leader.

## Try failover

### With the dashboard (easiest)

1. Open http://localhost:8088 and click **Start write test**.
2. Click **Stop** on the node marked `leader`.
3. Writes fail for roughly 20-25 seconds, a replica becomes leader, writes resume. The outage timer shows the gap.
4. Click **Start** on the stopped node. It rejoins as a replica.

### With the script

```bash
bash failover-demo.sh
```

It shows the cluster, writes through :5000, reads through :5001, stops the leader, retries writes until they succeed (printing the elapsed time), shows the new leader, then restarts the old leader and shows it rejoining as a replica.

### By hand

```bash
# who is the leader?
docker compose exec pg-node1 patronictl -c /config/patroni.yml list

# kill it
docker compose stop pg-node1        # use whichever node is the leader

# watch it recover
docker compose exec pg-node2 patronictl -c /config/patroni.yml list
```

In Git Bash on Windows, prefix `docker compose exec` commands with `MSYS_NO_PATHCONV=1`, or Git Bash rewrites `/config/...` into a Windows path.

## More things to practice

| Goal | Command |
|---|---|
| Planned switchover to a chosen node | `patronictl -c /config/patroni.yml switchover` |
| Show / edit cluster-wide settings | `patronictl -c /config/patroni.yml show-config` / `edit-config` |
| Stop losing recent commits on failover | `edit-config`, set `synchronous_mode: true` |
| Re-initialise a broken replica | `patronictl -c /config/patroni.yml reinit lab-cluster pg-node3` |
| Stop etcd (see what Patroni does with no lock store) | `docker compose stop etcd` |

Run all `patronictl` commands as `docker compose exec <node> patronictl -c /config/patroni.yml ...`.

Things worth observing:

- **Async data loss window.** With the default async replication, a commit the leader acknowledged but had not yet sent to a replica is lost if the leader dies at that moment. `synchronous_mode: true` closes this gap at the cost of commit latency.
- **Stopping etcd.** Without the lock store, the leader cannot renew its lock. Patroni demotes it to read-only to avoid split-brain, even though Postgres itself is healthy.
- **Stopping two nodes.** The lone survivor can still lead only if it can reach etcd. etcd is a single node here, so it is a single point of failure; production runs three.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | etcd, three Patroni nodes, HAProxy, dashboard |
| `Dockerfile` | Postgres 16 image with Patroni installed in a virtualenv |
| `config/patroni.yml` | shared Patroni config: timings, replication user, `pg_rewind`, slots |
| `config/post_bootstrap.sh` | creates the `lab` database and `failover_test` table once |
| `config/haproxy.cfg` | health-check routing for ports 5000 and 5001 |
| `dashboard/` | the web dashboard (Python backend, single HTML page) |
| `failover-demo.sh` | scripted failover walkthrough |

## Key settings (`config/patroni.yml`)

- `ttl: 20`: if the leader fails to renew its lock for 20 seconds, it is considered dead. This is the main part of the failover time.
- `loop_wait: 5`, `retry_timeout: 5`: Patroni checks every 5 seconds. Keep `loop_wait + 2 * retry_timeout <= ttl`.
- `maximum_lag_on_failover: 1048576`: a replica more than 1 MB behind is not promoted.
- `use_pg_rewind: true` with `wal_log_hints` and data checksums: the old leader can rejoin as a replica instead of needing a fresh clone.
- `use_slots: true`: the leader keeps WAL for each replica, so a stopped replica can catch up.

Lowering `ttl` makes failover faster but makes a brief network blip more likely to trigger one. Production commonly uses 30 seconds.

## Troubleshooting

- **A node stays `creating replica`.** Wait a minute; it is cloning. If it never completes, check `docker compose logs pg-node2`.
- **pgAdmin says `no password supplied`.** Enter the password and tick **Save password** in the server's connection settings.
- **pgAdmin keeps showing a dead connection after failover.** Disconnect and reconnect the server; pooled connections do not always recover.
- **`Provided config file C:/Program Files/Git/...` error.** Git Bash path rewriting; use `MSYS_NO_PATHCONV=1`.
- **Dashboard port in use.** It uses 8088 because 8080 is commonly taken. Change the mapping in `docker-compose.yml` if needed.

## Security note

The dashboard mounts the Docker socket so its buttons can stop and start containers, and it has no login. Passwords here are lab defaults. Use this only on your own machine.
