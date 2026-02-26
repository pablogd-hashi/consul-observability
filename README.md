# Consul Observability Demo

A hands-on demo of the three pillars of observability — **metrics**, **logs**, and **traces** — inside a Consul service mesh, extended with an **API Gateway** (north-south entry point) and a **Terminating Gateway** (controlled mesh exit to an external service). Runs identically on Docker Compose (local) and Kubernetes (kind/minikube/EKS/GKE).

The demo app is [fake-service](https://github.com/nicholasjackson/fake-service), a lightweight configurable HTTP service that simulates a realistic multi-tier call chain — no custom code to build or maintain.

---

## Service topology

```
[client]
   └─► API Gateway :21001 (Docker) / :8080 (K8s)
         └─► web :9090
               └─► api :9090
                     ├─► payments :9090
                     │     └─► currency :9090
                     │           └─► Terminating Gateway → rates :9090 (external)
                     └─► cache :9090
```

All services send **Zipkin traces** to the OTel Collector → Jaeger.
Envoy writes **JSON access logs** → OTel filelog receiver (Docker) / Promtail (K8s) → Loki.
Prometheus scrapes **Envoy metrics** (`:20200/stats/prometheus`), **Consul** (`/v1/agent/metrics`), and **gateway metrics**.

---

## Docker Compose

### Stack

| Service | Image | Port(s) |
|---------|-------|---------|
| Consul | `hashicorp/consul:1.22.3` | 8500 |
| web, api, payments, currency, cache | `nicholasjackson/fake-service:v0.26.2` | 9090 (internal) |
| rates | `nicholasjackson/fake-service:v0.26.2` | 9090 (external, no connect) |
| Envoy proxy (sidecar) | `envoyproxy/envoy:v1.32.2` | 20200 (metrics), 21000 (entry) |
| API Gateway | `envoyproxy/envoy:v1.32.2` | 21001 (HTTP), 20201 (admin/metrics) |
| Terminating Gateway | `envoyproxy/envoy:v1.32.2` | 9190 (egress), 20202 (admin/metrics) |
| Prometheus | `prom/prometheus:v2.52.0` | 9090 |
| Loki | `grafana/loki:3.1.0` | 3100 |
| OTel Collector | `otel/opentelemetry-collector-contrib:0.103.0` | 4317, 4318, 9411 |
| Jaeger | `jaegertracing/all-in-one:1.58` | 16686 |
| Grafana | `grafana/grafana:10.4.3` | 3000 |

### Quick start

```bash
# Start the full stack
task docker:up

# Verify everything is running
task validate

# Interactive demo (fault injection, load tests, gateway demo)
task demo
```

Or without Task:

```bash
cd docker
docker compose up -d
docker compose ps
```

### Endpoints — Docker Compose

| Service | URL | Notes |
|---------|-----|-------|
| App (sidecar Envoy) | http://localhost:21000 | Direct Envoy proxy |
| App (API Gateway) | http://localhost:21001 | North-south entry point |
| Consul UI | http://localhost:8500 | Service health + topology |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger UI | http://localhost:16686 | Search service: `web` |
| Prometheus | http://localhost:9090 | |
| Envoy metrics | http://localhost:20200/stats/prometheus | Sidecar raw metrics |
| API Gateway metrics | http://localhost:20201/stats/prometheus | Gateway raw metrics |
| Loki | http://localhost:3100 | |

---

## Kubernetes (kind)

Same topology, same observability stack — deployed on Kubernetes with Consul Connect injecting Envoy sidecars, plus the Consul API Gateway and Terminating Gateway managed by the Consul Helm chart and Kubernetes Gateway API.

### Prerequisites

```
kind    >= 0.20
kubectl >= 1.28
helm    >= 3.13
docker  >= 24
consul  CLI (for gossip key generation, or openssl as fallback)
```

### Quick start

```bash
# Bootstrap everything (~5-10 minutes)
task k8s:up
# or directly:
bash scripts/kind-setup.sh
```

The script:
1. Creates a kind cluster with host port mappings (including port 8080 → API Gateway NodePort 30004)
2. Pre-pulls images into the kind node
3. Installs Gateway API CRDs (required for Consul API Gateway)
4. Installs Consul via Helm (ACLs, TLS, Connect inject, API Gateway, Terminating Gateway)
5. Deploys the observability stack (Prometheus, Loki, OTel, Jaeger, Grafana, Promtail)
6. Deploys the fake-service pods (web, api, payments, currency, cache, rates) + load generator
7. Applies Consul config entries (intentions, service defaults, gateway config)
8. Applies Kubernetes Gateway API resources (GatewayClass, Gateway, HTTPRoute)
9. Patches the API Gateway Service to NodePort 30004

> **Note:** If you have an existing cluster created before this branch, run `task k8s:down && task k8s:up` — the new kind port mapping and Gateway API CRDs require a fresh cluster.

### Access the services

```bash
# Start all port-forwards (in separate terminals or background)
kubectl port-forward svc/consul-ui    8500:80    -n consul        &
kubectl port-forward svc/grafana      3000:3000  -n observability &
kubectl port-forward svc/jaeger-query 16686:16686 -n observability &
kubectl port-forward svc/prometheus   9091:9090  -n observability &
# web service (optional — API Gateway is the main entry point)
kubectl port-forward svc/web          9090:9090  -n default       &
```

| Service | URL | Notes |
|---------|-----|-------|
| App (API Gateway) | http://localhost:8080 | NodePort 30004, no port-forward needed |
| App (web direct) | http://localhost:9090 | Port-forward required |
| Consul UI | http://localhost:8500 | Port-forward required |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger | http://localhost:16686 | Port-forward required |
| Prometheus | http://localhost:9091 | Port-forward required |

### Tear down

```bash
task k8s:down
# or:
kind delete cluster --name consul-observability
```

---

## Gateways

### API Gateway

The API Gateway is the **north-south entry point** — external clients send traffic here, and the gateway routes it into the mesh.

- **Docker**: static Envoy JSON config (consistent with the sidecar pattern used in this demo). Listener on `:21001`. Includes a local rate limiter (100 req/s fill rate, burst 200 — requests above this return HTTP 429).
- **K8s**: managed by the Consul Helm chart via the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/). `GatewayClass + Gateway + HTTPRoute` CRDs route traffic to the `web` service. Exposed as NodePort 30004 → `localhost:8080`.

