# Benchmark results: patroni-prod

Run on 2026-11-27 on a Windows laptop running Docker Desktop (8 CPUs and 8 GB for Docker).
Each database node is limited to 1 CPU and 1 GB. The cluster had one primary, one synchronous standby and one asynchronous replica.
The load generator ran on the same machine, so these numbers show how the setup behaves, not production capacity.

Reproduce: `bash bench/run-benchmark.sh` (database level) and
`docker run --rm --network patroni-prod_default -v "$PWD/bench:/bench" grafana/k6:0.52.0 run /bench/k6-api.js` (API level).
Raw CSV from the database run: `bench/results/20261127-210626.csv` (not committed).

## Summary

| | Result |
|---|---|
| Read capacity (two replicas, SELECT-only) | about **7,900 queries/s**, flat from 16 clients up; the replicas hit their 1-CPU limit |
| Write capacity (pgbench read+write transactions) | about **230-270 TPS** at best; limited by commit flushes to disk |
| Whole stack, mixed load via the .NET API | **4,135 requests/s**, 0 failures, p95 69 ms at 200 concurrent users |
| Connection limit | `max_connections = 200`: 260 clients are refused with "too many clients already" |
| After the load | replication lag 0, sync standby intact, no alerts firing |

## Database level (pgbench, scale 10 = 1,000,000 rows, 20 s per measurement)

### Reads through the replica endpoint (:5001), SELECT-only

| Clients | TPS | Avg latency (ms) | Leader CPU % | Busiest replica CPU % |
|---:|---:|---:|---:|---:|
| 1 | 1,248 | 0.80 | 4 | 44 |
| 4 | 5,966 | 0.67 | 3 | 82 |
| 8 | 6,719 | 1.19 | 3 | 109 |
| 16 | 7,891 | 2.03 | 4 | 110 |
| 32 | 7,922 | 4.04 | 5 | 109 |
| 64 | 7,568 | 8.46 | 4 | 110 |
| 128 | 7,903 | 16.20 | 4 | 115 |

### Writes through the primary endpoint (:5000), read+write transactions

| Clients | TPS | Avg latency (ms) | Leader CPU % |
|---:|---:|---:|---:|
| 1 | 76 | 13.24 | 42 |
| 4 | 167 | 23.90 | 107 |
| 8 | 219 | 36.54 | 87 |
| 16 | 228 | 70.24 | 100 |
| 32 | 270 | 118.62 | 105 |
| 64 | 49 | 1,313.86 | 63 |
| 128 | 223 | 572.76 | 109 |

The 64-client row is a disk stall, not a real collapse: leader CPU fell to 63% and the next level recovered.

### Mixed: 32 read clients on the replicas and 8 write clients on the primary at the same time

| | TPS | Avg latency (ms) |
|---|---:|---:|
| Reads | 7,330 | 4.37 |
| Writes | 186 | 42.92 |

Against the same loads run alone: reads down about 7%, writes down about 15%.

### Cost of durability: 16 write clients under each `synchronous_commit` mode

| Mode | Pass 1 TPS | Pass 2 TPS |
|---|---:|---:|
| off | 466 | 239 (stall) |
| local | 351 | 339 |
| on (cluster default) | 291 | 326 |
| remote_apply | 77 (stall) | 318 |

Two of the eight runs were disk stalls. `local` and `on` are consistent: waiting for the synchronous standby cost roughly 5-15% of write throughput.

### Stress: 260 clients

Refused at connection time: `FATAL: sorry, too many clients already`. This is the hard `max_connections = 200` ceiling.

## API level (k6 -> .NET API -> HAProxy -> Postgres)

Ramp to 40 writers and 160 readers (200 users), about two minutes.

| | Result |
|---|---|
| Requests | 461,929, 0 failed (100% of checks passed) |
| Throughput | 4,135 requests/s |
| Writes | about 645/s average (71,452 rows inserted), avg 39 ms, p95 75 ms |
| Reads | about 3,530/s average, avg 29 ms, p95 68 ms |
| All requests | median 25 ms, p95 69 ms, p99 116 ms, max 892 ms |
| Thresholds | all passed: writes p95 < 500 ms, reads p95 < 200 ms, errors < 1% |

## Finding the ceiling (breakpoint test, through the .NET API)

`bench/find-ceiling.sh` holds a fixed request rate for 30 s per step (open model: requests arrive whether or not the
system keeps up) and steps up until a step fails: p95 >= 500 ms, errors >= 1%, or >= 3% of requests dropped.
Run separately for reads and for writes because they hit different limits.

### Reads only

| Target req/s | Achieved | p95 | p99 | Replica CPU | API cores | VM CPU | Verdict |
|---:|---:|---:|---:|---:|---:|---:|---|
| 2,000 | 2,000 | 32 ms | 61 ms | 72% | 1.75 | 70% | PASS |
| 4,000 | 3,871 | 116 ms | 229 ms | 98% | 1.54 | 85% | FAIL (3.2% dropped, no errors) |

Read ceiling: about **3,900 requests/s**, where the replicas reach their 1-CPU limit. Steps between 2,000 and 4,000 were not run.

### Writes only (POST /links, one row each)

| Target writes/s | Achieved | p95 | p99 | Leader CPU | Verdict |
|---:|---:|---:|---:|---:|---|
| 100 | 100 | 19 ms | 992 ms | 24% | PASS |
| 200 | 200 | 186 ms | 443 ms | 51% | PASS |
| 400 | 400 | 86 ms | 619 ms | 82% | PASS |
| 600 | 599 | 620 ms | 861 ms | 90% | FAIL (p95 over 500 ms, no errors) |

Write ceiling: roughly **400-600 writes/s**; the leader is nearly out of CPU at 600. The disk was healthy during this series
(543 fdatasync ops/s before, 676 after), so this is the 1-CPU leader plus commit cost, not a disk stall.
The earlier closed-loop test sustained about 645 writes/s on average with low latency, so on a good run the limit is probably nearer 600-700.

### An earlier attempt that failed for a different reason

A first mixed (85% reads / 15% writes) breakpoint run failed at 2,000 req/s (300 writes/s) with write p95 of 4.9 s. At that moment
the leader's disk had slowed to about 70 fdatasync ops/s (it normally does 500-650) and it recovered once idle. The API's retries turned
timeouts into long waits, so errors read 0% while latency was terrible. That run is not a valid ceiling; it shows that a slow disk, not CPU,
can drop write capacity by an order of magnitude on this machine, and that the API hides a struggling database behind retries.

### What this means for an 85% read / 15% write workload

Writes saturate first: at about 500 writes/s, a 15% write share is about 3,300 total req/s (reads would be about 2,800/s, under the 3,900 read limit).
So the mixed ceiling on this laptop is about **3,000-4,000 req/s**, set by the leader.

## Caveats

- Write numbers are limited by this machine's disk: `fdatasync` ran at only 260-630 per second and varied from run to run, with one 47 ms spike. A real server would do far more.
- The load generator shares the host's CPUs with the database.
- The dataset (about 150 MB) fits in memory, so reads are better than they would be on a large dataset.
- Most points are a single run, so expect noise. The commit-mode comparison had two runs per mode and two stalls.
- Not measured: behaviour of existing connections while `max_connections` is exhausted, and load during a failover.
- The API writes are faster than pgbench's. A likely reason is that one-row inserts group-commit well while pgbench's multi-statement transaction contends on 10 hot rows; this was not verified.
