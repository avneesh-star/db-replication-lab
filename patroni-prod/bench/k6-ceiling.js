// One step of the breakpoint test: hold a fixed request RATE against the API for DURATION.
// find-ceiling.sh runs this at increasing rates. It is an open-model test: requests arrive at the
// target rate whether or not the system keeps up, so an overloaded system shows up as high latency,
// errors, or "dropped iterations" (the generator could not even start the request in time).
//
// Mix: WRITE_SHARE of requests are POST /links, the rest are GET /links/{code}.
//
// Reads pick from KEYS pre-created links with a skew: HOT_SHARE of the reads go to the hottest 20% of
// the keys (default 80/20), the rest spread over the other 80%. That is what makes a cache useful
// without making the test unrealistically easy (a cache gets 100% hits only if every key is hot).
// The keys must exist: run once with SEED=1 (see compare-redis.sh) before the first step.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://api:8080';
const RATE = parseInt(__ENV.RATE || '1000');
const DURATION = __ENV.DURATION || '30s';
const WRITE_SHARE = parseFloat(__ENV.WRITE_SHARE || '0.15');
const KEYS = parseInt(__ENV.KEYS || '10000');
const HOT_SHARE = parseFloat(__ENV.HOT_SHARE || '0.8');
const HOT_KEYS = Math.max(1, Math.floor(KEYS * 0.2));
const OUT = __ENV.OUT || `/bench/results/k6-rate-${RATE}.json`;

// Where each read was served from, according to the API's X-Served-By header.
const fromMemory = new Counter('read_from_memory');
const fromCache = new Counter('read_from_cache');
const fromReplica = new Counter('read_from_replica');
const fromPrimary = new Counter('read_from_primary');

// VUS set: closed model (a fixed number of simultaneous users, each sending the next request when the last
// one finishes). That is what exhausts connection pools. Otherwise: open model at a fixed request rate.
const VUS = parseInt(__ENV.VUS || '0');
export const options = {
  scenarios: {
    load: VUS > 0
      ? { executor: 'constant-vus', vus: VUS, duration: DURATION }
      : {
          executor: 'constant-arrival-rate',
          rate: RATE, timeUnit: '1s', duration: DURATION,
          preAllocatedVUs: parseInt(__ENV.PREALLOC || Math.min(RATE, 400)), maxVUs: 4000,
        },
  },
  setupTimeout: '300s',
  // Loose thresholds exist only so k6 reports the per-kind sub-metrics in its summary.
  thresholds: {
    'http_req_duration{kind:write}': ['max>=0'],
    'http_req_duration{kind:read}': ['max>=0'],
    'http_req_failed{kind:write}': ['rate>=0'],
    'http_req_failed{kind:read}': ['rate>=0'],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

const runId = Date.now().toString(36);
const keyName = (i) => `bench-key-${i}`;

export function setup() {
  if (__ENV.SEED !== '1') return {};
  // Create the KEYS links once. Re-running is safe: an existing code with the same URL is a replay.
  for (let start = 0; start < KEYS; start += 100) {
    const batch = [];
    for (let i = start; i < Math.min(start + 100, KEYS); i++) {
      batch.push(['POST', `${BASE}/links`, JSON.stringify({ url: `https://example.com/key/${i}`, code: keyName(i) }),
        { headers: { 'Content-Type': 'application/json' } }]);
    }
    http.batch(batch);
  }
  return {};
}

function pickKey() {
  const hot = Math.random() < HOT_SHARE;
  const i = hot ? Math.floor(Math.random() * HOT_KEYS) : HOT_KEYS + Math.floor(Math.random() * (KEYS - HOT_KEYS));
  return keyName(i);
}

export default function () {
  if (Math.random() < WRITE_SHARE) {
    const id = `ceil-${runId}-${__VU}-${__ITER}`;
    const r = http.post(`${BASE}/links`, JSON.stringify({ url: `https://example.com/load/${id}`, code: id }), {
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': id },
      tags: { kind: 'write' },
    });
    check(r, { 'write 201': (x) => x.status === 201 });
  } else {
    const r = http.get(`${BASE}/links/${pickKey()}`, { tags: { kind: 'read' } });
    check(r, { 'read 200': (x) => x.status === 200 });
    const src = r.headers['X-Served-By'];
    if (src === 'memory') fromMemory.add(1);
    else if (src === 'cache') fromCache.add(1);
    else if (src === 'replica') fromReplica.add(1);
    else if (src === 'primary') fromPrimary.add(1);
  }
}

export function handleSummary(data) {
  return { [OUT]: JSON.stringify(data) };
}
