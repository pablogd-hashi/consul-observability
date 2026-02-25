#!/usr/bin/env bash
# scripts/demo.sh
# ─────────────────────────────────────────────────────────────────────────────
# Interactive guided demo of Consul service-mesh observability.
#
# Chapters:
#   0  Pre-flight   — validate the stack is healthy before starting
#   1  The Mesh     — show the live service topology in Consul UI
#   2  Metrics      — Grafana Data Plane Health & Performance dashboards
#   3  Traffic      — generate load, watch Grafana update in real time
#   4  Traces       — distributed trace walkthrough in Jaeger
#   5  Logs         — Envoy access logs in Loki, trace_id correlation
#   6  Fault        — inject product-api failure, watch 5xx spike everywhere
#   7  Recovery     — restore the service, watch the mesh self-heal
#
# Usage:
#   ./scripts/demo.sh                  # start from Chapter 0
#   ./scripts/demo.sh --chapter 3      # jump to a specific chapter
#   ./scripts/demo.sh --no-browser     # skip auto-open of browser URLs

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
CONSUL_NS="consul"
OBS_NS="observability"
DEMO_NS="default"
BASE_URL="${BASE_URL:-http://localhost:8080}"
GRAFANA="${GRAFANA_URL:-http://localhost:3000}"
JAEGER="${JAEGER_URL:-http://localhost:16686}"
PROM="${PROM_URL:-http://localhost:9090}"
CONSUL_UI="${CONSUL_URL:-http://localhost:8500}"

CHAPTER="${2:-0}"
NO_BROWSER=false

for arg in "$@"; do
  case $arg in
    --no-browser) NO_BROWSER=true ;;
    --chapter)    CHAPTER="${2:-0}" ;;
  esac
done

# ── Colours & formatting ──────────────────────────────────────────────────────
BOLD='\033[1m';    RESET='\033[0m'
GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m';   BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
DIM='\033[2m'

DEMO_PASS=0
DEMO_FAIL=0

# ── Helpers ───────────────────────────────────────────────────────────────────
chapter() {
  local num=$1; local title=$2; local color=$3
  echo ""
  echo -e "${color}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
  printf "${color}${BOLD}║  Chapter %-2s: %-32s║${RESET}\n" "$num" "$title"
  echo -e "${color}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
  echo ""
}

step() { echo -e "  ${CYAN}▶${RESET} $*"; }
info() { echo -e "  ${GREEN}✓${RESET} $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET} $*"; }
fail() { echo -e "  ${RED}✗${RESET} $*"; }
note() { echo -e "  ${DIM}$*${RESET}"; }
link() { echo -e "  ${BLUE}🔗 ${BOLD}$1${RESET}  ${DIM}$2${RESET}"; }
query(){ echo -e "  ${MAGENTA}⌕  Query:${RESET}  ${BOLD}$*${RESET}"; }

pause() {
  local msg="${1:-Press ENTER to continue...}"
  echo ""
  echo -e "  ${DIM}────────────────────────────────────────────${RESET}"
  echo -en "  ${YELLOW}▶  $msg${RESET} "
  read -r
}

open_url() {
  if [[ "$NO_BROWSER" == "false" ]]; then
    if command -v open &>/dev/null; then
      open "$1" 2>/dev/null || true
    elif command -v xdg-open &>/dev/null; then
      xdg-open "$1" 2>/dev/null || true
    fi
  fi
}