**How it differs from a sidecar:**

| | Sidecar (east-west) | API Gateway (north-south) |
|---|---|---|
| Traffic | Service → Service inside the mesh | External client → mesh |
| Scope | One Envoy per pod, 1:1 with the app | Shared Envoy, single entry point |
| Features | mTLS, intentions, circuit breaking | Auth, rate limiting, routing rules at the edge |

### Terminating Gateway

The Terminating Gateway is the **controlled mesh exit point** — mesh services reach external or legacy services through it.

- **Docker**: static Envoy JSON on port `9190`. Routes `currency` → `rates` (external).
- **K8s**: enabled via `terminatingGateways` in the Consul Helm chart. A `TerminatingGateway` CRD declares which external services are reachable. `currency` uses transparent proxy; the Consul CNI intercepts the call to `rates` and routes it through the TGW.

Traffic flow: `payments → currency → TGW → rates (external)`. mTLS terminates at the TGW; the last mile to `rates` is plain HTTP.

### rates service

`rates` is an external service — it runs as a plain fake-service container **without** Consul Connect inject. It simulates a third-party pricing API that the mesh cannot directly reach (must go through the Terminating Gateway).

Fault injection works on `rates` the same way as any other service. Set `RATES_ERROR_RATE` in `docker/.env` (Docker) or `kubectl set env deployment/rates ERROR_RATE=0.3` (K8s) to inject errors on the external call.

---

## Demo walkthrough

Run the interactive demo script:

```bash
task demo
```

Options:

| # | Action | What it shows |
|---|--------|---------------|
| 1 | Inject errors | Service returns N% HTTP 500 → error rate in Grafana, red spans in Jaeger |
| 2 | Inject latency | Service adds sleep → P99 spike in Grafana, wider spans in Jaeger |
| 3 | Load test | 30s burst of traffic → RPS spike in Service Health dashboard |
| 4 | Reset all faults | Restore baseline (0 errors, 1ms latency) |
| 5 | Circuit breaking | 100% errors → Envoy ejects backend → 503s with near-zero latency |
| 6 | Gateway load test | 30s of traffic through API Gateway + TGW → rates path |
| 7 | Show URLs | Print all dashboard URLs |
| 8 | Open all UIs | Open Grafana, Jaeger, Consul in browser |

### Fault injection

Each fake-service reads environment variables at startup:

