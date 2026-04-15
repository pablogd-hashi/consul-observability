# Docker Compose

Single-host deployment using Docker Compose. One shared Envoy sidecar proxies all fake-service traffic, plus dedicated Envoy instances for the API Gateway and Terminating Gateway.

## Key differences from other flavours

| Aspect | Docker | Podman | K8s / OpenShift |
|--------|--------|--------|-----------------|
| Envoy sidecars | 1 shared sidecar for all services | Same | 1 per pod (injected by Consul Connect) |
| Service discovery | Static `consul.hcl` registrations | Same | Consul Connect auto-registers pods |
| API Gateway | Static Envoy JSON `:21001` | Same | Kubernetes Gateway API CRDs |
| Terminating Gateway | Static Envoy JSON `:9190` | Same | Consul Helm `terminatingGateways` |
| Logs | OTel filelog receiver (access.log) | Same | Promtail DaemonSet (pod stdout) |
| Networking | Docker bridge, all ports on localhost | Same | ClusterIP + NodePort/Route |

## Quick start

```bash
task docker:up       # start the full stack
task validate        # verify everything is healthy
task demo            # interactive fault-injection demo
```

## Endpoints

| Service | URL |
|---------|-----|
| App (sidecar Envoy) | http://localhost:21000 |
| App (API Gateway) | http://localhost:21001 |
| Consul UI | http://localhost:8500 |
| Grafana | http://localhost:3000 (admin/admin) |
| Jaeger | http://localhost:16686 |
| Prometheus | http://localhost:9090 |

**Consul UI Metrics Integration:** The Consul UI is configured with Prometheus metrics integration. Click any service → "Metrics" tab to view real-time metrics, or click "Dashboard" to jump directly to the Grafana service-to-service dashboard for that service.

## Configuration files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | All services, network, volumes |
| `consul/consul.hcl` | Consul config + service registrations |
| `envoy/envoy-access-log.json` | Sidecar Envoy config |
| `envoy/envoy-api-gateway.json` | API Gateway Envoy (rate limiter 100 req/s) |
| `envoy/envoy-terminating-gateway.json` | Terminating Gateway Envoy |
| `otel/otel-collector.yml` | OTel Collector (Zipkin + filelog + servicegraph) |
| `prometheus/prometheus.yml` | Scrape configs |
| `grafana/dashboards/` | Four dashboard JSON files |
| `.env.example` | Fault injection defaults (copy to `.env`) |

## Fault injection

Variables are in `.env` (copy from `.env.example`). Each service has prefixed vars:

```bash
PAYMENTS_ERROR_RATE=0.3    # 30% HTTP 500
PAYMENTS_LATENCY_P50=500ms # 500ms added sleep
```

The `task demo` command manages these automatically.

## Tear down

```bash
task docker:down     # stop (keep volumes)
```
