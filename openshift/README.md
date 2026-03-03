# OpenShift Local (CRC)

Deploys the full Consul observability demo on OpenShift Local (CRC). Reuses all Kubernetes manifests from `kubernetes/` and layers OpenShift-specific configuration on top: Routes, SCCs, and Consul Helm `global.openshift.enabled`.

## Key differences from other flavours

| Aspect | OpenShift | K8s (kind) | Docker/Podman |
|--------|-----------|------------|---------------|
| Cluster | CRC (single-node OpenShift) | kind (K8s in Docker) | Docker/Podman Compose |
| CLI | `oc` (superset of `kubectl`) | `kubectl` | `docker`/`podman` compose |
| Exposure | Routes (TLS edge termination) | NodePort + port-forward | Localhost ports |
| Security | SCCs (anyuid granted to namespaces) | Default PSPs | N/A |
| Consul TLS | `verify: false` (OCP internal CA) | `verify: true` | N/A |
| API Gateway | ClusterIP + Route | NodePort 30004 | Static Envoy JSON `:21001` |
| Storage | Cluster default (crc-csi-hostpath) | Cluster default | Docker volumes |
| Envoy sidecars | 1 per pod (Consul Connect inject) | Same | 1 shared sidecar |

## Prerequisites

```
crc     >= 2.x    (running: crc start)
oc      CLI       (eval $(crc oc-env))
helm    >= 3.x
consul  CLI       (optional — openssl fallback for gossip key)
```

### CRC setup (one-time)

```bash
# Download from https://console.redhat.com/openshift/create/local
crc setup                    # one-time prerequisite install
crc start                    # start the VM (~10 GB RAM, ~4 CPUs)
eval $(crc oc-env)           # add oc to PATH
oc login -u kubeadmin -p $(crc console --credentials | grep kubeadmin | awk '{print $NF}' | tr -d "'") \
  $(crc console --url | sed 's|console-openshift-console|api|;s|$|:6443|') \
  --insecure-skip-tls-verify
```

## Quick start

```bash
task openshift:up            # bootstrap (~5-10 min)
task validate                # health check + print Route URLs
task demo                    # interactive fault-injection demo
```

The `openshift-setup.sh` script:
1. Verifies CRC is running and logs in with kubeadmin
2. Creates namespaces and grants anyuid SCC
3. Generates gossip encryption key
4. Installs Consul via Helm with both `kubernetes/consul/values.yaml` and `openshift/consul/values.yaml`
5. Applies Gateway API resources and config entries (shared with K8s)
6. Deploys observability stack (shared K8s manifests)
7. Deploys fake-service topology + load generator (shared K8s manifests)
8. Creates OpenShift Routes for all UIs and the API Gateway

## Access the services

No port-forwarding needed — all services are exposed via Routes with TLS edge termination:

```bash
# List all Routes
oc get routes --all-namespaces
```

| Service | How to find the URL |
|---------|---------------------|
| Grafana | `oc get route grafana -n observability -o jsonpath='{.spec.host}'` |
| Jaeger | `oc get route jaeger -n observability -o jsonpath='{.spec.host}'` |
| Prometheus | `oc get route prometheus -n observability -o jsonpath='{.spec.host}'` |
| Consul UI | `oc get route consul-ui -n consul -o jsonpath='{.spec.host}'` |
| Web (app) | `oc get route web -n default -o jsonpath='{.spec.host}'` |
| API Gateway | `oc get route api-gateway -n consul -o jsonpath='{.spec.host}'` |

All URLs are HTTPS (self-signed CRC certificate — use `curl -k` or accept in browser).

## Configuration files

### OpenShift-specific (this directory)

| File | Purpose |
|------|---------|
| `consul/values.yaml` | Helm overlay: `global.openshift.enabled`, SCC-compatible securityContext, ClusterIP API Gateway |
| `consul/route.yaml` | Route for Consul UI |
| `services/grafana.yaml` | Route for Grafana |
| `services/jaeger.yaml` | Route for Jaeger |
| `services/prometheus.yaml` | Route for Prometheus |
| `services/web.yaml` | Route for web (app entry point) |
| `services/api-gateway.yaml` | Route for API Gateway |

### Shared with Kubernetes

All observability, service, and Consul config-entry manifests are reused from `kubernetes/`:

| Directory | What it provides |
|-----------|------------------|
| `kubernetes/consul/values.yaml` | Base Consul Helm values |
| `kubernetes/consul/gateway/` | Gateway API CRDs |
| `kubernetes/consul/config-entries/` | ServiceIntentions, ServiceDefaults, ProxyDefaults |
| `kubernetes/services/fake-service/` | All service Deployments + Services |
| `kubernetes/observability/` | OTel Collector, Prometheus, Grafana, Jaeger, Loki, Promtail |

## Helm install command

The setup script runs this under the hood:

```bash
helm upgrade --install consul hashicorp/consul \
  --namespace consul \
  --values kubernetes/consul/values.yaml \
  --values openshift/consul/values.yaml \
  --wait --timeout 5m
```

The second values file overrides:
- `global.openshift.enabled: true` — configures SCCs and security contexts
- `global.tls.verify: false` — OCP's internal CA isn't in Consul's trust store
- `server.securityContext` — runs as non-root (UID 100)
- `connectInject.apiGateway.managedGatewayClass.serviceType: ClusterIP` — exposed via Route instead of NodePort

## Fault injection

Same as Kubernetes — `oc` is a superset of `kubectl`:

```bash
oc set env deployment/payments ERROR_RATE=0.3 -n default
oc set env deployment/api TIMING_50_PERCENTILE=500ms TIMING_90_PERCENTILE=500ms TIMING_99_PERCENTILE=500ms -n default
```

Or use `task demo` for the interactive menu.

## Tear down

```bash
task openshift:down          # remove demo resources (CRC keeps running)
crc stop                     # stop the CRC VM
```

## Troubleshooting

### Pods stuck in CrashLoopBackOff (SCC issues)

The setup script grants `anyuid` SCC to all relevant namespaces. If pods fail with permission errors:

```bash
oc adm policy add-scc-to-group anyuid system:serviceaccounts:consul
oc adm policy add-scc-to-group anyuid system:serviceaccounts:observability
oc adm policy add-scc-to-group anyuid system:serviceaccounts:default
```

### Routes not resolving

CRC uses `.apps-crc.testing` domain. Add the CRC IP to `/etc/hosts` if DNS doesn't resolve:

```bash
crc ip    # get CRC VM IP
# Add to /etc/hosts:  <CRC_IP>  grafana-observability.apps-crc.testing  ...
```

### Consul server fails to start (storage)

CRC provides `crc-csi-hostpath` as the default storage class. The Helm overlay uses `storageClass: ""` (cluster default). If your CRC uses a different class:

```bash
oc get storageclass
# Then update openshift/consul/values.yaml:
#   server.storageClass: "<your-class>"
```
