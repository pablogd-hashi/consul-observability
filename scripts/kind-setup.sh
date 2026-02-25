#!/usr/bin/env bash
# scripts/kind-setup.sh
# Bootstrap a local kind cluster with the full Consul observability demo.
# Uses fake-service (nicholasjackson/fake-service) for the demo app topology:
#   web → api → [payments, cache]  where  payments → currency
#
# Prerequisites:
#   - kind    (https://kind.sigs.k8s.io)
#   - kubectl
#   - helm    (>= 3.x)
#   - docker
#   - consul  CLI (for keygen) — or openssl as fallback

set -euo pipefail

CLUSTER_NAME="${KIND_CLUSTER:-consul-observability}"
CONSUL_NS="consul"
OBS_NS="observability"
DEMO_NS="default"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }

# ── 1. Create kind cluster ───────────────────────────────────────────────────
info "Creating kind cluster: $CLUSTER_NAME"
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster $CLUSTER_NAME already exists — skipping creation"
else
  cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 30000   # Consul UI
        hostPort: 8500
        protocol: TCP
      - containerPort: 30001   # Grafana
        hostPort: 3000
        protocol: TCP
      - containerPort: 30002   # Jaeger UI
        hostPort: 16686
        protocol: TCP
      - containerPort: 30003   # Prometheus
        hostPort: 9090
        protocol: TCP
EOF
fi

# ── 2. Pre-pull fake-service image into kind (speeds up pod startup) ─────────
info "Pre-pulling fake-service image into kind node..."
docker pull -q nicholasjackson/fake-service:v0.26.2 \
  && kind load docker-image nicholasjackson/fake-service:v0.26.2 --name "$CLUSTER_NAME" \
  || warn "Could not pre-load fake-service — pods will pull from registry"

# ── 3. Add Helm repos ────────────────────────────────────────────────────────
info "Adding Helm repos..."
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo update

# ── 4. Generate gossip encryption key and store as a Secret ─────────────────
info "Creating consul namespace and gossip encryption Secret..."
kubectl create namespace "$CONSUL_NS" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret consul-gossip-key -n "$CONSUL_NS" &>/dev/null; then
  warn "Secret consul-gossip-key already exists — skipping"
else
  # Use consul CLI if available, otherwise fall back to openssl
  if command -v consul &>/dev/null; then
    GOSSIP_KEY="$(consul keygen)"
  else
    warn "consul CLI not found — using openssl to generate gossip key"
    GOSSIP_KEY="$(openssl rand -base64 32)"
  fi
  kubectl create secret generic consul-gossip-key \
    --from-literal=key="${GOSSIP_KEY}" \
    -n "$CONSUL_NS"
  info "  Gossip encryption key created (Secret: consul-gossip-key)"
fi

# ── 5. Install Consul ────────────────────────────────────────────────────────
info "Installing Consul..."
helm upgrade --install consul hashicorp/consul \
  --namespace "$CONSUL_NS" \
  --values "${REPO_ROOT}/kubernetes/consul/values.yaml" \
  --wait --timeout 5m

# ── 6. Bootstrap ACL token (only on first install) ──────────────────────────
info "ACL bootstrap token is in Secret 'consul-bootstrap-acl-token' (namespace: $CONSUL_NS)"

# ── 7. Allow all service-to-service intentions ──────────────────────────────
info "Creating Consul intentions (allow all)..."
# Wait for Consul to be fully ready before applying intentions
kubectl wait --for=condition=ready pod -l app=consul,component=server \
  -n "$CONSUL_NS" --timeout=120s || warn "Consul server may not be ready"

# Apply allow-all intention via kubectl exec (no CRD needed for simple allow-all)
kubectl exec -n "$CONSUL_NS" consul-server-0 -- \
  consul intention create -allow '*' '*' 2>/dev/null \
  || warn "Could not create intentions — they may already exist or ACLs need a token"

