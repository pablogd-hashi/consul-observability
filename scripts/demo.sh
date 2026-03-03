#!/usr/bin/env bash
# scripts/demo.sh
# ─────────────────────────────────────────────────────────────────────────────
# Interactive fault-injection demo for the Consul observability stack.
#
# Service topology:  web → api → [payments (→ currency → rates), cache]
#                   Entry:  API Gateway → web  (Docker: :21001  K8s: :18080)
#
# Usage (interactive):
#   ./scripts/demo.sh
#
# Usage (non-interactive — from Taskfile):
#   ./scripts/demo.sh --inject-errors  <service> <rate>     # 0.0–1.0
#   ./scripts/demo.sh --inject-latency <service> <latency>  # e.g. 500ms
#   ./scripts/demo.sh --reset
#   ./scripts/demo.sh --open
#
# Mode is auto-detected:
#   Docker  — docker compose running in ./docker/
#   Podman  — podman compose running in ./podman/
#   K8s     — kubectl can reach a cluster with fake-service pods
#   Override with: DEMO_MODE=docker  or  DEMO_MODE=podman  or  DEMO_MODE=k8s
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_DIR="$REPO_ROOT/docker"
DOCKER_ENV="$DOCKER_DIR/.env"
PODMAN_DIR="$REPO_ROOT/podman"
PODMAN_ENV="$PODMAN_DIR/.env"

SERVICES=(web api payments cache currency rates)

# ── Grafana dashboard UIDs ────────────────────────────────────────────────────
GRAFANA="${GRAFANA_URL:-http://localhost:3000}"
CONSUL_UI="${CONSUL_URL:-http://localhost:8500}"
JAEGER="${JAEGER_URL:-http://localhost:16686}"
PROM="${PROM_URL:-http://localhost:9090}"

UID_SERVICE_HEALTH="ffbs6tb0gr4lcb"
UID_SERVICE_TO_SERVICE="service-to-service"
UID_LOGS="envoy-access-logs"
UID_GATEWAYS="consul-gateways"

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD='\033[1m';    RESET='\033[0m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m';   BLUE='\033[0;34m'; DIM='\033[2m'; MAGENTA='\033[0;35m'

