#!/usr/bin/env bash
# scripts/validate-consul-observability.sh
# Validates the Consul observability stack end-to-end.
# Checks: ProxyDefaults, ServiceDefaults envoyExtensions, Consul metrics (ACL),
#         Envoy metrics on :20200, Prometheus targets, Loki push endpoint, OTel.
#
# Usage: ./scripts/validate-consul-observability.sh

set -euo pipefail

CONSUL_NS="consul"
OBS_NS="observability"
DEMO_NS="default"

PASS=0
FAIL=0

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
pass() { echo -e "${GREEN}PASS${RESET}  $*"; ((PASS++)); }
fail() { echo -e "${RED}FAIL${RESET}  $*"; ((FAIL++)); }
info() { echo -e "${YELLOW}----${RESET}  $*"; }

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Consul Observability Validation"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── 0. Retrieve ACL bootstrap token ─────────────────────────────────────────
info "Retrieving Consul bootstrap ACL token..."
TOKEN=$(kubectl get secret consul-bootstrap-acl-token -n "$CONSUL_NS" \
  -o jsonpath='{.data.token}' | base64 --decode 2>/dev/null) \
  || { fail "Could not retrieve consul-bootstrap-acl-token from namespace $CONSUL_NS"; TOKEN=""; }

# ── 1. ProxyDefaults ─────────────────────────────────────────────────────────
info "Checking ProxyDefaults global..."
if kubectl get proxydefaults global -o yaml 2>/dev/null \
    | grep -q "envoy_prometheus_bind_addr"; then
  pass "ProxyDefaults has envoy_prometheus_bind_addr"
else
  fail "ProxyDefaults missing envoy_prometheus_bind_addr — Envoy metrics port 20200 not enabled"
fi

if kubectl get proxydefaults global -o yaml 2>/dev/null \
    | grep -q "envoy_tracing_json"; then
  pass "ProxyDefaults has envoy_tracing_json (Zipkin tracing configured)"
else
  fail "ProxyDefaults missing envoy_tracing_json — distributed tracing not configured"
fi

# ── 2. ServiceDefaults — envoyExtensions ─────────────────────────────────────
info "Checking ServiceDefaults for envoyExtensions (otel-access-logging)..."
for svc in nginx frontend public-api product-api payments; do
  if kubectl get servicedefaults "$svc" -n "$DEMO_NS" -o yaml 2>/dev/null \
      | grep -q "otel-access-logging"; then
    pass "ServiceDefaults/$svc has otel-access-logging envoyExtension"
  else
    fail "ServiceDefaults/$svc missing otel-access-logging envoyExtension"
  fi
done

# product-api-db is TCP — no envoyExtensions expected
if kubectl get servicedefaults product-api-db -n "$DEMO_NS" &>/dev/null; then
  pass "ServiceDefaults/product-api-db exists (TCP protocol, no envoyExtensions expected)"
else
  fail "ServiceDefaults/product-api-db not found"
fi

# ── 3. Intentions ─────────────────────────────────────────────────────────────
info "Checking ServiceIntentions..."
if kubectl get serviceintentions -n "$DEMO_NS" 2>/dev/null | grep -qE "nginx|frontend|public-api"; then
  pass "ServiceIntentions are present in namespace $DEMO_NS"
else
  fail "No ServiceIntentions found in namespace $DEMO_NS"
fi

