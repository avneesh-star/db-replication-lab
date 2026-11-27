// Application-level load and stress test: the whole path, HTTP -> .NET API -> HAProxy -> Postgres.
//
//   docker run --rm --network patroni-prod_default -v "$PWD/bench:/bench" grafana/k6:0.52.0 run /bench/k6-api.js
//
// Two scenarios run together, each ramping up and holding:
//   writes  POST /links  (inserts through the primary endpoint)
//   reads   GET  /links/{code}  (replica first, primary fallback)
// Override the target with -e BASE=http://host:port and the peak with -e PEAK_WRITERS / -e PEAK_READERS.
import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const BASE = __ENV.BASE || 'http://api:8080';
const PEAK_WRITERS = parseInt(__ENV.PEAK_WRITERS || '40');
const PEAK_READERS = parseInt(__ENV.PEAK_READERS || '160');
const retried = new Counter('writes_needing_retry');   // POSTs where the API had to retry a database call

export const options = {
  scenarios: {
    writes: {
      executor: 'ramping-vus', exec: 'write', startVUs: 1,
      stages: [
        { duration: '20s', target: Math.ceil(PEAK_WRITERS / 4) },
        { duration: '30s', target: Math.ceil(PEAK_WRITERS / 2) },
        { duration: '30s', target: PEAK_WRITERS },
        { duration: '30s', target: PEAK_WRITERS },
        { duration: '10s', target: 0 },
      ],
    },
    reads: {
      executor: 'ramping-vus', exec: 'read', startVUs: 1,
      stages: [
        { duration: '20s', target: Math.ceil(PEAK_READERS / 4) },
        { duration: '30s', target: Math.ceil(PEAK_READERS / 2) },
        { duration: '30s', target: PEAK_READERS },
        { duration: '30s', target: PEAK_READERS },
        { duration: '10s', target: 0 },
      ],
    },
  },
  thresholds: {
    'http_req_failed': ['rate<0.01'],                             // under 1% errors
    'http_req_duration{scenario:writes}': ['p(95)<500'],          // writes: 95% under 500 ms
    'http_req_duration{scenario:reads}': ['p(95)<200'],           // reads: 95% under 200 ms
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

const runId = Date.now().toString(36);

export function setup() {
  // Seed some rows so the readers have real codes to look up.
  const codes = [];
  for (let i = 0; i < 50; i++) {
    const code = `k6seed-${runId}-${i}`;
    const r = http.post(`${BASE}/links`, JSON.stringify({ url: `https://example.com/seed/${i}`, code }),
      { headers: { 'Content-Type': 'application/json' } });
    if (r.status === 201 || r.status === 200) codes.push(code);
  }
  return { codes };
}

export function write() {
  const id = `k6-${runId}-${__VU}-${__ITER}`;
  const r = http.post(`${BASE}/links`, JSON.stringify({ url: `https://example.com/load/${id}`, code: id }), {
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': id },
  });
  check(r, { 'write 201': (x) => x.status === 201 });
  if (parseInt(r.headers['X-Db-Attempts'] || '1') > 1) retried.add(1);
}

export function read(data) {
  const code = data.codes[Math.floor(Math.random() * data.codes.length)];
  const r = http.get(`${BASE}/links/${code}`);
  check(r, { 'read 200': (x) => x.status === 200 });
}
