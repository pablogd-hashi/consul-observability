#!/usr/bin/env bash
# scripts/ocp-setup.sh
# Deploy the Consul observability demo to an existing OpenShift cluster.
#
# Prerequisites:
#   - oc (OpenShift CLI), logged in to target cluster
#   - helm (>= 3.x)
#   - Image registry accessible to OCP (or images pushed to internal registry)

set -euo pipefail

CONSUL_NS="consul"
OBS_NS="observability"
DEMO_NS="demo"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[INFO]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }

# ── Verify OCP login ─────────────────────────────────────────────────────────
oc whoami > /dev/null || { echo "ERROR: not logged in to OpenShift"; exit 1; }
info "Logged in as: $(oc whoami) on $(oc whoami --show-server)"

# ── Push images to OCP internal registry ─────────────────────────────────────
REGISTRY=$(oc get route default-route -n openshift-image-registry \
  --template='{{ .spec.host }}' 2>/dev/null || echo "")

if [[ -n "$REGISTRY" ]]; then
  info "Internal registry: $REGISTRY"
  oc create namespace "$DEMO_NS" --dry-run=client -o yaml | oc apply -f -
  docker login -u "$(oc whoami)" -p "$(oc whoami -t)" "$REGISTRY"
  for svc in example-app backend-api db-api; do
    docker build -q -t "${REGISTRY}/${DEMO_NS}/consul-local-observability-${svc}:latest" \
      "${REPO_ROOT}/docker/services/${svc}"
    docker push "${REGISTRY}/${DEMO_NS}/consul-local-observability-${svc}:latest"
    info "  Pushed: ${svc}"
  done
else
  warn "Could not detect OCP internal registry route."
  warn "Please push images manually and update kubernetes/services/*.yaml image references."
fi

# ── SCCs for Consul ───────────────────────────────────────────────────────────
info "Granting required SCCs for Consul..."
oc create namespace "$CONSUL_NS" --dry-run=client -o yaml | oc apply -f -
oc adm policy add-scc-to-user anyuid -z consul-server -n "$CONSUL_NS" 2>/dev/null || true
oc adm policy add-scc-to-user anyuid -z consul -n "$CONSUL_NS" 2>/dev/null || true

# ── Helm install Consul ───────────────────────────────────────────────────────
info "Installing Consul (OpenShift mode)..."
helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
helm repo update
helm upgrade --install consul hashicorp/consul \
  --namespace "$CONSUL_NS" \
  --values "${REPO_ROOT}/kubernetes/consul/values.yaml" \
  --values "${REPO_ROOT}/openshift/consul/values.yaml" \
  --wait --timeout 5m

oc apply -f "${REPO_ROOT}/kubernetes/consul/config-entries/" -n "$CONSUL_NS"

# ── Observability stack ───────────────────────────────────────────────────────
info "Deploying observability stack..."
oc create namespace "$OBS_NS" --dry-run=client -o yaml | oc apply -f -
oc apply -f "${REPO_ROOT}/kubernetes/observability/"
# OCP Routes for observability UIs
oc apply -f "${REPO_ROOT}/openshift/services/grafana.yaml"
oc apply -f "${REPO_ROOT}/openshift/services/jaeger.yaml"

# ── Demo services ─────────────────────────────────────────────────────────────
info "Deploying demo services..."
oc create namespace "$DEMO_NS" --dry-run=client -o yaml | oc apply -f -
oc apply -f "${REPO_ROOT}/kubernetes/services/"
oc apply -f "${REPO_ROOT}/openshift/services/example-app.yaml"

# ── Print routes ─────────────────────────────────────────────────────────────
echo ""
info "Setup complete! Routes:"
oc get routes -n "$OBS_NS" 2>/dev/null || true
oc get routes -n "$DEMO_NS" 2>/dev/null || true