info()  { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()  { echo -e "  ${YELLOW}⚠${RESET} $*"; }
step()  { echo -e "  ${CYAN}▶${RESET} $*"; }
link()  { echo -e "  ${BLUE}🔗${RESET} ${BOLD}$1${RESET}"; }
note()  { echo -e "  ${DIM}$*${RESET}"; }
ruler() { echo -e "  ${DIM}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Mode detection ────────────────────────────────────────────────────────────
detect_mode() {
  if [[ -n "${DEMO_MODE:-}" ]]; then
    echo "$DEMO_MODE"
    return
  fi
  if docker compose -f "$DOCKER_DIR/docker-compose.yml" ps --status running \
      --format json 2>/dev/null | grep -q '"web"'; then
    echo "docker"
    return
  fi
  if podman compose -f "$PODMAN_DIR/podman-compose.yml" ps 2>/dev/null | grep -q "web"; then
    echo "podman"
    return
  fi
  # OpenShift (check for routes before plain K8s)
  if oc get routes -n observability 2>/dev/null | grep -q grafana; then
    echo "openshift"
    return
  fi
  if kubectl get pods -n default -l 'app in (web,api)' \
      --no-headers 2>/dev/null | grep -q Running; then
    echo "k8s"
    return
  fi
  echo "unknown"
}

# ── Fault injection — Docker ──────────────────────────────────────────────────
docker_set_env() {
  local service="$1"; local key="$2"; local val="$3"
  local prefix; prefix="${service^^}"
  local env_key="${prefix}_${key}"
  if grep -q "^${env_key}=" "$DOCKER_ENV" 2>/dev/null; then
    sed -i.bak "s|^${env_key}=.*|${env_key}=${val}|" "$DOCKER_ENV" && rm -f "${DOCKER_ENV}.bak"
  else
    echo "${env_key}=${val}" >> "$DOCKER_ENV"
  fi
}

docker_inject_errors() {
  local service="$1"; local rate="$2"
  docker_set_env "$service" "ERROR_RATE" "$rate"
  step "Restarting $service with ERROR_RATE=$rate ..."
  docker compose -f "$DOCKER_DIR/docker-compose.yml" \
    --env-file "$DOCKER_ENV" up -d --force-recreate "$service"
  info "$service restarting — will return ~$(printf '%.0f' "$(echo "$rate * 100" | bc -l)")% HTTP 500"
}

docker_inject_latency() {
  local service="$1"; local latency="$2"
  docker_set_env "$service" "LATENCY_P50" "$latency"
  docker_set_env "$service" "LATENCY_P90" "$latency"
  docker_set_env "$service" "LATENCY_P99" "$latency"
  step "Restarting $service with latency=${latency} ..."
  docker compose -f "$DOCKER_DIR/docker-compose.yml" \
    --env-file "$DOCKER_ENV" up -d --force-recreate "$service"
  info "$service restarting — will add ${latency} to every response"
}

docker_reset() {
  step "Resetting all fault injection ..."
  # Copy .env.example → .env for a guaranteed clean baseline (avoids stale values)
  cp "$DOCKER_DIR/.env.example" "$DOCKER_ENV"
  step "Restarting fake-service containers ..."
  docker compose -f "$DOCKER_DIR/docker-compose.yml" \
    --env-file "$DOCKER_ENV" up -d --force-recreate \
    web api payments cache currency rates
  info "All services reset to 0% errors / 1ms latency"
}

docker_status() {
  echo ""
  echo -e "  ${BOLD}Current fault injection${RESET}"
  echo ""
  for svc in "${SERVICES[@]}"; do
    local prefix="${svc^^}"
    local err; err=$(grep "^${prefix}_ERROR_RATE=" "$DOCKER_ENV" 2>/dev/null | cut -d= -f2 || echo "0")
    local lat; lat=$(grep "^${prefix}_LATENCY_P50=" "$DOCKER_ENV" 2>/dev/null | cut -d= -f2 || echo "1ms")
    if [[ "$err" != "0" ]] || [[ "$lat" != "1ms" ]]; then
      printf "  ${RED}%-12s${RESET}  error_rate=%-6s  p50_latency=%s  ${YELLOW}← FAULT${RESET}\n" "$svc" "$err" "$lat"
    else
      printf "  ${GREEN}%-12s${RESET}  error_rate=%-6s  p50_latency=%s\n" "$svc" "$err" "$lat"
    fi
  done
  echo ""
}

# ── Fault injection — Podman ──────────────────────────────────────────────────
podman_set_env() {
  local service="$1"; local key="$2"; local val="$3"
  local prefix; prefix="${service^^}"
  local env_key="${prefix}_${key}"
  # Seed .env from example if missing
  [[ -f "$PODMAN_ENV" ]] || cp "$PODMAN_DIR/.env.example" "$PODMAN_ENV"
  if grep -q "^${env_key}=" "$PODMAN_ENV" 2>/dev/null; then
    sed -i.bak "s|^${env_key}=.*|${env_key}=${val}|" "$PODMAN_ENV" && rm -f "${PODMAN_ENV}.bak"
  else
    echo "${env_key}=${val}" >> "$PODMAN_ENV"
  fi
}

podman_inject_errors() {
  local service="$1"; local rate="$2"
  podman_set_env "$service" "ERROR_RATE" "$rate"
  step "Restarting $service with ERROR_RATE=$rate ..."
  podman compose -f "$PODMAN_DIR/podman-compose.yml" \
    --env-file "$PODMAN_ENV" up -d --force-recreate "$service"
  info "$service restarting — will return ~$(printf '%.0f' "$(echo "$rate * 100" | bc -l)")% HTTP 500"
}

podman_inject_latency() {
  local service="$1"; local latency="$2"
  podman_set_env "$service" "LATENCY_P50" "$latency"
  podman_set_env "$service" "LATENCY_P90" "$latency"
  podman_set_env "$service" "LATENCY_P99" "$latency"
  step "Restarting $service with latency=${latency} ..."
  podman compose -f "$PODMAN_DIR/podman-compose.yml" \
    --env-file "$PODMAN_ENV" up -d --force-recreate "$service"
  info "$service restarting — will add ${latency} to every response"
}

podman_reset() {
  step "Resetting all fault injection ..."
  cp "$PODMAN_DIR/.env.example" "$PODMAN_ENV"
  step "Restarting fake-service containers ..."
  podman compose -f "$PODMAN_DIR/podman-compose.yml" \
    --env-file "$PODMAN_ENV" up -d --force-recreate \
    web api payments cache currency rates
  info "All services reset to 0% errors / 1ms latency"
}

podman_status() {
  echo ""
  echo -e "  ${BOLD}Current fault injection${RESET}"
  echo ""
  [[ -f "$PODMAN_ENV" ]] || cp "$PODMAN_DIR/.env.example" "$PODMAN_ENV"
  for svc in "${SERVICES[@]}"; do
    local prefix="${svc^^}"
    local err; err=$(grep "^${prefix}_ERROR_RATE=" "$PODMAN_ENV" 2>/dev/null | cut -d= -f2 || echo "0")
    local lat; lat=$(grep "^${prefix}_LATENCY_P50=" "$PODMAN_ENV" 2>/dev/null | cut -d= -f2 || echo "1ms")
    if [[ "$err" != "0" ]] || [[ "$lat" != "1ms" ]]; then
      printf "  ${RED}%-12s${RESET}  error_rate=%-6s  p50_latency=%s  ${YELLOW}← FAULT${RESET}\n" "$svc" "$err" "$lat"
    else
      printf "  ${GREEN}%-12s${RESET}  error_rate=%-6s  p50_latency=%s\n" "$svc" "$err" "$lat"
    fi
  done
  echo ""
}

# ── Fault injection — Kubernetes ──────────────────────────────────────────────
k8s_inject_errors() {
  local service="$1"; local rate="$2"
  step "Setting ERROR_RATE=$rate on deployment/$service ..."
  kubectl set env "deployment/$service" "ERROR_RATE=$rate" -n default
  info "$service updated (pod rolling restart in progress)"
}

k8s_inject_latency() {
  local service="$1"; local latency="$2"
  step "Setting TIMING latency=$latency on deployment/$service ..."
  kubectl set env "deployment/$service" \
    "TIMING_50_PERCENTILE=$latency" \
    "TIMING_90_PERCENTILE=$latency" \
    "TIMING_99_PERCENTILE=$latency" -n default
  info "$service updated (pod rolling restart in progress)"
}

k8s_reset() {
  step "Resetting all fake-service deployments ..."
  for svc in "${SERVICES[@]}"; do
    kubectl set env "deployment/$svc" \
      "ERROR_RATE=0" \
      "TIMING_50_PERCENTILE=1ms" \
      "TIMING_90_PERCENTILE=1ms" \
      "TIMING_99_PERCENTILE=1ms" -n default 2>/dev/null || true
  done
  info "Reset sent — run: kubectl rollout status deployment/web -n default"
}

k8s_status() {
  echo ""
  echo -e "  ${BOLD}Current fault injection${RESET}"
  echo ""
  for svc in "${SERVICES[@]}"; do
    local err; err=$(kubectl get deployment "$svc" -n default \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ERROR_RATE")].value}' 2>/dev/null || echo "0")
    local lat; lat=$(kubectl get deployment "$svc" -n default \
      -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="TIMING_50_PERCENTILE")].value}' 2>/dev/null || echo "1ms")
    err="${err:-0}"; lat="${lat:-1ms}"
    if [[ "$err" != "0" ]] || [[ "$lat" != "1ms" ]]; then
      printf "  ${RED}%-12s${RESET}  error_rate=%-6s  p50_latency=%s  ${YELLOW}← FAULT${RESET}\n" "$svc" "$err" "$lat"
    else
      printf "  ${GREEN}%-12s${RESET}  error_rate=%-6s  p50_latency=%s\n" "$svc" "$err" "$lat"
    fi
  done
  echo ""
}

# ── Fault injection — OpenShift ──────────────────────────────────────────────
# OpenShift uses oc (superset of kubectl) — same env-based fault injection as K8s
openshift_inject_errors() { k8s_inject_errors "$@"; }
openshift_inject_latency() { k8s_inject_latency "$@"; }
openshift_reset() { k8s_reset; }
openshift_status() { k8s_status; }

# ── Browser opener ────────────────────────────────────────────────────────────
open_url() {
  if command -v open &>/dev/null; then
    open "$1" 2>/dev/null || true
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$1" 2>/dev/null || true
  fi
}

print_urls() {
  local mode="$1"
  echo ""
  echo -e "  ${BOLD}Observability URLs${RESET}"
  echo ""
  link "$GRAFANA/d/${UID_SERVICE_HEALTH}     → Service Health  (error rate, P95 latency, RPS)"
  link "$GRAFANA/d/${UID_SERVICE_TO_SERVICE}  → Service Map     (node graph + trace waterfall)"
  link "$GRAFANA/d/${UID_LOGS}                → Access Logs     (Loki stream + Jaeger links)"
  link "$GRAFANA/d/${UID_GATEWAYS}            → Gateways        (API GW + Terminating GW metrics)"
  link "$JAEGER/search?service=web            → Jaeger          (distributed traces)"
  link "$CONSUL_UI/ui/dc1/services            → Consul UI       (service topology + intentions)"
  link "$PROM/graph                           → Prometheus      (raw metric explorer)"
  if [[ "$mode" == "docker" ]] || [[ "$mode" == "podman" ]]; then
    echo ""
    note "  App (direct Envoy):  curl http://localhost:21000/"
    note "  App (API Gateway):   curl http://localhost:21001/"
  elif [[ "$mode" == "openshift" ]]; then
    echo ""
    local web_host; web_host=$(oc get route web -n default -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    local gw_host; gw_host=$(oc get route api-gateway -n consul -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [[ -n "$web_host" ]] && note "  App (web Route):     curl -k https://$web_host/"
    [[ -n "$gw_host" ]]  && note "  App (API Gateway):   curl -k https://$gw_host/"
  else
    echo ""
    note "  App (direct svc):    curl http://localhost:9090/    (run: task k8s:open first)"
    note "  App (API Gateway):   curl http://localhost:18080/"
  fi
  echo ""
}

open_all() {
  step "Opening dashboards in browser..."
  open_url "$GRAFANA/d/${UID_SERVICE_HEALTH}"
  sleep 0.4
  open_url "$GRAFANA/d/${UID_SERVICE_TO_SERVICE}"
  sleep 0.4
  open_url "$GRAFANA/d/${UID_GATEWAYS}"
  sleep 0.4
  open_url "$JAEGER/search?service=web"
  sleep 0.4
  open_url "$CONSUL_UI/ui/dc1/services"
  info "Opened: Grafana Service Health, Service-to-Service, Gateways, Jaeger, Consul UI"
}

# ── Narrative explanations ────────────────────────────────────────────────────
explain_errors() {
  local service="$1"; local rate="$2"
  local pct; pct=$(printf '%.0f' "$(echo "$rate * 100" | bc -l)")
  ruler
  echo ""
  echo -e "  ${BOLD}How error injection works${RESET}"
  echo ""
  echo -e "  fake-service reads ${CYAN}ERROR_RATE=${rate}${RESET} and randomly fails ${BOLD}${pct}%${RESET} of"
  echo "  incoming requests with HTTP 500. The decision is made independently"
  echo "  for each request — there's no batching or pattern."
  echo ""
  echo -e "  ${BOLD}Grafana — where to look${RESET}"
  echo ""
  echo "  Service Health dashboard:"
  echo "    → 'Services with High Error Rate' panel"
  echo "       $service appears highlighted (threshold: > 1% error rate)"
  echo "    → Error rate formula:  5xx responses ÷ total responses ≈ ${rate}"
  echo ""
  echo "  Service-to-Service Traffic dashboard:"
  echo "    → \"Error Rate (%)\" stat card turns red"
  echo "    → \"Request Rate by Status Class\" chart: new 5xx line appears"
  echo ""
  echo -e "  ${BOLD}Jaeger — tracing a failed request${RESET}"
  echo ""
  echo "  1. Open Jaeger → Service: web → Tags: error=true → Find Traces"
  echo "  2. Click a trace — the waterfall shows where the error began:"
  echo ""
  echo "       web    [══════════════════════════════] ✗ 500"
  echo "        └─ api  [═══════════════════════] ✗ 500"
  echo "              └─ $service [══════════] ✗ 500  ← root cause"
  echo ""
  echo "  3. Click the $service span → Detail panel shows http.status_code=500"
  echo "  4. Errors propagate up — api and web also fail because there"
  echo "     are no retries configured (raw pass-through behaviour)"
  echo "  5. Compare a failing trace vs a passing one side by side:"
  echo "     failing spans appear red, successful spans appear green"
  echo ""
  echo -e "  ${BOLD}Prometheus — raw query to verify${RESET}"
  echo "  rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class=\\"5\\"}[1m])"
  echo ""
  ruler
  echo ""
}

explain_latency() {
  local service="$1"; local latency="$2"
  ruler
  echo ""
  echo -e "  ${BOLD}How latency injection works${RESET}"
  echo ""
  echo -e "  fake-service reads ${CYAN}TIMING_50_PERCENTILE=${latency}${RESET} (and P90, P99 set"
  echo "  to the same value) and sleeps for a random duration sampled from"
  echo "  a distribution that satisfies those percentile constraints."
  echo "  With P50=P90=P99=${latency}, essentially ALL requests wait ~${latency}."
  echo ""
  echo -e "  ${BOLD}What percentiles actually mean${RESET}"
  echo ""
  echo "  Percentiles describe the DISTRIBUTION of response times, not"
  echo "  just the average. The same total latency can look very different:"
  echo ""
  echo "   Metric  │ Meaning                         │ Example"
  echo "  ─────────┼─────────────────────────────────┼───────────────"
  echo "   P50     │ 50% of requests are faster      │ median = 1ms"
  echo "   P90     │ 90% of requests are faster      │ 1 in 10 is slow"
  echo "   P95     │ 95% of requests are faster      │ 1 in 20 is slow"
  echo "   P99     │ 99% of requests are faster      │ 1 in 100 is slow"
  echo "   P99.9   │ 999 in 1000 are faster          │ tail latency"
  echo ""
  echo "   Note: Why not just use averages?"
  echo "      99 requests take 1ms + 1 request takes 1s → average = 11ms"
  echo "      The average 'looks fine' but your P99 = 1s."
  echo "      1% of users wait a full second. Averages hide tail latency."
  echo ""
  echo -e "  ${BOLD}Grafana — where to look${RESET}"
  echo ""
  echo "  Service-to-Service Traffic dashboard:"
  echo "    → \"Response Time (P50 / P95 / P99)\" time series"
  echo "       All three lines rise. P99 may lag briefly while Envoy's"
  echo "       histogram buckets accumulate new observations."
  echo "    → \"P99 Latency (ms)\" stat card turns yellow then red"
  echo ""
  echo "  Envoy Access Logs dashboard:"
  echo "    → \"Response Time Distribution\" panel (P50/P95/P99 from Loki)"
  echo "       This uses Loki's quantile_over_time() on the 'duration' field"
  echo "       from Envoy's JSON access log — independent of Prometheus!"
  echo "       Both should show the same ${latency} baseline."
  echo ""
  echo -e "  ${BOLD}Jaeger — reading latency in traces${RESET}"
  echo ""
  echo "  1. Open Jaeger → Service: web → Find Traces"
  echo "  2. In the trace list, look at the 'Duration' column (far right)"
  echo "     Traces with $service latency show longer total duration"
  echo "  3. Click a trace → the waterfall:"
  echo ""
  echo "       web    [═══════════════════════════════════] ${latency}"
  echo "        └─ api  [══════════════════════════] ${latency}"
  echo "              └─ $service  [══════════] ← wider span = sleep"
  echo ""
  echo "  4. Hover a span → 'Duration' in the tooltip shows time in that span"
  echo "  5. The $service span is wider than its parent's other children"
  echo "     (payments vs cache, for example) if only one service is affected"
  echo ""
  echo -e "  ${BOLD}Prometheus — raw query${RESET}"
  echo "  histogram_quantile(0.99, sum(rate(envoy_cluster_upstream_rq_time_bucket[5m])) by (le))"
  echo ""
  ruler
  echo ""
}

explain_burst() {
  ruler
  echo ""
  echo -e "  ${BOLD}What just happened — load test${RESET}"
  echo ""
  echo "  Sent ~3 req/s for 30s through the Envoy proxy, on top of the"
  echo "  background load generator (~1.5 req/s). Total ≈ 4.5 req/s peak."
  echo ""
  echo -e "  ${BOLD}Grafana — where to look${RESET}"
  echo ""
  echo "  Service Health dashboard:"
  echo "    → \"Request Volume\" panel: spike visible in the time series"
  echo "    → Error rate stays at baseline (if no faults injected)"
  echo ""
  echo "  Service-to-Service Traffic dashboard:"
  echo "    → \"Request Rate (RPS)\" stat card: value rises during burst"
  echo "    → Request Rate by Status Class: 2xx spike in the chart"
  echo ""
  echo -e "  ${BOLD}Jaeger — correlating a burst${RESET}"
  echo ""
  echo "  1. Set Jaeger time range to 'Last 5 minutes'"
  echo "  2. Find Traces — more traces packed into the burst window"
  echo "  3. Traces should still succeed (short durations, green bars)"
  echo "  4. If you also have latency injected, burst traces show longer"
  echo "     durations — you're now generating both volume AND tail latency"
  echo ""
  ruler
  echo ""
}

explain_circuit_breaking() {
  local service="$1"
  ruler
  echo ""
  echo -e "  ${BOLD}How circuit breaking works${RESET}"
  echo ""
  echo -e "  Envoy tracks consecutive 5xx responses from each upstream. After"
  echo -e "  ${CYAN}3 consecutive failures${RESET}, it ejects the backend from the load"
  echo "  balancing pool for 30 seconds. During ejection, requests get"
  echo "  an immediate HTTP 503 from Envoy (no upstream call is made)."
  echo ""
  echo "  The $service service was injected with 100% errors. After 3"
  echo "  failures, Envoy opened the circuit. Subsequent requests fail"
  echo "  fast — no timeout, no waiting for upstream."
  echo ""
  echo -e "  ${BOLD}The distinctive circuit-open signature${RESET}"
  echo ""
  echo "  Compare these two states in Grafana Service Health:"
  echo ""
  echo "   State         Error rate   P95 latency"
  echo "  ──────────────────────────────────────────────"
  echo "   100% errors   100%         HIGH  (upstream responds slowly)"
  echo "   Circuit open  100%         LOW   (Envoy rejects instantly)"
  echo ""
  echo "  Error rate is 100% in both cases, but latency DROPS when the"
  echo "  circuit opens — that drop is Envoy taking over from the failing"
  echo "  backend and failing fast."
  echo ""
  echo -e "  ${BOLD}Prometheus — verify the circuit is open${RESET}"
  echo ""
  echo "  envoy_cluster_outlier_detection_ejections_active"
  echo "    → 1 means the backend is currently ejected"
  echo "    → 0 means Envoy is sending traffic (circuit closed)"
  echo ""
  echo -e "  ${BOLD}Jaeger — what ejected requests look like${RESET}"
  echo ""
  echo "  1. Open Jaeger → Service: web → Find Traces"
  echo "  2. Look at the 'Duration' column: ejected requests are"
  echo "     microseconds (Envoy rejects before any network round-trip)"
  echo "  3. The span shows http.status_code=503 with no child spans"
  echo "     (no call was forwarded to $service)"
  echo ""
  echo "  After 30s (base_ejection_time), Envoy sends one probe request."
  echo "  If $service is still failing, the ejection timer doubles."
  echo "  Run option 4 (Reset) to restore baseline and close the circuit."
  echo ""
  ruler
  echo ""
}

explain_reset() {
  ruler
  echo ""
  echo -e "  ${BOLD}What just happened — reset${RESET}"
  echo ""
  echo "  All services restored to baseline:"
  echo "    ERROR_RATE = 0       → no artificial errors"
  echo "    TIMING_P50 = 1ms     → effectively zero added latency"
  echo ""
  echo "  Grafana panels return to baseline within ~15–30 seconds as"
  echo "  new Prometheus scrapes arrive (scrape interval = 15s)."
  echo ""
  echo "  In Jaeger, new traces show:"
  echo "    → Short durations (sub-millisecond spans)"
  echo "    → All spans green (no errors)"
  echo "    → Normal call chain: web → api → [payments+cache] → currency"
  echo ""
  ruler
  echo ""
}

explain_gateway() {
  local mode="$1"
  ruler
  echo ""
  echo -e "  ${BOLD}What just happened — gateway load test${RESET}"
  echo ""
  echo "  Sent 30s of traffic through the API Gateway."
  echo "  The full path for each request:"
  echo ""
  if [[ "$mode" == "docker" ]]; then
    echo "    curl → API Gateway (:21001) → web → api → [payments, cache]"
    echo "                                              payments → currency"
    echo "                                              currency → TGW (:9190) → rates"
  else
    echo "    curl → API Gateway (:18080) → web → api → [payments, cache]"
    echo "                                            payments → currency"
    echo "                                            currency → transparent proxy → TGW → rates"
  fi
  echo ""
  echo -e "  ${BOLD}API Gateway panels (Consul Gateways dashboard)${RESET}"
  echo ""
  echo "  Request Rate:   total RPS entering via the API Gateway listener"
  echo "  Error Rate:     5xx responses from the gateway (not from upstreams)"
  echo "  P99 Latency:    end-to-end time at the gateway listener"
  echo "  Rate Limited:   requests dropped by the local rate limiter"
  echo "                  (Docker: 100 req/s fill, burst 200 — above that returns 429)"
  echo "                  Send > 100 req/s to make this panel non-zero."
  echo ""
  echo -e "  ${BOLD}Terminating Gateway panels${RESET}"
  echo ""
  echo "  External RPS:       calls forwarded to the external rates service"
  echo "  External Error Rate: errors from rates (set RATES_ERROR_RATE to inject)"
  echo "  Active Connections: open TCP connections to rates"
  echo ""
  echo "  The rates hop also appears in the Service-to-Service node graph as a"
  echo "  new node connected to currency — that extra hop is the TGW path."
  echo ""
  echo -e "  ${BOLD}How API Gateway differs from a sidecar${RESET}"
  echo ""
  echo "  Sidecars:    east-west traffic only (service to service inside the mesh)"
  echo "               one Envoy per pod, 1:1 with the app"
  echo "  API Gateway: north-south traffic (external client into the mesh)"
  echo "               shared Envoy, single entry point for all clients"
  echo "               can enforce auth, rate limiting, routing rules at the edge"
  echo ""
  echo "  Terminating Gateway: controlled mesh exit point"
  echo "               mesh services reach external/legacy services through it"
  echo "               mTLS terminates at the TGW; the last mile to rates is plain HTTP"
  echo "               only services with an allow intention can reach rates"
  echo ""
  echo -e "  ${BOLD}Prometheus queries to explore${RESET}"
  echo ""
  echo "  envoy_http_downstream_rq_total{job=\"api-gateway\"}"
  echo "    → total requests received by the API Gateway"
  echo "  envoy_cluster_upstream_rq_total{job=\"terminating-gateway\"}"
  echo "    → total calls proxied by the TGW to rates"
  echo "  envoy_http_local_rate_limiter_rate_limited{job=\"api-gateway\"}"
  echo "    → requests dropped by the local rate limiter"
  echo ""
  ruler
  echo ""
}

validate_service() {
  local svc="$1"
  for s in "${SERVICES[@]}"; do
    [[ "$s" == "$svc" ]] && return 0
  done
  return 1
}

# ── Non-interactive CLI dispatch ──────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
  MODE=$(detect_mode)
  case "$1" in
    --inject-errors)
      SERVICE="${2:?Usage: demo.sh --inject-errors <service> <rate>}"
      RATE="${3:?Usage: demo.sh --inject-errors <service> <rate>}"
      if   [[ "$MODE" == "docker" ]]; then docker_inject_errors "$SERVICE" "$RATE"
      elif [[ "$MODE" == "podman" ]]; then podman_inject_errors "$SERVICE" "$RATE"
      elif [[ "$MODE" == "openshift" ]]; then openshift_inject_errors "$SERVICE" "$RATE"
      else k8s_inject_errors "$SERVICE" "$RATE"; fi
      ;;
    --inject-latency)
      SERVICE="${2:?Usage: demo.sh --inject-latency <service> <latency>}"
      LATENCY="${3:?Usage: demo.sh --inject-latency <service> <latency>}"
      if   [[ "$MODE" == "docker" ]]; then docker_inject_latency "$SERVICE" "$LATENCY"
      elif [[ "$MODE" == "podman" ]]; then podman_inject_latency "$SERVICE" "$LATENCY"
      elif [[ "$MODE" == "openshift" ]]; then openshift_inject_latency "$SERVICE" "$LATENCY"
      else k8s_inject_latency "$SERVICE" "$LATENCY"; fi
      ;;
    --reset)
      if   [[ "$MODE" == "docker" ]]; then docker_reset
      elif [[ "$MODE" == "podman" ]]; then podman_reset
      elif [[ "$MODE" == "openshift" ]]; then openshift_reset
      else k8s_reset; fi
      ;;
    --open)
      open_all "$MODE"
      print_urls "$MODE"
      ;;
    *)
      echo "Usage: demo.sh [--inject-errors <svc> <rate>] [--inject-latency <svc> <dur>] [--reset] [--open]"
      exit 1
      ;;
  esac
  exit 0
