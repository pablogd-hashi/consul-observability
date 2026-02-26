#!/usr/bin/env bash
# scripts/kind-setup.sh
# Bootstrap a local kind cluster with the full Consul observability demo.
# Uses fake-service (nicholasjackson/fake-service) for the demo app topology:
#   web → api → [payments, cache]  where  payments → currency → rates (via TGW)
# Entry point: API Gateway (http://localhost:8080/) → web
#
# Prerequisites:
#   - kind    (https://kind.sigs.k8s.io)
#   - kubectl
#   - helm    (>= 3.x)
#   - docker
#   - consul  CLI (for keygen) — or openssl as fallback
#
# NOTE: If upgrading from a cluster without port 30004, run:
#   task k8s:down && task k8s:up

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
      - containerPort: 30004   # API Gateway
        hostPort: 8080
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

# ── 3.5. Install Kubernetes Gateway API CRDs ─────────────────────────────────
# Required by Consul API Gateway (values.yaml: apiGateway.enabled: true).
# Must be installed before the Consul Helm chart.
info "Installing Kubernetes Gateway API CRDs (v1.1.0)..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

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

# ── 6.5. Apply API Gateway resources ─────────────────────────────────────────
info "Applying API Gateway resources (GatewayClass, Gateway, HTTPRoute, TerminatingGateway)..."
kubectl apply -f "${REPO_ROOT}/kubernetes/consul/gateway/"

info "Waiting for API Gateway pod to be ready..."
kubectl wait --for=condition=ready pod -l component=api-gateway \
  -n "$CONSUL_NS" --timeout=120s \
  || warn "API Gateway pod not ready in time — check: kubectl get pods -n $CONSUL_NS"

info "Patching api-gateway Service to NodePort 30004 (maps to localhost:8080)..."
kubectl patch svc api-gateway -n "$CONSUL_NS" --type='json' \
  -p='[{"op":"replace","path":"/spec/type","value":"NodePort"},{"op":"add","path":"/spec/ports/0/nodePort","value":30004}]' \
  || warn "Could not patch api-gateway NodePort — patch manually if needed"

# ── 7. Apply Consul config entries (ProxyDefaults, ServiceDefaults, Intentions) ──
info "Waiting for Consul server to be ready for CRD operations..."
kubectl wait --for=condition=ready pod -l app=consul,component=server \
  -n "$CONSUL_NS" --timeout=120s || warn "Consul server may not be ready"

info "Applying ProxyDefaults (Envoy metrics :20200 + Zipkin tracing + stdout access logs)..."
kubectl apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/proxy-defaults.yaml"

info "Applying ServiceDefaults (protocol: http for fake-service topology)..."
kubectl apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/service-defaults-fake-service.yaml"

info "Applying ServiceIntentions (web→api→[payments,cache]→currency→rates allow-list)..."
kubectl apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/intentions-allow.yaml"

info "Config entries applied — waiting 10s for Consul to sync CRDs to xDS..."
sleep 10

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
info "  Topology: web → api → [payments, cache]  where  payments → currency → rates (external, via TGW)"

# Deploy leaf services first (no upstreams), then work up the chain
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/rates.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/currency.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/cache.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/payments.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/api.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/web.yaml"
kubectl apply -f "${REPO_ROOT}/kubernetes/services/fake-service/loadgenerator.yaml"

info "Waiting for fake-service pods to be ready..."
for svc in rates currency cache payments api web; do
  kubectl rollout status deployment/"$svc" -n "$DEMO_NS" --timeout=300s \
    || warn "${svc} did not become ready — check: kubectl logs -n ${DEMO_NS} -l app=${svc}"
done

# ── 10. Print next steps ─────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
info "K8s setup complete!"
echo "╠══════════════════════════════════════════════════════════════╣"
echo ""
echo "  Next step — start port-forwards and open the UIs:"
echo ""
echo "    task k8s:open        # starts all port-forwards + prints URLs"
echo "    task demo            # interactive fault-injection demo"
echo "    task demo:open       # open Grafana + Jaeger + Consul in browser"
echo ""
echo "  Manual port-forwards:"
echo "    kubectl port-forward svc/web          9090:9090   -n $DEMO_NS  &"
echo "    kubectl port-forward svc/consul-ui    8500:80     -n $CONSUL_NS &"
echo "    kubectl port-forward svc/grafana      3000:3000   -n $OBS_NS   &"
echo "    kubectl port-forward svc/jaeger-query 16686:16686 -n $OBS_NS   &"
echo "    kubectl port-forward svc/prometheus   9091:9090   -n $OBS_NS   &"
echo ""
echo "  App:"
echo "    curl http://localhost:8080/    → API Gateway → web→api→[payments,cache]→currency→rates"
echo "    curl http://localhost:9090/    → direct to web (bypass API Gateway)"
echo ""
echo "  Grafana dashboards (after port-forward):"
echo "    http://localhost:3000/d/ffbs6tb0gr4lcb  Service Health (errors, latency, rps)"
echo "    http://localhost:3000/d/service-to-service  Service-to-Service traffic"
echo "    http://localhost:3000/d/consul-health       Consul cluster health"
echo "    http://localhost:3000/d/envoy-access-logs   Envoy access logs (Loki)"
echo "    http://localhost:3000/d/consul-gateways     API Gateway + Terminating Gateway"
echo "    Credentials: admin / admin"
echo ""
echo "  ACL bootstrap token:"
echo "    kubectl get secret consul-bootstrap-acl-token -n $CONSUL_NS \\"
echo "      -o jsonpath='{.data.token}' | base64 --decode && echo"
echo "╚══════════════════════════════════════════════════════════════╝"
