#!/usr/bin/env bash
# scripts/openshift-setup.sh
# Bootstrap OpenShift Local (CRC) with the full Consul observability demo.
# Uses fake-service (nicholasjackson/fake-service) for the demo app topology:
#   web → api → [payments, cache]  where  payments → currency → rates (via TGW)
# Entry point: API Gateway Route → web
#
# Prerequisites:
#   - crc     (https://console.redhat.com/openshift/create/local)
#   - oc      (ships with crc — `eval $(crc oc-env)`)
#   - helm    (>= 3.x)
#
# Before running this script, CRC must be installed, configured and started:
#   crc setup                        # one-time setup
#   crc config set memory 14336      # 14 GB — required for OCP + demo stack
#   crc config set disk-size 50      # 50 GB — required for container images + logs
#   crc start                        # start the VM
#   eval $(crc oc-env)               # add oc to PATH
#
# Usage:
#   ./scripts/openshift-setup.sh          # full setup
#   SKIP_CONSUL=1 ./scripts/openshift-setup.sh  # skip Consul install (re-deploy apps only)

set -euo pipefail

CONSUL_NS="consul"
OBS_NS="observability"
DEMO_NS="default"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

# ── 0. Preflight checks ─────────────────────────────────────────────────────
info "Running preflight checks..."

command -v oc   &>/dev/null || err "oc CLI not found. Run: eval \$(crc oc-env)"
command -v helm &>/dev/null || err "helm not found. Install: https://helm.sh/docs/intro/install/"

# Verify CRC is running and we can reach the API
if ! oc whoami &>/dev/null; then
  warn "Not logged into OpenShift. Attempting login with kubeadmin..."
  CRC_CONSOLE_URL=$(crc console --url 2>/dev/null || echo "")
  if [[ -z "$CRC_CONSOLE_URL" ]]; then
    err "CRC does not appear to be running. Start it with: crc start"
  fi
  API_URL=$(echo "$CRC_CONSOLE_URL" | sed 's|https://console-openshift-console|https://api|;s|$|:6443|')
  KUBEADMIN_PW=$(crc console --credentials 2>/dev/null | grep kubeadmin | sed 's/.*password is //' | sed 's/ .*//' | tr -d "'")
  oc login "$API_URL" -u kubeadmin -p "$KUBEADMIN_PW" --insecure-skip-tls-verify=true \
    || err "Could not log in to CRC. Check: crc status"
fi

info "Connected to OpenShift: $(oc whoami --show-server)"

# Check available memory on the node
ALLOC_MEM_KI=$(oc get node crc -o jsonpath='{.status.allocatable.memory}' 2>/dev/null | tr -d 'Ki')
if [[ -n "$ALLOC_MEM_KI" ]]; then
  ALLOC_MEM_MI=$((ALLOC_MEM_KI / 1024))
  if (( ALLOC_MEM_MI < 12000 )); then
    warn "CRC node has only ${ALLOC_MEM_MI}Mi allocatable memory."
    warn "The demo stack needs at least 14 GB. Run:"
    warn "  crc config set memory 14336"
    warn "  crc stop && crc start"
    err "Insufficient memory on CRC node (${ALLOC_MEM_MI}Mi < 12000Mi)"
  fi
  info "CRC node memory: ${ALLOC_MEM_MI}Mi allocatable"
fi

# ── 1. Create namespaces ────────────────────────────────────────────────────
info "Creating namespaces..."
for ns in "$CONSUL_NS" "$OBS_NS"; do
  oc create namespace "$ns" --dry-run=client -o yaml | oc apply -f -
done

# ── 2. SCC permissions ──────────────────────────────────────────────────────
# Consul and observability workloads need the anyuid SCC to run as non-root
# with specific UIDs. On production clusters, create a custom SCC instead.
info "Granting anyuid SCC to service accounts..."
for ns in "$CONSUL_NS" "$OBS_NS" "$DEMO_NS"; do
  oc adm policy add-scc-to-group anyuid "system:serviceaccounts:${ns}" 2>/dev/null || true
done

# Promtail needs hostPath access to /var/log/pods for pod log scraping.
# On OCP, CRI-O log directories require privileged SCC (hostmount-anyuid is
# not enough — the directory itself has restrictive permissions).
info "Granting privileged SCC to promtail..."
oc create serviceaccount promtail -n "$OBS_NS" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user privileged -z promtail -n "$OBS_NS" 2>/dev/null || true

# ── 3. Gossip encryption key ────────────────────────────────────────────────
info "Creating gossip encryption Secret..."
if oc get secret consul-gossip-key -n "$CONSUL_NS" &>/dev/null; then
  warn "Secret consul-gossip-key already exists — skipping"
else
  if command -v consul &>/dev/null; then
    GOSSIP_KEY="$(consul keygen)"
  else
    warn "consul CLI not found — using openssl to generate gossip key"
    GOSSIP_KEY="$(openssl rand -base64 32)"
  fi
  oc create secret generic consul-gossip-key \
    --from-literal=key="${GOSSIP_KEY}" \
    -n "$CONSUL_NS"
  info "Gossip encryption key created"
fi

# ── 4. Install Consul ───────────────────────────────────────────────────────
if [[ "${SKIP_CONSUL:-}" == "1" ]]; then
  warn "SKIP_CONSUL=1 — skipping Consul Helm install"
