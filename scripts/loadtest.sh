#!/usr/bin/env bash
# scripts/loadtest.sh
# Generate sustained HTTP traffic through HashiCups and optionally inject a fault.
#
# Usage:
#   ./scripts/loadtest.sh                          # default: localhost:8080, 120s
#   ./scripts/loadtest.sh http://localhost:8080    # explicit base URL
#   ./scripts/loadtest.sh http://localhost:8080 60  # 60-second run
#
# What it does:
#   Phase 1 (0-60s):  Normal traffic — GET /api, /api/coffees, /api/orders
#   Phase 2 (60-end): Fault injection — scales product-api to 0 replicas to
#                     trigger 5xx errors visible on the Data Plane Performance
#                     dashboard (envoy_cluster_upstream_rq_5xx).
#   Cleanup:          Restores product-api to 1 replica after the run.
#
# Observability:
#   - Metrics:  Prometheus → Data Plane Performance dashboard → "5xx errors" panel
#   - Traces:   Jaeger → service "nginx" → look for ERROR spans
#   - Logs:     Grafana Explore → Loki → {namespace="default"} → filter for "500"

set -euo pipefail

BASE_URL="${1:-http://localhost:8080}"
DURATION="${2:-120}"
DEMO_NS="default"
FAULT_DELAY=60         # seconds before fault injection
CONCURRENCY=3          # parallel request workers
REQUEST_INTERVAL=0.5   # seconds between requests per worker

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[$(date +%H:%M:%S)]${RESET} $*"; }
error() { echo -e "${RED}[$(date +%H:%M:%S)]${RESET} $*"; }

# ── Endpoints to hammer ───────────────────────────────────────────────────────
ENDPOINTS=(
  "/"
  "/api"
  "/api/coffees"
  "/api/ingredients/1"
  "/api/ingredients/2"
)

# ── Stats tracking ────────────────────────────────────────────────────────────
SUCCESS=0
FAILURE=0
TOTAL=0

cleanup() {
  echo ""
  info "Cleaning up..."
  # Restore product-api if it was scaled down
  CURRENT=$(kubectl get deployment product-api -n "$DEMO_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [[ "$CURRENT" == "0" ]]; then
    info "Restoring product-api to 1 replica..."
    kubectl scale deployment product-api -n "$DEMO_NS" --replicas=1
    info "product-api scaled back to 1 replica"
  fi
  # Kill background workers
  jobs -p | xargs -r kill 2>/dev/null || true
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  info "Load test complete"
  echo "  Total requests:   $TOTAL"
  echo "  Successful (2xx): $SUCCESS"
  echo "  Failed (4xx/5xx): $FAILURE"
  echo ""
  echo "  Check dashboards:"
  echo "    Grafana:    http://localhost:3000 → Data Plane Performance"
  echo "    Jaeger:     http://localhost:16686 → service: nginx"
  echo "    Prometheus: http://localhost:9090 → envoy_cluster_upstream_rq_5xx"
  echo "═══════════════════════════════════════════════════════════"
}
trap cleanup EXIT INT TERM

# ── Worker function ───────────────────────────────────────────────────────────
worker() {
  local worker_id=$1
  local end_time=$(($(date +%s) + DURATION))
  while [[ $(date +%s) -lt $end_time ]]; do
    for endpoint in "${ENDPOINTS[@]}"; do
      url="${BASE_URL}${endpoint}"
      STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time 5 --connect-timeout 3 "$url" 2>/dev/null || echo "000")
      ((TOTAL++)) || true
      if [[ "$STATUS" =~ ^[23] ]]; then
        ((SUCCESS++)) || true
      else
        ((FAILURE++)) || true
        if [[ "$STATUS" != "000" ]]; then
          warn "Worker $worker_id: $STATUS $url"
        fi
      fi
    done
    sleep "$REQUEST_INTERVAL"
  done
}

# ── Pre-flight check ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
info "HashiCups Load Test"
echo "  Target:     $BASE_URL"
echo "  Duration:   ${DURATION}s"
echo "  Workers:    $CONCURRENCY"
echo "  Fault at:   ${FAULT_DELAY}s (product-api scaled to 0)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check target is reachable
if ! curl -sf --max-time 5 --connect-timeout 3 "${BASE_URL}/" -o /dev/null; then
  error "Cannot reach $BASE_URL — is kubectl port-forward running?"
  echo "  Run: kubectl port-forward svc/nginx 8080:80 -n $DEMO_NS"
  exit 1
fi
info "Target reachable. Starting load test..."

# ── Phase 1: Normal traffic ───────────────────────────────────────────────────
info "Phase 1: Normal traffic for ${FAULT_DELAY}s..."
for i in $(seq 1 $CONCURRENCY); do
  worker "$i" &
done

sleep "$FAULT_DELAY"

# ── Phase 2: Fault injection ──────────────────────────────────────────────────
REMAINING=$((DURATION - FAULT_DELAY))
if [[ $REMAINING -gt 0 ]]; then
  echo ""
  warn "Phase 2: FAULT INJECTION — scaling product-api to 0 replicas"
  warn "  This will cause 503 errors on /api/coffees (product-api dependency)"
  warn "  Watch: Grafana → Data Plane Performance → Upstream Rq by Status Code"
  echo ""
  kubectl scale deployment product-api -n "$DEMO_NS" --replicas=0
  info "product-api scaled to 0. Continuing traffic for ${REMAINING}s..."
  sleep "$REMAINING"
fi

# ── Wait for workers to finish ────────────────────────────────────────────────
wait
