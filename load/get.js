import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";
import { sleep } from "k6";
import http from "k6/http";
import Big from "https://cdn.jsdelivr.net/npm/big.js@7.0.1/big.min.js";

const MAX_REQUESTS = __ENV.MAX_REQUESTS ?? 500;

export const options = {
  summaryTrendStats: [
    "p(99)",
    "count",
  ],
  thresholds: {
    //http_req_failed: [{ threshold: "rate < 0.01", abortOnFail: false }],
    //http_req_duration: ['p(99) < 50'],
  },
  scenarios: {
    get_payments: {
      exec: "getPayments",
      executor: "ramping-vus",
      startVUs: 1,
      gracefulRampDown: "0s",
      stages: [{ target: MAX_REQUESTS, duration: "10" }],
    },
  },
};

export function getPayments() {
  http.get("http://localhost:9999/payments-summary");
  sleep(1 * 1000);
}

export function handleSummary(data) {
  // Print p99 latency and other summary stats
  const httpReqDuration = data.metrics["http_req_duration"];
  if (httpReqDuration && httpReqDuration["p(99)"] !== undefined) {
    console.log(`p99 latency: ${httpReqDuration["p(99)"]} ms`);
  }
  return {
    stdout: textSummary(data),
  };
}