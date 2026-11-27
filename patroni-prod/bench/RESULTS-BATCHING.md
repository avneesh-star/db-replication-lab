# Write batching: before and after

`WRITE_BATCHING` switches the API between one transaction per create (off) and grouping concurrent creates into one
multi-row INSERT per commit (on). Same build, same data. Run with `bash bench/compare-batching.sh` on 2026-11-27 on a
Docker Desktop laptop (8 CPUs for Docker; each Postgres node limited to 1 CPU), 100% writes through the API, rate raised
step by step (25 s per step) until a step fails (p95 >= 500 ms, errors >= 1%, or >= 3% dropped). Two passes, alternating
off/on. Redis cache on throughout (each write also populates the cache).

## Result

| Pass | Peak completed, batching OFF | Peak completed, batching ON | Gain |
|---|---:|---:|---:|
| 1 | 547 writes/s | 935 writes/s | 1.7x |
| 2 | 797 writes/s | 3,000 writes/s | 3.8x |
| average | 672 | 1,968 | 2.9x |

The passes disagree a lot, so the honest range is **1.7x to 3.8x**. Pass 2 is the cleaner comparison (the leader's disk was
healthy before both runs: 743 and 809 fdatasync ops/s); in pass 1 the "on" run stalled at the 1,000 writes/s step (the leader's CPU
fell to 17% while latency rose, which looks like a stall rather than saturation).

## What changed at the same rate

| Writes/s | p95 OFF (pass 1 / 2) | p95 ON (pass 1 / 2) | DB connections OFF -> ON |
|---:|---|---|---|
| 400 | 112 ms / 20 ms | 16 ms / 17 ms | 41 -> 5 |
| 600 | 3,220 ms (fail) / 28 ms | 26 ms / 19 ms | 20-41 -> 5 |
| 800 | - / 119 ms | 35 ms / 34 ms | 41 -> 5 |
| 1,000 | - / 19,645 ms (fail) | 724 ms (fail) / 20 ms | -> 5 |
| 2,000 | - | - / 30 ms | -> 5 |
| 3,000 | - | - / 66 ms (leader 72% CPU) | -> 5 |

- **Connections:** the API held about 41 database connections without batching (its pools were full) and **5 with it**.
  A pool of 20 connections no longer limits writes, and Postgres's 200-connection limit is far less of a worry.
- **Latency:** at 800 writes/s p95 was 119 ms off and 34 ms on.

## Failure behaviour

- **Batching off** failed hard when overloaded: in pass 2 at 1,000 writes/s, 17% of requests errored and p95 was 19.6 s. (The disk probe
  right after that step read 35 fdatasync ops/s, so the disk collapsed too; the cause is mixed.)
- **Batching on** failed at 4,000 writes/s (pass 2) with no errors but 52% of requests dropped by the generator and p95 of 2.3 s.
  At that step the leader was at 65% CPU, the API 0.9 cores and the VM 56%, so nothing I measured was saturated. The raw database
  inserted about 11,000 rows/s in `write-path.sh`, so the limit here is not the database; it may be the batcher's settings
  (4 workers, 100 rows per batch), the API, or the load generator. I did not find out which.

## Correctness checked with batching on

- Replay of the same create returns 200, a conflicting URL returns 409, a repeated idempotency key returns 200.
- 60 parallel creates of one code: exactly one 201 and 59 replays (200). Same code with different URLs: one 201 and 59 conflicts (409).
- 600 parallel unique creates: all 201 and exactly the expected row count.
- **Failover under write load** (`bench/failover-under-load.sh`): the leader was killed at 15 s into 100 writes/s. The API acknowledged
  5,146 writes and the database held exactly 5,146 new rows, with no failures. No acknowledged write was lost.
  This was one run of one scenario at a low rate; it is evidence, not proof.

## Costs and risks of batching

- **A failed batch fails every request in it.** One database error or an exhausted retry window now affects up to 100 clients at once
  instead of one.
- **Requests can wait in a queue.** Under overload the latency comes from queueing, not from the database (the 52% dropped, p95 2.3 s step).
- **A bounded queue (10,000)** applies backpressure, but a long outage still holds those requests for the full retry window.
- **The 200 vs 201 status can differ** after a retry across a failover: a batch that committed but whose reply was lost is reported as a replay.
- It adds code (`WriteBatcher.cs`) that has to be understood and tested; it does nothing for reads.

## Caveats

- Two passes on a shared laptop with a volatile disk (fdatasync probes ranged from 35 to 899 ops/s across the run). Treat
  differences under about 30% as noise, and note that the two "on" passes differ by 3x.
- Coarse steps (200-1,000 writes/s) mean each ceiling is accurate to about one step.
- The "off" ceiling here (547-797 completed) is a little higher than the earlier 400-600 estimate; that estimate came from different runs.
- Batching settings (4 workers, 100 rows) were not tuned.