| Variable | Effect | Example |
|----------|--------|---------|
| `ERROR_RATE` | Fraction of requests that return HTTP 500 | `0.3` = 30% errors |
| `TIMING_50_PERCENTILE` | P50 added sleep (K8s: `TIMING_50_PERCENTILE`) | `500ms` |
| `TIMING_90_PERCENTILE` | P90 added sleep | `500ms` |
| `TIMING_99_PERCENTILE` | P99 added sleep | `500ms` |

Docker: variables come from `docker/.env` (copy `docker/.env.example` for defaults). Each service has a prefixed variable: `PAYMENTS_ERROR_RATE=0.3`, `CACHE_LATENCY_P50=200ms`, etc.

K8s: `kubectl set env deployment/<service> ERROR_RATE=0.3 -n default` triggers a rolling restart.

---

## Dashboards

All dashboards auto-provision under **Consul Observability** in Grafana.

| Dashboard | Datasource(s) | What it shows |
|-----------|---------------|---------------|
| **Service-to-Service Traffic** | Prometheus + Jaeger | Entry-point RPS, error rate, latency percentiles, distributed trace waterfall, service dependency node graph |
| **Consul Service Health** | Prometheus | Cluster membership, registered services, health checks, raft stability |
| **Envoy Access Logs** | Loki | Live access log stream, request rate by status code, error counts |
| **Consul Gateways** | Prometheus | API Gateway RPS / error rate / P99 / rate limited requests; Terminating Gateway external RPS / error rate / active connections |

### Service Dependency Map (node graph)

The **Service-to-Service Traffic** dashboard includes a node graph panel that shows the live service topology derived from traces. The OTel Collector's `servicegraph` connector counts span pairs and emits `traces_service_graph_request_total{client, server}` → scraped by Prometheus → powers the graph in Grafana.

After running any load (background loadgen generates 1 req/2s), edges appear between services: `web → api → payments → currency → rates` and `api → cache`. The `rates` node appears as an extra hop via the Terminating Gateway.

---

## Architecture

### Docker Compose

```
[client]
   │
   ▼
API Gateway :21001 ──────────────────────────────────────────────────┐
   │  (rate limiter, routes to web:9090)                              │
Envoy :21000 ─────────────────────────► Prometheus :9090            │
   │  access.log (JSON) → otel-collector  (scrapes Consul + Envoy +  │
   │  Zipkin traces → otel-collector :9411   gateways)               │
   ▼                        │                                        │
web :9090 ──────────────────┼── traces + logs ──► Jaeger :16686     │
   └─► api :9090            │                   ► Loki :3100        │
         ├─► payments :9090 │                      │                 │
         │     └─► currency ─► TGW :9190 ─► rates │                 │
         └─► cache :9090    ▼                      ▼                 │
Consul :8500          otel-collector          Grafana :3000 ◄────────┘
```

### Kubernetes

```
 ┌──────────────────────── consul namespace ──────────────────────────┐
 │  API Gateway (Envoy pod, NodePort 30004)                           │
 │  Terminating Gateway (Envoy pod)                                   │
 └───────────────────────────┬────────────────────────────────────────┘
                              │ Gateway API (GatewayClass, Gateway, HTTPRoute)
                              ▼
 ┌──────────────────────── default namespace ─────────────────────────┐
 │  web ──► api ──► payments ──► currency ──► [TGW] ──► rates        │
 │               └─► cache                                            │
 │  (each pod has consul-dataplane sidecar injected by Consul Connect;│
 │   Envoy metrics on :20200, Zipkin traces → otel-collector :9411)   │
 └─────────────────────────────┬──────────────────────────────────────┘
                                │ Zipkin spans → :9411
                                │ Metrics :20200/stats/prometheus
                                ▼
 ┌──────────────────── observability namespace ────────────────────────┐
 │  OTel Collector:                                                     │
 │    receivers:  zipkin (Envoy spans), otlp (app traces)              │
 │    connectors: servicegraph → traces_service_graph_request_total    │
 │    exporters:  jaeger (traces), loki (logs), prometheus :8889       │
 │  Promtail DaemonSet → Loki (pod stdout, with service_name labels)   │
 │  Prometheus (scrapes Consul + Envoy sidecars + gateways)            │
 │  Jaeger, Grafana                                                     │
 └──────────────────────────────────────────────────────────────────────┘
```

---

## Configuration reference

### Docker Compose

