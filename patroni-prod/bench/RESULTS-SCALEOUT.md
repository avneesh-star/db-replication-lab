# Scaling out: what was tried and what it showed

Everything here ran on one Docker Desktop laptop (8 CPUs for Docker; each Postgres node limited to 1 CPU unless stated),
with the load generator, API, Redis, HAProxy and databases all sharing those CPUs. Single runs unless stated. Read the
numbers as direction, not capacity. Branch: `feature/scale-out`.

## What helped, with evidence

| Change | Measured effect |
|---|---|
| **Redis cache** (earlier work, `RESULTS-REDIS.md`) | read ceiling about 2.0-2.5x; replicas and leader nearly idle on reads |
| **Write batching** (earlier, `RESULTS-BATCHING.md`) | write ceiling 1.7x-3.8x; DB connections 41 -> 5; p95 at 800 writes/s 119 -> 34 ms |
| **L1 in-process cache** | Redis CPU 0.21-0.22 -> 0.03-0.04 cores (about 85% less) and API CPU 10-18% lower at the same read rate; no throughput gain measurable (the load generator is the cap at about 9,700 req/s) |
| **PgBouncer** (12 API instances, 1,500 simultaneous users, cache and batching off) | throughput 711 -> 1,334 req/s, failed requests 6.2% -> 0.0%, p95 3.8 s -> 2.1 s, real Postgres connections per node 139-168 -> 10-20 |
| **Load balancer retries** (4 API instances, one killed under 2,000 req/s) | failed requests 95 of 73,653 (0.13%) -> 0 of 72,895; slowest request 10.4 s -> 4.9 s; the dead instance was dropped from rotation after about 1.3 s either way |
| **HTTP caching headers** | implemented and verified with curl (`Cache-Control: public, max-age=N` on found links, none on 404); the benefit comes from browsers and CDNs, which this lab does not have, so it was not benchmarked |

## What did not help (or was not shown to)

| Change | Result |
|---|---|
| **Batcher tuning** (workers 2/4/8/16, batch 50/100/200) | from 100 rows up all settings peaked at 3,784-3,943 writes/s, a 4% spread, within noise; batch size 50 was clearly worse (failed at 3,000); worker count changes DB connections (3 to 17) but not throughput. The default (4 workers, 100 rows) stays |
| **More CPU per database node** (1 -> 2 CPUs) | inconclusive. Writes without batching: peak 534 -> 800 (p95 3,349 -> 40 ms). Writes with batching: 2,507 -> 4,636, but earlier 1-CPU runs reached about 3,900, so most of that gain is run-to-run variation. Reads with the cache off: 3,742 -> 2,880 (worse). At the failing steps the databases were far from CPU-bound (leader 5-41%, replicas 27-30%) and the machine had headroom (VM 26-50%) |
| **A third read replica** (cache off, straight to the API) | no gain: 3 replicas 3,840 completed at 4,000 req/s vs 2 replicas 3,688; per-replica CPU fell from about 42% to about 17% but throughput did not move |
| **API connection pool 20 -> 60** (cache off) | no gain: 3,435 -> 3,507 completed at 4,000 req/s |

## What is still unexplained

With the cache off, reads stop at about **3,700-3,850 req/s** whatever I changed: node CPU (1 or 2), replica count (2 or 3), API
pool size (20 or 60). At those points the database nodes (17-43%), the API (0.6-1.0 cores), the database HAProxy (0.2 cores) and the
VM (44-53%) were all well below saturation, yet latency rose and requests were dropped. I did not find what is limiting it.
The load balancer is a minor cost, not the cause: through it, 4,000 req/s completed 3,513 with p95 349 ms and 0.84 cores of load
balancer CPU, versus 3,853 and p95 121 ms straight to the API.

Writes show a similar pattern: with batching on they stop at about 3,800-4,600 writes/s with the leader at 5-62% CPU.

So the honest summary is that the cheap, well-understood levers (a cache, batching, a connection pooler, load-balancer retries)
helped, and the expensive ones (more CPU, more replicas, a bigger pool) did not move the numbers here. The next step is to find the
unexplained limit with a profiler or tracing on the API and a different load generator, not to buy more hardware.

## Not done

- **A write queue** (for example Kafka) with asynchronous acknowledgement changes what a write means and needs another system.
- **Sharding** across several Patroni clusters, and **multi-region** replicas, need much more infrastructure than one Docker host.

## Caveats

- Single runs on a shared laptop whose disk speed varied from 35 to 900 fdatasync ops/s during these experiments. Differences under about 30% are noise.
- The vertical-scaling and replica experiments are confounded by the machine's own limits and by the unexplained cap above.
- The PgBouncer demo did not exhaust Postgres's 200-connection limit (busiest node 168); each extra API instance adds about 13 connections per node, so about 15 instances would. I did not examine what caused the 6.2% failures in the direct case.
- The extra replica (`pg-node4`, profile `extra-replica`) was added, tested and removed; its replication slot was dropped by hand.
