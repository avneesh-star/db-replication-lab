// One step of the breakpoint test: hold a fixed request RATE against the API for DURATION.
// find-ceiling.sh runs this at increasing rates. It is an open-model test: requests arrive at the
// target rate whether or not the system keeps up, so an overloaded system shows up as high latency,
// errors, or "dropped iterations" (the generator could not even start the request in time).
//
// Mix: WRITE_SHARE of requests are POST /links, the rest are GET /links/{code}.
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.BASE || 'http://api:8080';
const RATE = parseInt(__ENV.RATE || '1000');
const DURATION = __ENV.DURATION || '30s';
const WRITE_SHARE = parseFloat(__ENV.WRITE_SHARE || '0.15');
const OUT = __ENV.OUT || `/bench/results/k6-rate-${RATE}.json`;

export const options = {
  scenarios: {
    load: {
      executor: 'constant-arrival-rate',
      rate: RATE, timeUnit: '1s', duration: DURATION,
      preAllocatedVUs: Math.min(RATE, 400), maxVUs: 4000,
    },
  },
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

export function setup() {
  const codes = [];
  for (let i = 0; i < 50; i++) {
    const code = `ceil-${runId}-seed-${i}`;
    const r = http.post(`${BASE}/links`, JSON.stringify({ url: `https://example.com/seed/${i}`, code }),
      { headers: { 'Content-Type': 'application/json' } });
    if (r.status === 201 || r.status === 200) codes.push(code);
  }
  return { codes };
}

export default function (data) {
  if (Math.random() < WRITE_SHARE) {
    const id = `ceil-${runId}-${__VU}-${__ITER}`;
    const r = http.post(`${BASE}/links`, JSON.stringify({ url: `https://example.com/load/${id}`, code: id }), {
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': id },
      tags: { kind: 'write' },
    });
    check(r, { 'write 201': (x) => x.status === 201 });
  } else {
    const code = data.codes[Math.floor(Math.random() * data.codes.length)];
    const r = http.get(`${BASE}/links/${code}`, { tags: { kind: 'read' } });
    check(r, { 'read 200': (x) => x.status === 200 });
  }
}

export function handleSummary(data) {
  return { [OUT]: JSON.stringify(data) };
}