| File | Purpose |
|------|---------|
| `docker/docker-compose.yml` | All services, network, volumes |
| `docker/consul/consul.hcl` | Consul config + service registrations (incl. api-gateway, terminating-gateway, rates) |
| `docker/envoy/envoy-access-log.json` | Sidecar Envoy (web proxy, port 21000, JSON access logs, Zipkin tracing) |
| `docker/envoy/envoy-api-gateway.json` | API Gateway Envoy (port 21001, rate limiter 100 req/s, routes to web) |
| `docker/envoy/envoy-terminating-gateway.json` | Terminating Gateway Envoy (port 9190, routes to rates:9090) |
| `docker/prometheus/prometheus.yml` | Scrape configs (consul, envoy sidecar, api-gateway, terminating-gateway, otel-collector) |
| `docker/otel/otel-collector.yml` | Zipkin + filelog receivers → Jaeger + Loki exporters; servicegraph connector |
| `docker/loki/loki-config.yml` | Loki single-binary, filesystem storage, 7-day retention |
| `docker/grafana/provisioning/` | Datasource + dashboard auto-provisioning |
| `docker/grafana/dashboards/` | Four dashboard JSON files (service-health, service-to-service, logs, gateways) |
| `docker/.env.example` | Default fault-injection variables for all services including `rates` |

### Kubernetes

| File | Purpose |
|------|---------|
| `kubernetes/consul/values.yaml` | Consul Helm values (Connect inject, ACLs, TLS, metrics, API Gateway, Terminating Gateway) |
| `kubernetes/consul/gateway/` | GatewayClass, Gateway, HTTPRoute, TerminatingGateway CRD resources |
| `kubernetes/consul/config-entries/` | ServiceIntentions (allow traffic between services), ServiceDefaults (protocol: http) |
| `kubernetes/services/fake-service/` | Deployments + Services for web, api, payments, currency, cache, rates |
| `kubernetes/observability/otel-collector.yaml` | OTel Collector with servicegraph connector (no metric namespace prefix) |
| `kubernetes/observability/prometheus.yaml` | Prometheus with consul-gateways scrape job |
| `kubernetes/observability/promtail.yaml` | Promtail with pipeline stage to add `service_name`/`log_source` labels to consul-dataplane logs |
| `kubernetes/observability/grafana.yaml` | Grafana with all four dashboards embedded |
| `kubernetes/observability/jaeger.yaml` | Jaeger all-in-one |
| `kubernetes/observability/loki.yaml` | Loki single-binary |
| `scripts/kind-setup.sh` | Full bootstrap script (kind cluster, Gateway API CRDs, Consul Helm, observability, services) |

---

## Taskfile

```bash
task            # List all tasks

task docker:up   # Start Docker Compose stack
task docker:down # Stop Docker Compose
task validate    # Health check (auto-detects Docker vs K8s)
task demo        # Interactive demo (fault injection, load tests, gateways)

task k8s:up      # Bootstrap kind cluster (~5-10 min)
task k8s:down    # Delete kind cluster + stop port-forwards
```

---

## Troubleshooting

### Grafana shows "No data" for the node graph (K8s)

The Service Dependency Map uses `traces_service_graph_request_total` derived from traces by the OTel servicegraph connector. Wait ~60 seconds after cluster startup for traces to flow and the connector to emit metrics. Verify with:

```bash
kubectl port-forward svc/otel-collector 8889:8889 -n observability &
curl -s http://localhost:8889/metrics | grep traces_service_graph
```

### Grafana shows "No data" for Envoy Access Logs panels (K8s)

Logs are collected by Promtail and labeled with `service_name=envoy-sidecar, log_source=access-log` (set by the `match` pipeline stage for `consul-dataplane` containers). Verify labels reached Loki:

```bash
kubectl port-forward svc/loki 3100:3100 -n observability &
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq .
curl -s 'http://localhost:3100/loki/api/v1/label/service_name/values' | jq .
```

### Jaeger shows no traces

Envoy sidecars send Zipkin B3 spans to `otel-collector:9411`. Check the OTel collector is running and the zipkin receiver is listening:

```bash
kubectl logs -n observability deploy/otel-collector | grep -i zipkin
```

### API Gateway not accessible (K8s)

The API Gateway is exposed on NodePort 30004 → `localhost:8080` (no port-forward needed for kind). If the cluster was created before this branch, recreate it with `task k8s:down && task k8s:up` to get the new kind port mapping.

```bash
kubectl get svc api-gateway -n consul
curl -s http://localhost:8080/
```