fi

# ── Interactive mode ──────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       Consul Service Mesh Observability — Demo               ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${CYAN}Topology:${RESET}  API GW → web → api → [payments (→ currency → rates),  cache]"
echo ""

MODE=$(detect_mode)
case "$MODE" in
  docker)    echo -e "  ${GREEN}Mode: Docker Compose${RESET}  — API GW (:21001) + TGW (:9190) + sidecar Envoy" ;;
  podman)    echo -e "  ${GREEN}Mode: Podman Compose${RESET}  — API GW (:21001) + TGW (:9190) + sidecar Envoy" ;;
  k8s)       echo -e "  ${GREEN}Mode: Kubernetes${RESET}     — API GW (:18080) + TGW + per-service Envoy sidecars" ;;
  openshift) echo -e "  ${GREEN}Mode: OpenShift${RESET}      — Routes + TGW + per-service Envoy sidecars (CRC)" ;;
  *)
    warn "Could not detect a running stack."
    echo ""
    echo "  Start the demo first:"
    echo "    Docker:     task docker:up"
    echo "    Podman:     task podman:up"
    echo "    K8s:        task k8s:up"
    echo "    OpenShift:  task openshift:up"
    echo ""
    exit 1
    ;;
esac

echo ""
ruler
echo ""
echo -e "  ${BOLD}Three observability pillars${RESET}"
echo ""
echo -e "  ${MAGENTA}Metrics${RESET}  Prometheus scrapes Envoy /stats/prometheus every 15s"
echo "           → Grafana shows error rate, latency (P50/P95/P99), RPS"
echo "           → Consul metrics: health checks, RPC rate, cluster membership"
echo ""
echo -e "  ${YELLOW}Traces ${RESET}  Envoy generates Zipkin B3 spans → OTel Collector → Jaeger"
echo "           → Each HTTP request = one trace spanning all service hops"
echo "           → See timing at each hop, which call failed, propagation"
echo ""
echo -e "  ${GREEN}Logs   ${RESET}  Envoy writes JSON access logs → OTel filelog → Loki"
echo "           → method, path, response_code, duration (ms), upstream_host"
echo "           → traceparent field links each log line to its Jaeger trace"
echo ""
ruler

