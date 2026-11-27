# Redis cache: before and after

Same API build, same data, same test script. The only difference is `CACHE_ENABLED` (false = every read goes to
Postgres, true = reads try Redis first). Run with `bash bench/compare-redis.sh` on 2026-11-27 on a Docker Desktop laptop
(8 CPUs for Docker; Postgres nodes and Redis each limited to 1 CPU). Everything, including the load generator, shares those CPUs.

Test: the request rate is raised step by step (25 s per step) until a step fails (p95 >= 500 ms, errors >= 1%, or >= 3% of
requests dropped). Reads pick from 10,000 existing links, 80% of them from the hottest 20%. The cache starts empty and gets a
10 s warm-up. Modes were alternated per workload.

## Result

| Workload | Peak throughput completed, Redis OFF | Redis ON | Gain |
|---|---:|---:|---:|
| 100% reads | 3,833 req/s | 7,780 req/s | **2.0x** |
| 99% reads / 1% writes | 3,441 req/s | 5,701 req/s | **1.7x** |
| 85% reads / 15% writes | 2,658 req/s | 3,951 req/s | **1.5x** |

"Peak throughput completed" is the highest rate the stack actually finished, including the step where it started to fail.
The test steps in increments of 1,000-2,000 req/s, so each figure is accurate to roughly that much. The last *passing* step
alone understates the limit (for example, 100% reads passed 2,000 with the cache off but completed 3,833 at the next step).

## What Redis changed: load on Postgres

At the same request rate, the database nearly stops working on reads:

| 100% reads | p95 latency OFF | p95 latency ON | Busiest replica CPU OFF | ON |
|---|---:|---:|---:|---:|
| 2,000 req/s | 28 ms | 5 ms | 54% | 5% |
| 4,000 req/s | 103 ms | 7 ms | 80% | 4% |

With the cache on, the replicas and the leader sit nearly idle during a read-only load (2-6% CPU), and Redis itself uses
only 0.15-0.3 of a core. Cache hit rate was 91% at the first step (still filling), then 98-100%.

Other fixed-rate comparisons (p95): 99/1 mix at 4,000 req/s: 248 ms -> 24 ms. 85/15 mix at 3,000 req/s: 358 ms -> 32 ms.

## Per-workload detail

Columns: p95 latency, cache hit %, and CPU (api/redis in cores; replica as % of its 1-CPU limit; vm = whole Docker VM).

### 100% reads
| Rate | OFF: result | OFF p95 | ON: result | ON p95 | hit% | replica% off -> on | api cores (ON) | redis cores | vm% (ON) |
|---:|---|---:|---|---:|---:|---|---:|---:|---:|
| 2,000 | pass | 28 ms | pass | 5 ms | 91 | 54 -> 5 | 1.56 | 0.20 | 50 |
| 4,000 | FAIL (3,833 done, 4.2% dropped) | 103 ms | pass | 7 ms | 98 | 80 -> 4 | 1.77 | 0.28 | 64 |
| 6,000 | | | pass | 19 ms | 100 | -> 3 | 1.88 | 0.29 | 70 |
| 8,000 | | | pass (7,780 done, 2.7% dropped) | 36 ms | 100 | -> 2 | 1.72 | 0.23 | 68 |
| 10,000 | | | FAIL (7,125 done, 28.7% dropped) | 108 ms | 100 | -> 6 | 1.58 | 0.14 | 71 |

### 99% reads / 1% writes
| Rate | OFF | OFF p95 | ON | ON p95 | write p95 off -> on |
|---:|---|---:|---|---:|---|
| 2,000 | pass | 31 ms | pass | 8 ms | 36 -> 54 ms |
| 4,000 | FAIL (3,441 done, 14% dropped) | 248 ms | pass | 24 ms | 956 -> 43 ms |
| 6,000 | | | FAIL (5,701 done, 5% dropped) | 64 ms | 92 ms |

### 85% reads / 15% writes
| Rate | OFF | OFF p95 | ON | ON p95 | write p95 off -> on |
|---:|---|---:|---|---:|---|
| 1,000 | pass | 12 ms | pass | 13 ms | 22 -> 22 ms |
| 2,000 | pass | 68 ms | pass | 50 ms | 154 -> 107 ms |
| 3,000 | FAIL (2,658 done, 11.4% dropped) | 358 ms | pass | 32 ms | 186 -> 48 ms |
| 4,000 | | | pass (3,951 done) | 59 ms | 200 ms |
| 5,000 | | | FAIL (2,442 done, 51% dropped, 1.2% errors) | 2,852 ms | 12,526 ms |

## What to take from this

- **Redis roughly doubles the read ceiling and takes almost all read load off Postgres.** That is the main benefit: the database
  has room for writes and the replicas can be smaller or fewer.
- **The gain shrinks as the write share grows**, as expected: 2.0x, 1.7x, 1.5x. Redis cannot speed up writes.
- **With the cache on, the 85/15 mix fails abruptly at 5,000 req/s** (about 750 writes/s): write p95 reached 12.5 s with errors, and
  the leader was at 78% CPU. That is the write limit found earlier (roughly 600-700 writes/s on this machine) and it is a cliff,
  not a gradual slowdown. A cache does nothing for it.
- **Before running this, I expected the 85/15 mix to gain very little**, because I thought writes alone limited it. It gained 1.5x:
  with the cache off, reads were also a limit (read p95 reached 364 ms at 3,000 req/s while replica CPU was only 67%), so removing
  read load helped even a write-heavy mix. I did not isolate why reads slowed with the replicas not saturated; the API's
  database connection pool (20 connections per pool) is a plausible cause but is untested.
- **In the read-heavy runs with the cache on, nothing I measured was saturated** at the failing step: replicas 2-6% CPU, leader 3-9%,
  Redis 0.14-0.29 cores, the Docker VM 68-71%, the API about 1.6-1.9 cores. So the limit at about 7,800-8,000 req/s is
  not the database and not Redis. It is likely the API process or the load generator; I have not determined which.

## Caveats

- **The 10,000 keys all fit in Redis**, so the hit rate approaches 100%. A larger keyspace with a long tail would hit less often
  and gain less. The results show an upper bound for this key distribution, not a typical case.
- **Single runs on a shared laptop.** The disk was noisy: `fdatasync` before the 99/1 Redis-ON run was 174 ops/s (normal 500-700),
  and the probe after the 85/15 OFF run returned a nonsensical negative value (a timing glitch). Treat gains of 20% or less as noise.
- **Coarse steps** (1,000-2,000 req/s) mean each ceiling is accurate to about one step.
- **Cache keys never change**, because links are immutable, so there is no invalidation test here. A cache for data that changes
  needs an invalidation strategy that these runs do not exercise.
- **The Redis 1-CPU limit and 256 MB cap were never reached** (Redis used 0.14-0.29 cores).
- The cache is **cold-started and warmed for 10 s only**; a production restart of Redis would briefly send the full read load back to
  Postgres (a "thundering herd"), which this test does not measure.