# ── 4. HashiCups pods running ────────────────────────────────────────────────
info "Checking HashiCups pods (2/2 Running = app + consul-dataplane)..."
for svc in nginx frontend public-api product-api product-api-db payments; do
  READY=$(kubectl get pods -n "$DEMO_NS" -l "app=$svc" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
  if echo "$READY" | grep -q "true"; then
    READY_COUNT=$(echo "$READY" | tr ' ' '\n' | grep -c "true")
    pass "$svc: $READY_COUNT container(s) ready"
  else
    fail "$svc: pod not Running or not found in namespace $DEMO_NS"
  fi
done

# ── 5. Observability pods running ────────────────────────────────────────────
info "Checking observability pods..."
for deploy in loki otel-collector prometheus jaeger grafana; do
  READY=$(kubectl get deployment "$deploy" -n "$OBS_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  if [[ "${READY:-0}" -ge 1 ]]; then
    pass "$deploy is ready ($READY replicas)"
  else
    fail "$deploy is not ready in namespace $OBS_NS"
  fi
done

PROMTAIL_DESIRED=$(kubectl get daemonset promtail -n "$OBS_NS" \
  -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
PROMTAIL_READY=$(kubectl get daemonset promtail -n "$OBS_NS" \
  -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
if [[ "${PROMTAIL_DESIRED:-0}" -gt 0 && "$PROMTAIL_READY" == "$PROMTAIL_DESIRED" ]]; then
  pass "promtail DaemonSet: $PROMTAIL_READY/$PROMTAIL_DESIRED nodes ready"
else
  fail "promtail DaemonSet: $PROMTAIL_READY/$PROMTAIL_DESIRED nodes ready"
fi

# ── 6. Consul metrics endpoint (ACL auth) ────────────────────────────────────
info "Checking Consul metrics endpoint with ACL token..."
if [[ -n "$TOKEN" ]]; then
  CONSUL_METRICS=$(kubectl exec -n "$CONSUL_NS" consul-server-0 -- \
    sh -c "wget -qO- --header='X-Consul-Token: ${TOKEN}' \
    'http://localhost:8500/v1/agent/metrics?format=prometheus' 2>/dev/null" \
    | head -5 2>/dev/null || echo "")
  if echo "$CONSUL_METRICS" | grep -q "^consul_"; then
    pass "Consul metrics endpoint returns consul_ metrics (ACL auth working)"
  else
    fail "Consul metrics endpoint did not return consul_ metrics — check ACL token"
  fi
else
  fail "Skipped Consul metrics check (no token)"
fi

# ── 7. Envoy sidecar metrics on :20200 ───────────────────────────────────────
info "Checking Envoy sidecar metrics on port 20200..."
NGINX_POD=$(kubectl get pod -n "$DEMO_NS" -l app=nginx \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$NGINX_POD" ]]; then
  ENVOY_METRICS=$(kubectl exec -n "$DEMO_NS" "$NGINX_POD" -c nginx -- \
    wget -qO- "http://localhost:20200/metrics" 2>/dev/null | head -3 || echo "")
  if echo "$ENVOY_METRICS" | grep -q "^envoy_\|^consul_"; then
    pass "Envoy metrics available on :20200/metrics in pod $NGINX_POD"
  else
    # Try via curl if wget not available
    ENVOY_METRICS=$(kubectl exec -n "$DEMO_NS" "$NGINX_POD" -c nginx -- \
      curl -sf "http://localhost:20200/metrics" 2>/dev/null | head -3 || echo "")
    if echo "$ENVOY_METRICS" | grep -q "^envoy_\|^consul_"; then
      pass "Envoy metrics available on :20200/metrics in pod $NGINX_POD"
    else
      fail "Envoy metrics not found on :20200/metrics — check ProxyDefaults envoy_prometheus_bind_addr"
    fi
  fi
else
  fail "nginx pod not found in namespace $DEMO_NS — cannot check Envoy metrics"
fi

# ── 8. Prometheus targets ─────────────────────────────────────────────────────
info "Checking Prometheus API for target health..."
PROM_TARGETS=$(kubectl exec -n "$OBS_NS" \
  "$(kubectl get pod -n "$OBS_NS" -l app=prometheus -o jsonpath='{.items[0].metadata.name}')" -- \
  wget -qO- "http://localhost:9090/api/v1/targets?state=active" 2>/dev/null || echo "")

if echo "$PROM_TARGETS" | grep -q '"job":"consul"'; then
  CONSUL_HEALTH=$(echo "$PROM_TARGETS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
targets=[t for t in d.get('data',{}).get('activeTargets',[]) if t.get('labels',{}).get('job')=='consul']
up=[t for t in targets if t.get('health')=='up']
print(f'{len(up)}/{len(targets)} up')
" 2>/dev/null || echo "unknown")
  if echo "$CONSUL_HEALTH" | grep -vq "^0/"; then
    pass "Prometheus consul job: $CONSUL_HEALTH"
  else
    fail "Prometheus consul job targets are all down ($CONSUL_HEALTH) — check ACL token mount"
  fi
else
  fail "Prometheus consul job not found in active targets"
fi

if echo "$PROM_TARGETS" | grep -q '"job":"envoy-sidecars"'; then
  ENVOY_HEALTH=$(echo "$PROM_TARGETS" | python3 -c "
import json,sys
d=json.load(sys.stdin)
targets=[t for t in d.get('data',{}).get('activeTargets',[]) if t.get('labels',{}).get('job')=='envoy-sidecars']
up=[t for t in targets if t.get('health')=='up']
print(f'{len(up)}/{len(targets)} up')
" 2>/dev/null || echo "unknown")
  if echo "$ENVOY_HEALTH" | grep -vq "^0/"; then
    pass "Prometheus envoy-sidecars job: $ENVOY_HEALTH"
  else
    fail "Prometheus envoy-sidecars job targets are all down ($ENVOY_HEALTH) — check pod annotations + relabels"
  fi
else
  fail "Prometheus envoy-sidecars job not found in active targets"
fi

# ── 9. OTel Collector — no crash loops ───────────────────────────────────────
info "Checking OTel Collector for crash loops..."
OTEL_RESTARTS=$(kubectl get pod -n "$OBS_NS" -l app=otel-collector \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "unknown")
if [[ "$OTEL_RESTARTS" == "0" ]]; then
  pass "OTel Collector: 0 restarts (stable)"
elif [[ "$OTEL_RESTARTS" == "unknown" ]]; then
  fail "OTel Collector pod not found"
else
  warn "OTel Collector has $OTEL_RESTARTS restart(s) — check: kubectl logs -n $OBS_NS -l app=otel-collector --previous"
  ((FAIL++))
fi

# ── 10. Loki push endpoint ────────────────────────────────────────────────────
info "Checking Loki ready endpoint..."
LOKI_READY=$(kubectl exec -n "$OBS_NS" \
  "$(kubectl get pod -n "$OBS_NS" -l app=loki -o jsonpath='{.items[0].metadata.name}')" -- \
  wget -qO- "http://localhost:3100/ready" 2>/dev/null || echo "")
if echo "$LOKI_READY" | grep -qi "ready"; then
  pass "Loki is ready"
else
  fail "Loki /ready did not return 'ready' — check: kubectl logs -n $OBS_NS -l app=loki"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GREEN}ALL $TOTAL CHECKS PASSED${RESET}"
else
  echo -e "${RED}$FAIL/$TOTAL CHECKS FAILED${RESET}  (${PASS} passed)"
  echo ""
  echo "Troubleshooting:"
  echo "  kubectl get pods -A"
  echo "  kubectl logs -n $OBS_NS -l app=otel-collector --tail=50"
  echo "  kubectl logs -n $OBS_NS -l app=prometheus --tail=50"
  echo "  kubectl logs -n $OBS_NS -l app=loki --tail=50"
fi
echo "═══════════════════════════════════════════════════════════"
echo ""

[[ $FAIL -eq 0 ]]