else
  info "Installing Consul with OpenShift overrides..."
  helm upgrade --install consul hashicorp/consul \
    --namespace "$CONSUL_NS" \
    --values "${REPO_ROOT}/kubernetes/consul/values.yaml" \
    --values "${REPO_ROOT}/openshift/consul/values.yaml" \
    --timeout 5m
fi

# ── 5. Deploy observability stack in parallel while Consul finishes ─────────
info "Deploying observability stack (in parallel with Consul bootstrap)..."
oc create namespace "$OBS_NS" --dry-run=client -o yaml | oc apply -f -

info "Waiting for Consul bootstrap ACL token..."
until oc get secret consul-bootstrap-acl-token -n "$CONSUL_NS" &>/dev/null; do sleep 2; done

info "Copying Consul ACL token to observability namespace..."
CONSUL_TOKEN=$(oc get secret consul-bootstrap-acl-token -n "$CONSUL_NS" \
  -o jsonpath='{.data.token}' | base64 --decode)
oc create secret generic consul-bootstrap-acl-token \
  --from-literal=token="${CONSUL_TOKEN}" \
  -n "$OBS_NS" \
  --dry-run=client -o yaml | oc apply -f -

oc apply -f "${REPO_ROOT}/kubernetes/observability/"

# ── 6. Wait for Consul server, then apply config entries ────────────────────
info "Waiting for Consul server to be ready..."
oc wait --for=condition=ready pod -l app=consul,component=server \
  -n "$CONSUL_NS" --timeout=300s || warn "Consul server may not be ready"

info "Applying Consul config entries (ProxyDefaults, ServiceDefaults, Intentions)..."
oc apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/proxy-defaults.yaml"
oc apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/service-defaults-fake-service.yaml"
oc apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/intentions-allow.yaml"

# ── 7. Apply API Gateway resources ──────────────────────────────────────────
info "Applying API Gateway resources (Gateway, HTTPRoute, TerminatingGateway)..."
oc apply -f "${REPO_ROOT}/kubernetes/consul/gateway/"

# ── 7.5. Register 'rates' as an external service in Consul catalog ──────────
# rates runs outside the mesh (no sidecar) and syncCatalog is disabled, so
# we register it manually so the Terminating Gateway can route to it.
info "Registering 'rates' as external service in Consul catalog..."
oc exec consul-server-0 -n "$CONSUL_NS" -- sh -c \
  "curl -sf -X PUT -H 'X-Consul-Token: ${CONSUL_TOKEN}' \
   http://localhost:8500/v1/catalog/register -d '{
     \"Node\": \"external-rates\",
     \"Address\": \"rates.default.svc.cluster.local\",
     \"Service\": {
       \"Service\": \"rates\",
       \"Port\": 9090,
       \"Address\": \"rates.default.svc.cluster.local\"
     }
   }'" \
  || warn "Could not register rates in Consul catalog"

# ── 8. Deploy ALL fake-service manifests in one shot ────────────────────────
info "Deploying fake-service topology (namespace: $DEMO_NS)..."
info "  Topology: web → api → [payments, cache]  where  payments → currency → rates (external, via TGW)"
oc apply -f "${REPO_ROOT}/kubernetes/services/fake-service/"

# ── 9. Wait for everything in parallel ─────────────────────────────────────
info "Waiting for observability stack..."
oc rollout status deployment -l 'app in (loki,otel-collector,prometheus,jaeger,grafana)' \
  -n "$OBS_NS" --timeout=180s \
  || warn "Some observability pods did not become ready — check: oc get pods -n ${OBS_NS}"
oc rollout status daemonset/promtail -n "$OBS_NS" --timeout=60s \
  || warn "promtail did not become ready in time"

info "Waiting for API Gateway..."
oc wait --for=condition=ready pod -l component=api-gateway \
  -n "$CONSUL_NS" --timeout=120s \
  || warn "API Gateway pod not ready in time — check: oc get pods -n $CONSUL_NS"

info "Waiting for fake-service pods..."
for svc in rates currency cache payments api web; do
  oc rollout status deployment/"$svc" -n "$DEMO_NS" --timeout=300s \
    || warn "${svc} did not become ready — check: oc logs -n ${DEMO_NS} -l app=${svc}"
done

# ── 10. Create OpenShift Routes ───────────────────────────────────────────
info "Creating OpenShift Routes..."
oc apply -f "${REPO_ROOT}/openshift/services/"
oc apply -f "${REPO_ROOT}/openshift/consul/route.yaml" 2>/dev/null \
  || warn "Consul UI route not created"

# ── 11. Print next steps ─────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
info "OpenShift setup complete!"
echo "╠══════════════════════════════════════════════════════════════╣"
echo ""
echo "  Routes:"

for route in grafana jaeger prometheus web consul-ui api-gateway; do
  NS="$OBS_NS"
  [[ "$route" == "web" ]] && NS="$DEMO_NS"
  [[ "$route" == "consul-ui" || "$route" == "api-gateway" ]] && NS="$CONSUL_NS"
  URL=$(oc get route "$route" -n "$NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
  if [[ -n "$URL" ]]; then
    printf "    %-20s https://%s\n" "$route" "$URL"
  fi
done

echo ""
echo "  Run the demo:"
echo "    task demo            # interactive fault-injection"
echo "    task validate        # health check + URLs"
echo ""
echo "  ACL bootstrap token:"
echo "    oc get secret consul-bootstrap-acl-token -n $CONSUL_NS \\"
echo "      -o jsonpath='{.data.token}' | base64 --decode && echo"
echo "╚══════════════════════════════════════════════════════════════╝"