# ── 8. Deploy observability stack ────────────────────────────────────────────
info "Deploying observability stack..."
kubectl create namespace "$OBS_NS" --dry-run=client -o yaml | kubectl apply -f -

info "Copying Consul ACL token to observability namespace..."
CONSUL_TOKEN=$(kubectl get secret consul-bootstrap-acl-token -n "$CONSUL_NS" \
  -o jsonpath='{.data.token}' | base64 --decode)
kubectl create secret generic consul-bootstrap-acl-token \
  --from-literal=token="${CONSUL_TOKEN}" \
  -n "$OBS_NS" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${REPO_ROOT}/kubernetes/observability/"

for deploy in loki otel-collector prometheus jaeger grafana; do
  info "Waiting for ${deploy} to be ready..."
  kubectl rollout status deployment/"$deploy" -n "$OBS_NS" --timeout=120s \
    || warn "${deploy} did not become ready in time — check: kubectl logs -n ${OBS_NS} -l app=${deploy}"
done

info "Waiting for promtail DaemonSet to be ready..."
kubectl rollout status daemonset/promtail -n "$OBS_NS" --timeout=60s \
  || warn "promtail did not become ready in time"

# ── 9. Deploy fake-service topology ──────────────────────────────────────────
info "Deploying fake-service topology (namespace: $DEMO_NS)..."
info "  Topology: web → api → [payments, cache]  where  payments → currency"

# Deploy leaf services first (no upstreams), then work up the chain
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/currency.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/cache.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/payments.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/api.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/web.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/loadgenerator.yaml"

info "Waiting for fake-service pods to be ready..."
for svc in currency cache payments api web; do
  kubectl rollout status deployment/"$svc" -n "$DEMO_NS" --timeout=300s \
    || warn "${svc} did not become ready — check: kubectl logs -n ${DEMO_NS} -l app=${svc}"
done

# ── 10. Print endpoints ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
info "Setup complete! Run the following to access services:"
echo ""
echo "  Fake-Service (web):  kubectl port-forward svc/web 9090:9090 -n $DEMO_NS"
echo "  Consul UI:           kubectl port-forward svc/consul-ui 8500:80 -n $CONSUL_NS"
echo "  Grafana:             kubectl port-forward svc/grafana 3000:3000 -n $OBS_NS"
echo "  Jaeger UI:           kubectl port-forward svc/jaeger-query 16686:16686 -n $OBS_NS"
echo "  Prometheus:          kubectl port-forward svc/prometheus 9090:9090 -n $OBS_NS"
echo ""
echo "  Or start all at once (background):"
echo "    kubectl port-forward svc/web 9090:9090 -n $DEMO_NS &"
echo "    kubectl port-forward svc/consul-ui 8500:80 -n $CONSUL_NS &"
echo "    kubectl port-forward svc/grafana 3000:3000 -n $OBS_NS &"
echo "    kubectl port-forward svc/jaeger-query 16686:16686 -n $OBS_NS &"
echo "    kubectl port-forward svc/prometheus 9090:9090 -n $OBS_NS &"
echo ""
echo "  App endpoints:"
echo "    curl http://localhost:9090/       → full call chain (web→api→payments→currency + cache)"
echo "    curl http://localhost:9090/ui     → fake-service topology UI"
echo ""
echo "  Observability:"
echo "    Consul UI:    http://localhost:8500    (service health + topology)"
echo "    Grafana:      http://localhost:3000    (admin / admin)"
echo "      → Service-to-Service Traffic dashboard"
echo "      → Consul Service Health dashboard"
echo "      → Envoy Access Logs dashboard"
echo "    Jaeger:       http://localhost:16686   (search service: web)"
echo "    Prometheus:   http://localhost:9090"
echo ""
echo "  ACL bootstrap token:"
echo "    kubectl get secret consul-bootstrap-acl-token -n $CONSUL_NS \\"
echo "      -o jsonpath='{.data.token}' | base64 --decode && echo"
echo "═══════════════════════════════════════════════════════════"
