# LinkShortener: a .NET backend for the Patroni lab

An ASP.NET Core (.NET 10) minimal API that stores short links in the Patroni cluster from `../patroni`. It shows how an application should talk to a failover-capable PostgreSQL setup.

## Run

**In Docker (part of the Patroni compose file):**

```bash
cd ../patroni && docker compose up -d --build     # starts the cluster and the api at http://localhost:5100
```

Inside Docker the app reaches HAProxy as `haproxy:5000` (writes) and `haproxy:5001` (reads), set through `ConnectionStrings__Writer` and `ConnectionStrings__Reader` in `../patroni/docker-compose.yml`.

**Or locally with the .NET SDK** (stop the `api` container first, since both use port 5100):

```bash
cd ../patroni && docker compose up -d --build
cd ../dotnet/LinkShortener
dotnet run --urls http://localhost:5100
```

On start it waits for the cluster and creates the `links` table on the primary. The replicas receive it through replication.

## Endpoints

| Method and path | What it does |
|---|---|
| `POST /links` | create a link: `{"url": "https://...", "code": "optional"}`. Send an `Idempotency-Key` header to make retries safe |
| `GET /links/{code}` | look a link up. Header `X-Served-By` says `replica` or `primary` |
| `GET /r/{code}` | 302 redirect to the long URL |
| `GET /stats` | row count and replication lag, read from a replica |
| `GET /health/db` | which node answers the writer and reader endpoints |

```bash
curl -X POST localhost:5100/links -H 'Content-Type: application/json' \
     -H 'Idempotency-Key: order-42' -d '{"url":"https://example.com/hello","code":"hello"}'
curl -i localhost:5100/links/hello
curl localhost:5100/health/db
```

## How it uses the cluster

The app holds exactly two connection strings (`appsettings.json`) and never names a Postgres node:

| Setting | Points at | Used for |
|---|---|---|
| `ConnectionStrings:Writer` | `localhost:5450` (HAProxy, leader only) | all writes, and read fallbacks |
| `ConnectionStrings:Reader` | `localhost:5451` (HAProxy, healthy replicas) | normal reads |

Because HAProxy follows the leader, a failover needs no config change or restart.

## What the code does about failover

| Concern | Where | What it does |
|---|---|---|
| Connections die during failover | `Db.cs` `Resilience.RetryAsync` | retries transient errors (dropped connection, connect timeout, node shutting down, write on a just-demoted node) with backoff for up to 45 s. A failover takes about 25 s here, so the window must be longer than that |
| A retry repeats a write that already committed | `LinkRepository.CreateAsync` | the code is picked once, outside the retry loop, and the insert uses `ON CONFLICT DO NOTHING`, so a repeat returns the existing row. An `Idempotency-Key` makes retries from the client safe too |
| Replicas can be slightly behind | `LinkRepository.GetAsync` | a miss on a replica is re-checked on the primary, so "create, then open" always works |
| Reader endpoint down | `LinkRepository.GetAsync` | falls back to the primary instead of failing |
| Dead pooled connections | connection string | `Keepalive=10` and `Connection Lifetime=60` so stale connections are detected and recycled |
| Hung requests | connection string | `Timeout=3` (connect) and `Command Timeout=10`, so a request fails fast instead of hanging |

Responses to `POST /links` carry `attempts` and `elapsedMs` (also as `X-DB-Attempts` and `X-DB-Elapsed-Ms` headers), so you can see a failover as one slow request with many attempts.

## Test a failover

With the app running, post writes while you stop the leader. The dashboard at http://localhost:8088 shows which node is the leader and has Stop/Start buttons.

A test I ran: 30 writes at one per half second through the API, leader stopped after 6 seconds. All 30 returned 201 with no client errors. The write in flight when the leader stopped waited 24 s, was retried 12 times, and then succeeded. No rows were lost or duplicated.

Watch the app log for lines like `create link: attempt 3 failed (...); retrying in 1000 ms`.

## Things to know

- **Writes slower than your timeout.** The 45 s retry window holds a request open during a failover. If your HTTP clients or load balancer time out sooner, they will see a failure even though the write succeeds. Match the timeouts to the failover time, or return `202 Accepted` and finish asynchronously.
- **Retrying is only safe for idempotent operations.** This is why every write here is built to be repeated. A blind retry of `INSERT ... VALUES (...)` without a unique key can duplicate rows.
- **Async replication can lose recent commits.** If a leader dies before sending a commit to a replica, that commit is gone after promotion. For data you cannot lose, turn on `synchronous_mode` in Patroni (see `../patroni/README.md`).
- **Passwords are in `appsettings.json` for the lab.** In real use, use environment variables or a secret store.

## Files

| File | Purpose |
|---|---|
| `Program.cs` | HTTP endpoints |
| `LinkRepository.cs` | queries, idempotent insert, replica-first reads with primary fallback |
| `Db.cs` | the two data sources and the retry helper |
| `appsettings.json` | connection strings and retry windows |
