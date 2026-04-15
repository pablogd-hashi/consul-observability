# Kubernetes (kind)

Deploys the full Consul observability demo on a local kind cluster. Consul Connect injects per-pod Envoy sidecars, and the Consul Helm chart manages the API Gateway and Terminating Gateway via Kubernetes Gateway API CRDs.

## Key differences from other flavours

| Aspect | K8s | Docker/Podman | OpenShift |
|--------|-----|---------------|-----------|
| Envoy sidecars | 1 per pod (injected by Consul Connect) | 1 shared sidecar | Same as K8s |
| API Gateway | Kubernetes Gateway API CRDs | Static Envoy JSON | Same CRDs + Route |
| Terminating Gateway | Consul Helm `terminatingGateways` | Static Envoy JSON | Same + SCC |
| Exposure | NodePort (30004 → localhost:18080) | Localhost ports | OpenShift Routes |
| Logs | Promtail DaemonSet → Loki | OTel filelog receiver | Same as K8s |
| Security | Default PSPs | N/A | SCCs (anyuid) |
| TLS | Consul auto-TLS (verify: true) | N/A | Consul auto-TLS (verify: false for OCP CA) |
| Transparent proxy | iptables via Consul CNI | N/A | Same |

## Prerequisites

```
kind    >= 0.20
kubectl >= 1.28
helm    >= 3.13
docker  >= 24
consul  CLI (optional — openssl fallback for gossip key)
```

## Quick start

```bash
task k8s:up          # bootstrap (~5-10 min)
task validate        # health check + print URLs
task demo            # interactive fault-injection demo
```

The `kind-setup.sh` script:
1. Creates a kind cluster with host port mappings
2. Pre-pulls images into the kind node
3. Installs Consul via Helm (ACLs, TLS, Connect, gateways)
4. Deploys observability stack (Prometheus, Loki, OTel, Jaeger, Grafana, Promtail)
5. Deploys fake-service topology + load generator
6. Applies Consul config entries + Gateway API resources

## Access the services

```bash
kubectl port-forward svc/consul-ui    8500:80    -n consul        &
kubectl port-forward svc/grafana      3000:3000  -n observability &
kubectl port-forward svc/jaeger-query 16686:16686 -n observability &
kubectl port-forward svc/prometheus   9091:9090  -n observability &
```

| Service | URL | Notes |
|---------|-----|-------|
| App (API Gateway) | http://localhost:18080 | NodePort, no port-forward |
| Consul UI | http://localhost:8500 | Port-forward required, metrics integration enabled |
| Grafana | http://localhost:3000 | admin/admin, port-forward required |
| Jaeger | http://localhost:16686 | Port-forward required |
| Prometheus | http://localhost:9091 | Port-forward required |

**Port-forward commands:**
```bash
kubectl port-forward svc/consul-ui 8500:80 -n consul &
kubectl port-forward svc/grafana 3000:3000 -n observability &
kubectl port-forward svc/jaeger-query 16686:16686 -n observability &
kubectl port-forward svc/prometheus 9091:9090 -n observability &
```

**Consul UI Metrics Integration:** The Consul UI is configured with Prometheus metrics integration. Click any service → "Metrics" tab to view real-time metrics, or click "Dashboard" to jump directly to the Grafana service-to-service dashboard for that service.

## Configuration files

| File | Purpose |
|------|---------|
| `consul/values.yaml` | Consul Helm chart values |
| `consul/gateway/` | Gateway, HTTPRoute, TerminatingGateway CRDs |
| `consul/config-entries/` | ServiceIntentions, ServiceDefaults, ProxyDefaults |
| `services/fake-service/` | Deployments + Services for all topology services |
| `observability/otel-collector.yaml` | OTel Collector with servicegraph connector |
| `observability/prometheus.yaml` | Prometheus with consul + envoy scrape jobs |
| `observability/grafana.yaml` | Grafana with embedded dashboards |
| `observability/promtail.yaml` | Promtail DaemonSet for pod logs → Loki |

## Fault injection

```bash
kubectl set env deployment/payments ERROR_RATE=0.3 -n default
kubectl set env deployment/api TIMING_50_PERCENTILE=500ms TIMING_90_PERCENTILE=500ms TIMING_99_PERCENTILE=500ms -n default
```

Or use `task demo` for the interactive menu.

## Tear down

```bash
task k8s:down        # delete kind cluster
```
