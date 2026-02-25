#!/usr/bin/env bash
# scripts/minikube-setup.sh
# Bootstrap a minikube cluster with the full Consul observability demo.
#
# Prerequisites:
#   - minikube (>= 1.30)
#   - kubectl
#   - helm (>= 3.x)

set -euo pipefail

PROFILE="${MINIKUBE_PROFILE:-consul-observability}"
DRIVER="${MINIKUBE_DRIVER:-docker}"
CONSUL_NS="consul"
OBS_NS="observability"
DEMO_NS="demo"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }

# ── 1. Start minikube ────────────────────────────────────────────────────────
info "Starting minikube profile: $PROFILE"
minikube start \
  --profile "$PROFILE" \
  --driver "$DRIVER" \
  --cpus 4 \
  --memory 8192 \
  --kubernetes-version stable

eval "$(minikube docker-env --profile "$PROFILE")"

# ── 2. Build images directly into minikube's Docker ─────────────────────────
info "Building demo service images into minikube..."
for svc in example-app backend-api db-api; do
  docker build -q -t "consul-local-observability-${svc}:latest" \
    "${REPO_ROOT}/docker/services/${svc}"
  info "  Built: consul-local-observability-${svc}:latest"
done

# ── 3. Helm + Consul ────────────────────────────────────────────────────────
info "Adding Helm repos..."
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo update

kubectl create namespace "$CONSUL_NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install consul hashicorp/consul \
  --namespace "$CONSUL_NS" \
  --values "${REPO_ROOT}/kubernetes/consul/values.yaml" \
  --wait --timeout 5m

kubectl apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/" -n "$CONSUL_NS"

# ── 4. Observability + services ─────────────────────────────────────────────
kubectl create namespace "$OBS_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/kubernetes/observability/"

kubectl create namespace "$DEMO_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${REPO_ROOT}/kubernetes/services/"

# ── 5. minikube tunnel for service access ───────────────────────────────────
echo ""
info "Setup complete! Run the following to access services:"
echo ""
echo "  minikube service grafana -n $OBS_NS --profile $PROFILE"
echo "  minikube service jaeger-query -n $OBS_NS --profile $PROFILE"
echo "  minikube service prometheus -n $OBS_NS --profile $PROFILE"
echo "  minikube service consul-ui -n $CONSUL_NS --profile $PROFILE"
