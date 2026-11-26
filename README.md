# Database replication and failover labs

Hands-on labs for understanding how databases replicate and fail over, built with Docker so each one runs on a laptop with one command. Every lab is scripted: you can watch a primary die, see which node takes over, and measure what clients experience.

| Lab | What it shows | Failover |
|---|---|---|
| [`postgres/`](postgres) | PostgreSQL streaming replication: one primary, a synchronous and an asynchronous replica, replication slots, lag under load, commit modes | manual |
| [`patroni/`](patroni) | A Patroni + etcd + HAProxy cluster, with a web dashboard to stop nodes and watch recovery | automatic |
| [`patroni-prod/`](patroni-prod) | A production-style version: 3 etcd, 2 HAProxy, synchronous replication, scram auth, least-privilege roles, WAL archiving, Prometheus and Grafana | automatic |
| [`sqlserver/`](sqlserver) | SQL Server Always On availability group: one primary and two readable secondaries (no cluster manager) | manual |
| [`dotnet/`](dotnet) | A .NET 10 API that uses the Patroni clusters: retries through failover, idempotent writes, replica reads with primary fallback | n/a |

## What the labs demonstrate

- **Synchronous vs asynchronous replication:** commit latency, read-after-write behaviour, and what is lost when a primary dies.
- **Failover:** promoting a replica by hand, then letting Patroni do it. Measured outage was about 30 seconds on a crash with a 30-second lock `ttl`, and no acknowledged write was lost with synchronous replication.
- **Control-plane failures:** losing one HAProxy or one etcd member is invisible to clients; losing etcd quorum makes the cluster refuse writes rather than risk two primaries.
- **Application side of failover:** retrying transient errors, making writes safe to repeat with idempotency keys, and falling back from replicas to the primary.
- **Operations:** WAL archiving, base backups from a replica, Prometheus alert rules, and a Grafana dashboard showing which node holds which role.

## Quick start

You need Docker Desktop. The labs use different ports, but running several at once needs a lot of memory, so start one at a time.

```bash
cd patroni-prod
cp .env.example .env        # then replace the "change-me" values
docker compose up -d --build
bash failover-test.sh       # writes through the API, kills the primary, checks nothing was lost
```

Grafana: http://localhost:3001. See each lab's folder for its own instructions and port table. [`patroni-prod/README.md`](patroni-prod/README.md) is the most complete.

## Ports

| Lab | Main addresses |
|---|---|
| `postgres/` | `:5440` primary, `:5441` synchronous replica, `:5442` asynchronous replica |
| `patroni/` | `:5450` primary, `:5451` replicas, `:7000` HAProxy stats, `:8088` dashboard, `:5100` API |
| `patroni-prod/` | `:5460`-`:5463` primary and replicas via two HAProxy, `:3001` Grafana, `:9090` Prometheus, `:5101` API |
| `sqlserver/` | none published by default; scenarios run through `docker compose exec` |

## Notes

- Passwords in the compose files are lab defaults for local use only. `patroni-prod` reads its secrets from a `.env` file that is not committed.
- Everything runs on a single Docker host, so these labs show behaviour and architecture, not real network or hardware separation. `patroni-prod/README.md` lists what that leaves out (TLS, a connection pooler, off-host backups, Alertmanager).