while true; do
  echo ""
  if   [[ "$MODE" == "docker" ]]; then docker_status
  elif [[ "$MODE" == "podman" ]]; then podman_status
  elif [[ "$MODE" == "openshift" ]]; then openshift_status
  else k8s_status; fi

  echo -e "  ${BOLD}Choose an action:${RESET}"
  echo ""
  echo "    1) Inject errors       (e.g. payments fails 30% of requests → HTTP 500)"
  echo "    2) Inject latency      (e.g. api adds 500ms sleep per request)"
  echo "    3) Load test           (30s of fast requests → spike in metrics)"
  echo "    4) Reset all faults    (back to 0 errors, 1ms latency)"
  echo "    5) Circuit breaking    (100% errors → Envoy ejects backend → 503s)"
  echo "    6) Gateway load test   (30s through API Gateway → TGW → rates path)"
  echo "    7) Show URLs"
  echo "    8) Open all UIs in browser"
  echo "    q) Quit"
  echo ""
  echo -en "  ${CYAN}›${RESET} "
  read -r CHOICE

  case "$CHOICE" in

    1)
      echo ""
      echo -n "  Service [web / api / payments / cache / currency / rates]: "
      read -r SVC
      if ! validate_service "$SVC"; then
        warn "Unknown service '$SVC'  (choices: web api payments cache currency rates)"
        continue
      fi
      echo -n "  Error rate [0.0–1.0  e.g. 0.3 = 30% fail]: "
      read -r RATE
      echo ""
      if   [[ "$MODE" == "docker" ]]; then docker_inject_errors "$SVC" "$RATE"
      elif [[ "$MODE" == "podman" ]]; then podman_inject_errors "$SVC" "$RATE"
      elif [[ "$MODE" == "openshift" ]]; then openshift_inject_errors "$SVC" "$RATE"
      else k8s_inject_errors "$SVC" "$RATE"; fi
      explain_errors "$SVC" "$RATE"
      link "$GRAFANA/d/${UID_SERVICE_HEALTH}  → Service Health (error rate panel)"
      link "$JAEGER/search?service=web&tags=error%3Dtrue  → Jaeger error=true"
      echo ""
      ;;

    2)
      echo ""
      echo -n "  Service [web / api / payments / cache / currency / rates]: "
      read -r SVC
      if ! validate_service "$SVC"; then
        warn "Unknown service '$SVC'  (choices: web api payments cache currency rates)"
        continue
      fi
      echo -n "  Latency [e.g. 200ms / 500ms / 1s / 2s]: "
      read -r LAT
      echo ""
      if   [[ "$MODE" == "docker" ]]; then docker_inject_latency "$SVC" "$LAT"
      elif [[ "$MODE" == "podman" ]]; then podman_inject_latency "$SVC" "$LAT"
      elif [[ "$MODE" == "openshift" ]]; then openshift_inject_latency "$SVC" "$LAT"
      else k8s_inject_latency "$SVC" "$LAT"; fi
      explain_latency "$SVC" "$LAT"
      link "$GRAFANA/d/${UID_SERVICE_TO_SERVICE}  → Service-to-Service (P50/P95/P99 panel)"
      link "$JAEGER/search?service=web             → Jaeger (compare span widths)"
      echo ""
      ;;

    3)
      echo ""
      if   [[ "$MODE" == "docker" ]]; then TARGET="http://localhost:21000/"
      elif [[ "$MODE" == "podman" ]]; then TARGET="http://localhost:21000/"
      elif [[ "$MODE" == "openshift" ]]; then TARGET="https://$(oc get route web -n default -o jsonpath='{.spec.host}' 2>/dev/null)/"
      else TARGET="http://localhost:9090/"; fi
      step "Sending burst traffic for 30s to $TARGET ..."
      END=$(($(date +%s) + 30)); COUNT=0
      while [[ $(date +%s) -lt $END ]]; do
        curl -skf --max-time 2 "$TARGET" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
        curl -skf --max-time 2 "$TARGET" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
        curl -skf --max-time 2 "$TARGET" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
      done
      info "Sent $COUNT requests"
      explain_burst
      link "$GRAFANA/d/${UID_SERVICE_HEALTH}  → Service Health (Request Volume)"
      link "$JAEGER/search?service=web         → Jaeger (recent trace list)"
      echo ""
      ;;

    4)
      echo ""
      if   [[ "$MODE" == "docker" ]]; then docker_reset
      elif [[ "$MODE" == "podman" ]]; then podman_reset
      elif [[ "$MODE" == "openshift" ]]; then openshift_reset
      else k8s_reset; fi
      explain_reset
      link "$GRAFANA/d/${UID_SERVICE_HEALTH}  → Watch error rate return to 0"
      echo ""
      ;;

    5)
      echo ""
      # Docker/Podman: eject web (the only backend behind Envoy)
      # K8s: eject payments (called by api, has currency downstream)
      if   [[ "$MODE" == "docker" ]]; then
        CB_SERVICE="web"; TARGET="http://localhost:21000/"
        docker_inject_errors "$CB_SERVICE" "1"
      elif [[ "$MODE" == "podman" ]]; then
        CB_SERVICE="web"; TARGET="http://localhost:21000/"
        podman_inject_errors "$CB_SERVICE" "1"
      elif [[ "$MODE" == "openshift" ]]; then
        CB_SERVICE="payments"; TARGET="https://$(oc get route web -n default -o jsonpath='{.spec.host}' 2>/dev/null)/"
        openshift_inject_errors "$CB_SERVICE" "1"
      else
        CB_SERVICE="payments"; TARGET="http://localhost:9090/"
        k8s_inject_errors "$CB_SERVICE" "1"
      fi
      step "Sending 20 requests to trigger circuit breaker ejection..."
      COUNT=0
      for i in $(seq 1 20); do
        curl -skf --max-time 2 "$TARGET" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
      done
      info "Sent 20 requests ($COUNT succeeded)"
      explain_circuit_breaking "$CB_SERVICE"
      link "$GRAFANA/d/${UID_SERVICE_HEALTH}  → Service Health (error rate + latency drop)"
      echo "  Prometheus query: envoy_cluster_outlier_detection_ejections_active"
      echo ""
      ;;

    6)
      echo ""
      if   [[ "$MODE" == "docker" ]] || [[ "$MODE" == "podman" ]]; then GATEWAY_URL="http://localhost:21001/"
      elif [[ "$MODE" == "openshift" ]]; then GATEWAY_URL="https://$(oc get route api-gateway -n consul -o jsonpath='{.spec.host}' 2>/dev/null)/"
      else GATEWAY_URL="http://localhost:18080/"; fi
      step "Sending gateway load test for 30s to $GATEWAY_URL ..."
      END=$(($(date +%s) + 30)); COUNT=0
      while [[ $(date +%s) -lt $END ]]; do
        curl -skf --max-time 3 "$GATEWAY_URL" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
        curl -skf --max-time 3 "$GATEWAY_URL" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
        curl -skf --max-time 3 "$GATEWAY_URL" -o /dev/null 2>/dev/null && COUNT=$((COUNT+1)) || true
      done
      info "Sent $COUNT requests through the API Gateway"
      explain_gateway "$MODE"
      link "$GRAFANA/d/${UID_GATEWAYS}            → Consul Gateways (API GW + TGW metrics)"
      link "$GRAFANA/d/${UID_SERVICE_TO_SERVICE}  → Service-to-Service (rates node in graph)"
      echo ""
      ;;

    7)
      print_urls "$MODE"
      ;;

    8)
      open_all "$MODE"
      print_urls "$MODE"
      ;;

    q|Q|quit|exit)
      echo ""
      info "Demo session ended."
      echo ""
      break
      ;;

    *)
      warn "Unknown choice: '$CHOICE'"
      ;;
  esac
done