kubectl_exec_prom() {
  # Run a command inside the Prometheus pod
  local pod
  pod=$(kubectl get pod -n "$OBS_NS" -l app=prometheus \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  [[ -z "$pod" ]] && return 1
  kubectl exec -n "$OBS_NS" "$pod" -- "$@" 2>/dev/null
}

# ── Background traffic worker ─────────────────────────────────────────────────
TRAFFIC_PID=""

start_traffic() {
  local duration="${1:-999999}"
  (
    local end=$(($(date +%s) + duration))
    local endpoints=("/" "/api" "/api/coffees" "/api/ingredients/1" "/api/ingredients/2")
    while [[ $(date +%s) -lt $end ]]; do
      for ep in "${endpoints[@]}"; do
        curl -sf --max-time 3 --connect-timeout 2 "${BASE_URL}${ep}" \
          -o /dev/null 2>/dev/null || true
      done
      sleep 0.4
    done
  ) &
  TRAFFIC_PID=$!
}

stop_traffic() {
  if [[ -n "$TRAFFIC_PID" ]]; then
    kill "$TRAFFIC_PID" 2>/dev/null || true
    wait "$TRAFFIC_PID" 2>/dev/null || true
    TRAFFIC_PID=""
  fi
}

# ── Cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
  stop_traffic
  # Ensure product-api is restored if demo was interrupted mid-fault
  local replicas
  replicas=$(kubectl get deployment product-api -n "$DEMO_NS" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
  if [[ "$replicas" == "0" ]]; then
    echo ""
    warn "Restoring product-api (was scaled to 0 during fault injection)..."
    kubectl scale deployment product-api -n "$DEMO_NS" --replicas=1 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 0: Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
chapter 0 "Pre-flight Check" "$GREEN"

echo "  Verifying the observability stack before we start the demo."
echo ""

# Check kubectl is connected
if ! kubectl cluster-info &>/dev/null; then
  fail "kubectl cannot reach the cluster. Run 'task k8s-setup' first."
  exit 1
fi
info "kubectl connected to cluster"

# Check all HashiCups pods
READY_COUNT=0
for svc in nginx frontend public-api product-api product-api-db payments; do
  READY=$(kubectl get pods -n "$DEMO_NS" -l "app=$svc" \
    -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
  if echo "$READY" | grep -q "true"; then
    READY_COUNT=$((READY_COUNT + 1))
  else
    warn "$svc not ready yet"
  fi
done
info "$READY_COUNT/6 HashiCups services ready"

# Check observability pods
OBS_COUNT=0
for dep in loki otel-collector prometheus jaeger grafana; do
  R=$(kubectl get deployment "$dep" -n "$OBS_NS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  [[ "${R:-0}" -ge 1 ]] && OBS_COUNT=$((OBS_COUNT + 1))
done
info "$OBS_COUNT/5 observability services ready"

# Check the app is reachable
if curl -sf --max-time 5 --connect-timeout 3 "${BASE_URL}/" -o /dev/null 2>/dev/null; then
  info "HashiCups UI reachable at $BASE_URL"
else
  warn "HashiCups UI not reachable at $BASE_URL"
  echo ""
  note "  You may need to port-forward first:"
  note "    kubectl port-forward svc/nginx 8080:80 -n $DEMO_NS &"
  note "    kubectl port-forward svc/consul-ui 8500:80 -n $CONSUL_NS &"
  note "    kubectl port-forward svc/grafana 3000:3000 -n $OBS_NS &"
  note "    kubectl port-forward svc/jaeger-query 16686:16686 -n $OBS_NS &"
  note "    kubectl port-forward svc/prometheus 9090:9090 -n $OBS_NS &"
fi

if [[ $READY_COUNT -lt 6 || $OBS_COUNT -lt 5 ]]; then
  echo ""
  warn "Stack is not fully ready. The demo may be incomplete."
  pause "Press ENTER to continue anyway, or Ctrl-C to wait and retry..."
else
  echo ""
  info "All systems go! Let's start the demo."
  pause "Press ENTER to begin..."
fi

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 1: The Mesh — Service Topology
# ─────────────────────────────────────────────────────────────────────────────
chapter 1 "The Service Mesh" "$CYAN"

echo "  HashiCups is a microservices app running inside the Consul service mesh."
echo "  Every service has an Envoy sidecar proxy injected automatically."
echo ""
echo "  Call graph:"
echo ""
echo -e "    ${CYAN}User${RESET}"
echo -e "      └──▶ ${BOLD}nginx${RESET}  (reverse proxy)"
echo -e "              ├──▶ ${BOLD}frontend${RESET}  (React UI)"
echo -e "              └──▶ ${BOLD}public-api${RESET}  (GraphQL)"
echo -e "                       ├──▶ ${BOLD}product-api${RESET}  (catalog)"
echo -e "                       │         └──▶ ${BOLD}product-api-db${RESET}  (PostgreSQL)"
echo -e "                       └──▶ ${BOLD}payments${RESET}  (payment service)"
echo ""
echo "  Each arrow is an mTLS-encrypted, Consul-intention-controlled connection."
echo "  Each hop generates Envoy metrics, access logs, and Zipkin traces."

step "Showing live pods..."
echo ""
kubectl get pods -n "$DEMO_NS" \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,STATUS:.status.phase' \
  2>/dev/null | head -20 || true

echo ""
echo "  Each pod shows '2/2' — the app container + the Envoy (consul-dataplane) sidecar."
echo ""

link "$CONSUL_UI/ui/dc1/services" "→ Consul UI — Service list"
echo ""
echo "  In Consul UI you can see:"
echo "    • All 6 services registered in the mesh"
echo "    • mTLS certificates issued per service"
echo "    • Intentions controlling which services can talk to which"

open_url "$CONSUL_UI/ui/dc1/services"
pause "Explore the Consul UI, then press ENTER for Grafana metrics..."

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 2: Metrics — Data Plane Dashboards
# ─────────────────────────────────────────────────────────────────────────────
chapter 2 "Metrics: Envoy Proxy Dashboards" "$MAGENTA"

echo "  Prometheus scrapes Envoy's merged metrics endpoint on port 20200/metrics"
echo "  from every sidecar in the mesh. Grafana visualises them on two dashboards."
echo ""
echo "  Dashboard 1: Data Plane Health"
echo "    — Are all services up?  What's the upstream success rate?"
echo ""
echo "  Dashboard 2: Data Plane Performance"
echo "    — Requests/s, P50/P99 latency, 5xx error rate per service"

echo ""
step "Checking Prometheus target health..."
CONSUL_UP=$(kubectl_exec_prom wget -qO- \
  "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22consul%22%7D" \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
up=[x for x in r if x['value'][1]=='1']
print(f'{len(up)}/{len(r)} targets up')
" 2>/dev/null || echo "unknown")

ENVOY_UP=$(kubectl_exec_prom wget -qO- \
  "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22envoy-sidecars%22%7D" \
  2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=d.get('data',{}).get('result',[])
up=[x for x in r if x['value'][1]=='1']
print(f'{len(up)}/{len(r)} targets up')
" 2>/dev/null || echo "unknown")

info "consul targets:       $CONSUL_UP"
info "envoy-sidecars:       $ENVOY_UP"

echo ""
link "$GRAFANA/d/data-plane-health" "→ Data Plane Health dashboard"
link "$GRAFANA/d/data-plane-performance" "→ Data Plane Performance dashboard"

open_url "$GRAFANA/d/data-plane-health"

echo ""
echo "  What to look for in Data Plane Health:"
echo "    • 'Running services' gauge — should show 6"
echo "    • 'Upstream success rate' — should be ~100% (no traffic yet)"
echo "    • All services green in the topology view"
echo ""
echo "  What to look for in Data Plane Performance:"
echo "    • Request rate per service — near zero (we haven't sent traffic yet)"
echo "    • We'll come back here after generating load in Chapter 3"

pause "Press ENTER to start generating traffic..."

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 3: Traffic — Real requests through the mesh
# ─────────────────────────────────────────────────────────────────────────────
chapter 3 "Traffic: Load Generation" "$BLUE"

echo "  Starting background traffic — 3 workers hitting 5 endpoints every 400ms."
echo "  This generates realistic Envoy metrics, access logs, and traces."
echo ""
echo "  Endpoints:"
echo "    GET /                   (nginx → frontend)"
echo "    GET /api                (nginx → public-api)"
echo "    GET /api/coffees        (nginx → public-api → product-api → product-api-db)"
echo "    GET /api/ingredients/1  (nginx → public-api → product-api → product-api-db)"
echo "    GET /api/ingredients/2  (nginx → public-api → product-api → product-api-db)"

echo ""
start_traffic
info "Traffic running (PID $TRAFFIC_PID)"

echo ""
echo "  Give it ~30 seconds to populate the dashboards, then:"
echo ""
link "$GRAFANA/d/data-plane-performance" "→ Data Plane Performance — watch requests/s climb"
link "$GRAFANA/d/data-plane-health" "→ Data Plane Health — upstream success rate stays 100%"
link "${PROM}/graph?g0.expr=envoy_cluster_upstream_rq_total%7Bjob%3D%22envoy-sidecars%22%7D" \
  "→ Prometheus — raw envoy_cluster_upstream_rq_total metric"

open_url "$GRAFANA/d/data-plane-performance"

echo ""
echo "  Key metrics now visible in Grafana:"
echo "    • envoy_cluster_upstream_rq_total     — request count per upstream"
echo "    • envoy_cluster_upstream_cx_active    — active connections"
echo "    • envoy_http_downstream_rq_2xx        — success rate"
echo "    • consul_mesh_active_root_ca_expiry   — mTLS certificate health"

pause "Press ENTER to explore distributed traces in Jaeger..."

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 4: Traces — Distributed Tracing in Jaeger
# ─────────────────────────────────────────────────────────────────────────────
chapter 4 "Traces: Distributed Tracing (Jaeger)" "$YELLOW"

echo "  Every request through the mesh generates an Envoy Zipkin trace."
echo "  OTel Collector receives them and forwards to Jaeger via OTLP."
echo ""
echo "  Tracing pipeline:"
echo ""
echo -e "    ${CYAN}Envoy sidecars${RESET}  (Zipkin B3 format)"
echo -e "      └──▶ ${BOLD}OTel Collector :9411${RESET}  (Zipkin receiver)"
echo -e "               └──▶ ${BOLD}traces/proxy pipeline${RESET}"
echo -e "                        ├── k8sattributes  (adds pod/namespace metadata)"
echo -e "                        ├── attributes     (marks telemetry.source=envoy-proxy)"
echo -e "                        └── otlp/jaeger exporter"
echo -e "                                └──▶ ${BOLD}Jaeger :4317${RESET}  (OTLP)"

echo ""
step "Fetching recent trace sample from Jaeger..."
TRACE_RESULT=$(kubectl exec -n "$OBS_NS" \
  "$(kubectl get pod -n "$OBS_NS" -l app=jaeger -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" -- \
  wget -qO- "http://localhost:16686/api/services" 2>/dev/null || echo "")

if echo "$TRACE_RESULT" | grep -q '"data"'; then
  SERVICES=$(echo "$TRACE_RESULT" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(', '.join(sorted(d.get('data',[]))))" 2>/dev/null || echo "unknown")
  info "Services registered in Jaeger: $SERVICES"
else
  info "Jaeger is running — services will appear after first traces are processed"
fi

echo ""
link "$JAEGER/search?service=nginx&limit=20" "→ Jaeger — traces from nginx (entry point)"
echo ""
echo "  Instructions:"
echo "    1. Select service: nginx in the search panel"
echo "    2. Click 'Find Traces' — you'll see recent requests"
echo "    3. Click any trace to expand the waterfall:"
echo ""
echo "       nginx.proxy                         [───────────────────────]"
echo "         └─ public-api.proxy               [──────────────]"
echo "               ├─ product-api.proxy        [──────────]"
echo "               │    └─ product-api-db.proxy [───────]"
echo "               └─ payments.proxy           [─────]"
echo ""
echo "    4. Each span shows:"
echo "       • Duration at each hop"
echo "       • HTTP method/URL/status"
echo "       • Kubernetes pod + namespace labels (from k8sattributes)"
echo "       • consul.mesh.name tag"

open_url "$JAEGER/search?service=nginx&limit=20"
pause "Press ENTER to explore Loki logs + trace correlation..."

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 5: Logs — Envoy Access Logs in Loki
# ─────────────────────────────────────────────────────────────────────────────
chapter 5 "Logs: Envoy Access Logs (Loki)" "$GREEN"

echo "  Envoy access logs flow two ways:"
echo ""
echo -e "  ${BOLD}Path 1: OTel access logging extension${RESET}"
echo "    Each sidecar ships OTLP log records to OTel Collector (gRPC)."
echo "    Configured via envoyExtensions: builtin/otel-access-logging"
echo "    in each ServiceDefaults. OTel Collector forwards to Loki."
echo ""
echo -e "  ${BOLD}Path 2: Promtail (stdout scraping)${RESET}"
echo "    Envoy access logs also go to stdout (ProxyDefaults accessLogs.type: stdout)."
echo "    Promtail DaemonSet scrapes /var/log/pods/**/*.log from every node"
echo "    and ships to Loki. JSON pipeline stage extracts trace_id field."
echo ""
echo "  This gives you two complementary log streams in Loki."

echo ""
step "Checking Loki..."
LOKI_READY=$(kubectl exec -n "$OBS_NS" \
  "$(kubectl get pod -n "$OBS_NS" -l app=loki -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" -- \
  wget -qO- "http://localhost:3100/ready" 2>/dev/null || echo "")
echo "$LOKI_READY" | grep -qi "ready" && info "Loki is ready" || warn "Loki status: $LOKI_READY"

echo ""
link "$GRAFANA/explore?orgId=1&left=%7B%22datasource%22:%22loki%22%7D" \
  "→ Grafana Explore — Loki datasource"
echo ""
echo "  Step-by-step in Grafana Explore:"
echo ""
echo "  1. Select datasource: Loki"
echo "  2. Run this query to see all proxy access logs:"
query '{namespace="default"} | json'
echo ""
echo "  3. Filter to a specific service:"
query '{namespace="default", app="public-api"} | json'
echo ""
echo "  4. Filter by HTTP status:"
query '{namespace="default"} | json | status_code >= 200 and status_code < 300'
echo ""
echo "  5. Find a trace_id in a log line, then:"
echo "     • Click the 'Jaeger' link icon on the log line"
echo "     • It jumps directly to that trace in Jaeger!"
echo "     (This works because Loki has derivedFields linking traceparent → Jaeger)"
echo ""
echo "  6. Live tail — click 'Live' to stream access logs in real time:"
query '{namespace="default", app="nginx"} | json'

open_url "$GRAFANA/explore?orgId=1&left=%7B%22datasource%22:%22loki%22%7D"
pause "Press ENTER to inject a fault and watch the mesh respond..."

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 6: Fault Injection — Break product-api
# ─────────────────────────────────────────────────────────────────────────────
chapter 6 "Fault Injection: Chaos Engineering" "$RED"

echo "  We're about to simulate a production outage:"
echo ""
echo -e "    Scale ${BOLD}product-api${RESET} to ${RED}0 replicas${RESET}"
echo ""
echo "  Effect on HashiCups:"
echo "    • GET /api/coffees    → 503 (product-api unreachable)"
echo "    • GET /api/ingredients → 503 (same)"
echo "    • GET /               → 200 (frontend still serves static UI)"
echo ""
echo "  What we'll see in observability:"
echo -e "  ${MAGENTA}Metrics:${RESET}  envoy_cluster_upstream_rq_5xx spike in Grafana Data Plane Performance"
echo -e "  ${YELLOW}Traces:${RESET}   ERROR spans on nginx → public-api hops in Jaeger"
echo -e "  ${GREEN}Logs:${RESET}     status_code=503 lines in Loki"

echo ""
link "$GRAFANA/d/data-plane-performance" "→ Grafana — keep this open and watch the 5xx panel"
link "$JAEGER/search?service=nginx&tags=%7B%22error%22%3A%22true%22%7D" \
  "→ Jaeger — filter for error=true spans"

open_url "$GRAFANA/d/data-plane-performance"

pause "Press ENTER to INJECT THE FAULT (product-api → 0 replicas)..."

echo ""
step "Injecting fault: scaling product-api to 0..."
kubectl scale deployment product-api -n "$DEMO_NS" --replicas=0
info "product-api scaled to 0 replicas"

echo ""
echo "  Traffic is still running. Give it ~15-20 seconds for the metrics to update."
echo ""
echo "  Watch in Grafana Data Plane Performance:"
echo "    • '5xx Error Rate' panel — should jump from 0% to ~60-80%"
echo "    • Request rate drops on product-api upstreams"
echo "    • public-api and nginx upstream error metrics climb"
echo ""
echo "  Watch in Jaeger:"
echo "    • Search service=nginx, add tag error=true"
echo "    • Traces show nginx→public-api succeeds but public-api→product-api fails"
echo "    • The failing span has status_code=503 and error=true"
echo ""
echo "  Watch in Loki:"
query '{namespace="default"} | json | status_code >= 500'

FAULT_START=$(date +%s)
pause "Press ENTER when you've seen the 5xx spike, to begin recovery..."

# ─────────────────────────────────────────────────────────────────────────────
# CHAPTER 7: Recovery — Self-healing mesh
# ─────────────────────────────────────────────────────────────────────────────
chapter 7 "Recovery: The Mesh Self-Heals" "$GREEN"

FAULT_DURATION=$(( $(date +%s) - FAULT_START ))
echo "  The fault lasted ${FAULT_DURATION} seconds."
echo ""
echo "  Restoring product-api to 1 replica..."

kubectl scale deployment product-api -n "$DEMO_NS" --replicas=1
info "product-api scaled back to 1 replica"

echo ""
step "Waiting for product-api to become ready..."
kubectl rollout status deployment/product-api -n "$DEMO_NS" --timeout=120s \
  && info "product-api is ready!" \
  || warn "product-api taking longer than expected — check: kubectl logs -n $DEMO_NS -l app=product-api"

echo ""
echo "  Watch the mesh recover in real time:"
echo "    • Grafana 5xx rate drops back to 0"
echo "    • Jaeger — new traces succeed end-to-end"
echo "    • Loki — status_code=200 lines resume"
echo ""
echo "  Consul's health checks detected the pod coming back automatically."
echo "  No config changes needed — the mesh rebalances itself."

echo ""
echo "  A few metrics worth checking now that we have fault + recovery in the dataset:"
echo ""
echo "  In Prometheus (raw queries):"
query 'rate(envoy_cluster_upstream_rq_5xx{job="envoy-sidecars"}[5m])'
query 'histogram_quantile(0.99, rate(envoy_cluster_upstream_rq_time_bucket{job="envoy-sidecars"}[5m]))'
echo ""
link "$PROM/graph?g0.expr=rate(envoy_cluster_upstream_rq_5xx%7Bjob%3D%22envoy-sidecars%22%7D%5B1m%5D)" \
  "→ Prometheus — 5xx rate over time"

pause "Press ENTER to see the demo summary..."

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
stop_traffic

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                  Demo Complete — Summary                     ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${MAGENTA}Metrics ${RESET}   Envoy proxy metrics scraped via :20200/metrics"
echo -e "             Visualised in Grafana Data Plane Health & Performance"
echo -e "             Prometheus query: ${DIM}envoy_cluster_upstream_rq_total${RESET}"
echo ""
echo -e "  ${YELLOW}Traces  ${RESET}   Zipkin B3 traces from every Envoy sidecar"
echo -e "             OTel Collector enriches with k8s metadata → Jaeger"
echo -e "             Full call graph: nginx→public-api→product-api→db"
echo ""
echo -e "  ${GREEN}Logs    ${RESET}   Envoy access logs via otel-access-logging extension"
echo -e "             + Promtail DaemonSet scraping pod stdout"
echo -e "             trace_id in logs links directly to Jaeger traces"
echo ""
echo -e "  ${RED}Fault   ${RESET}   product-api → 0 replicas"
echo -e "             5xx spike visible in metrics + traces + logs simultaneously"
echo -e "             Recovery automatic when pod restored — no mesh config change"
echo ""
echo "  ──────────────────────────────────────────────────────────"
echo ""
echo "  All observability data stays correlated via trace IDs:"
echo ""
echo "   [Grafana metric panel] → [Loki log line with trace_id] → [Jaeger trace]"
echo ""
echo "  ──────────────────────────────────────────────────────────"
echo ""
echo "  Bookmarks for exploration:"
link "$BASE_URL" "HashiCups App"
link "$CONSUL_UI/ui/dc1/services" "Consul UI — Services"
link "$GRAFANA/d/data-plane-health" "Grafana — Data Plane Health"
link "$GRAFANA/d/data-plane-performance" "Grafana — Data Plane Performance"
link "$JAEGER/search?service=nginx" "Jaeger — nginx traces"
link "$GRAFANA/explore?orgId=1&left=%7B%22datasource%22:%22loki%22%7D" "Grafana — Loki Explore"
link "$PROM/graph" "Prometheus — Raw metrics"
echo ""
