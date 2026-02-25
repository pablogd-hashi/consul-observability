# Consul Observability Demo

A hands-on demo of the three pillars of observability — **metrics**, **logs**, and **traces** — with a Consul service mesh. Runs identically on Docker Compose (local) and Kubernetes (kind/minikube/EKS/GKE).

The demo app is [fake-service](https://github.com/nicholasjackson/fake-service), a lightweight configurable HTTP service that simulates a realistic multi-tier call chain — no custom code to build or maintain.

---

## Service topology

```
client
  └─► Envoy proxy :21000 (access logs + metrics)
        └─► web :9090
              └─► api :9090
                    ├─► payments :9090
                    │     └─► currency :9090
                    └─► cache :9090
```

All services send **Zipkin traces** to the OTel Collector → Jaeger.
Envoy writes **JSON access logs** to disk → OTel filelog receiver → Loki.
Prometheus scrapes **Envoy metrics** (:20200/stats/prometheus) and **Consul** (/v1/agent/metrics).

---

## Docker Compose

### Stack

| Service | Image | Port(s) |
|---------|-------|---------|
| Consul | `hashicorp/consul:1.22.3` | 8500 |
| web, api, payments, currency, cache | `nicholasjackson/fake-service:v0.26.2` | 9090 (internal) |
| Envoy proxy | `envoyproxy/envoy:v1.32.2` | 20200 (metrics), 21000 (entry) |
| Prometheus | `prom/prometheus:v2.52.0` | 9090 |
| Loki | `grafana/loki:3.1.0` | 3100 |
| OTel Collector | `otel/opentelemetry-collector-contrib:0.103.0` | 4317, 4318, 9411 |
| Jaeger | `jaegertracing/all-in-one:1.58` | 16686 |
| Grafana | `grafana/grafana:10.4.3` | 3000 |

### Quick start

```bash
cd docker

# Pull images first (avoids timeout on first startup)
task pull

# Start the full stack
task up

# Verify everything is running
task validate
```

Or without Task:

```bash
cd docker
docker compose up -d
docker compose ps
```

---

## Demo walkthrough

> The load generator starts automatically and drives traffic through the full chain every 2 seconds. Allow ~30 seconds after `task up` for traces and logs to appear.

### 1 — Hit the service

```bash
# Full call chain: web → api → payments → currency + cache
curl -s http://localhost:21000/ | jq .
```

You'll see a JSON response with nested `upstream_calls` showing each hop in the chain.

```bash
# The fake-service UI renders the call graph visually
open http://localhost:21000/ui
```

### 2 — Consul service health

Open **http://localhost:8500**

- **Services** tab: shows all 5 services (web, api, payments, currency, cache) with health check status
- **Topology** (Consul 1.17+): visual service dependency graph

```bash
# Check via API
curl -s http://localhost:8500/v1/health/state/passing | jq '.[].ServiceName'
```

### 3 — Grafana dashboards

Open **http://localhost:3000** (admin / admin)

Navigate to **Dashboards → Consul Observability**. Three dashboards:

#### Service-to-Service Traffic
Shows Envoy proxy metrics (Prometheus) and distributed traces (Jaeger):
- RPS, error rate, P99 latency at the entry point
- Response time percentiles (P50/P95/P99)
- Distributed trace search — click any trace to see the full waterfall (web → api → payments → currency + cache)

#### Consul Service Health
Shows the health of the Consul cluster:
- Cluster membership, registered services, health check failures
- Raft stability (leader contact time)
- Consul HTTP API request rate

#### Envoy Access Logs
Shows Envoy's JSON access logs ingested via Loki:
- Request rate by status code (2xx/4xx/5xx) over time
- Live log stream with traceparent field linking to Jaeger

### 4 — Jaeger traces

Open **http://localhost:16686**

1. Select service **web** → **Find Traces**
2. Click any trace to see the full call chain waterfall: `web → api → payments → currency` and `api → cache` (parallel)
3. Click the `traceparent` field in the Envoy Access Logs dashboard to jump directly to the matching trace

### 5 — Inject errors (fault injection demo)

Temporarily reconfigure a service to return errors 30% of the time:

```bash
# Restart the payments service with 30% error injection
docker compose stop payments
docker compose run -d --name payments_err \
  -e NAME=payments \
  -e LISTEN_ADDR=0.0.0.0:9090 \
  -e UPSTREAM_URIS=http://currency:9090 \
  -e ERROR_RATE=0.3 \
  -e ERROR_TYPE=http_error \
  -e ERROR_CODE=500 \
  -e TRACING_ZIPKIN=http://otel-collector:9411 \
  -e LOG_FORMAT=json \
  --network docker_consul-mesh \
  nicholasjackson/fake-service:v0.26.2
```

Watch in Grafana:
- **Service-to-Service** → error rate climbs to ~30%
- **Envoy Access Logs** → 5xx entries appear in the log stream
- **Jaeger** → error spans appear (red) in the trace waterfall

Restore:
```bash
docker compose up -d payments
```

### 6 — Simulate latency

```bash
# Add 500ms artificial delay to the cache service
docker compose stop cache
docker compose run -d --name cache_slow \
  -e NAME=cache \
  -e LISTEN_ADDR=0.0.0.0:9090 \
  -e TIMING_50_PERCENTILE=500ms \
  -e TIMING_VARIANCE=20 \
  -e TRACING_ZIPKIN=http://otel-collector:9411 \
  -e LOG_FORMAT=json \
  --network docker_consul-mesh \
  nicholasjackson/fake-service:v0.26.2
```

Watch P99 latency rise in the **Service-to-Service** dashboard. Restore:

```bash
docker compose up -d cache
```

---

## Kubernetes (kind)

Same topology, same observability stack — just deployed on Kubernetes with Consul Connect automatically injecting Envoy sidecars into each pod.

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
./scripts/kind-setup.sh
```

The script:
1. Creates a kind cluster with host port mappings
2. Pre-pulls `fake-service:v0.26.2` into the kind node
3. Installs Consul via Helm with ACLs, TLS, Connect inject
4. Deploys the observability stack (Prometheus, Loki, OTel, Jaeger, Grafana, Promtail)
5. Deploys the 5 fake-service pods + load generator in the `default` namespace

### Access the services

```bash
# Start all port-forwards
kubectl port-forward svc/web          9090:9090  -n default       &
kubectl port-forward svc/consul-ui    8500:80    -n consul        &
kubectl port-forward svc/grafana      3000:3000  -n observability &
kubectl port-forward svc/jaeger-query 16686:16686 -n observability &
kubectl port-forward svc/prometheus   9091:9090  -n observability &

# Or use the Taskfile shortcut:
cd docker && task k8s-forward
```

| Service | URL |
|---------|-----|
| App (web) | http://localhost:9090 |
| Consul UI | http://localhost:8500 |
| Grafana | http://localhost:3000 (admin / admin) |
| Jaeger | http://localhost:16686 |
| Prometheus | http://localhost:9091 |

### Fault injection on Kubernetes

```bash
# Scale payments to 0 — watch 5xx spike in Grafana
kubectl scale deployment payments --replicas=0 -n default

# Restore
kubectl scale deployment payments --replicas=1 -n default
```

### Tear down

```bash
kind delete cluster --name consul-observability
# or:
cd docker && task k8s-down
```

---

## Endpoints — Docker Compose

| Service | URL | Notes |
|---------|-----|-------|
| App entry point | http://localhost:21000 | Through Envoy proxy |
| App UI | http://localhost:21000/ui | Fake-service topology UI |
| Consul UI | http://localhost:8500 | Service health + topology |
| Grafana | http://localhost:3000 | admin / admin (or `$GRAFANA_ADMIN_PASSWORD`) |
| Jaeger UI | http://localhost:16686 | Search service: `web` |
| Prometheus | http://localhost:9090 | |
| Envoy metrics | http://localhost:20200/stats/prometheus | Raw Prometheus metrics |
| Loki | http://localhost:3100 | |

---

## Dashboards

All dashboards auto-provision under **Consul Observability** in Grafana.

| Dashboard | Datasource(s) | What it shows |
|-----------|---------------|---------------|
| **Service-to-Service Traffic** | Prometheus + Jaeger | Entry-point RPS, error rate, latency, distributed trace waterfall |
| **Consul Service Health** | Prometheus | Membership, registered services, health checks, raft stability |
| **Envoy Access Logs** | Loki | Live access log stream, request rate by status, error counts |

---

## Architecture

### Docker Compose

```
 client
   │
   ▼
 Envoy :21000 ──────────────────────────► Prometheus :9090
   │  access.log (JSON)                      (scrapes Consul + Envoy)
   │  Zipkin traces → otel-collector :9411      │
   ▼                                            ▼
 web :9090    ─ZIPKIN─► otel-collector ──► Jaeger :16686
   │                        │
   ▼                        │ logs
 api :9090                  ▼
   ├─► payments :9090     Loki :3100
   │       └─► currency                         │
   └─► cache :9090                              ▼
                                          Grafana :3000
 Consul :8500                             (Prometheus + Loki + Jaeger)
   (service registry + health checks)
```

### Kubernetes

```
 ┌──────────────────────── default namespace ──────────────────────────┐
 │  web ──► api ──► payments ──► currency                              │
 │               └─► cache                                             │
 │  (each pod has Envoy sidecar injected by Consul Connect;            │
 │   Envoy metrics on :20200, Zipkin traces to otel-collector)         │
 └─────────────────────────────┬───────────────────────────────────────┘
                               │ xDS from consul namespace
                               │ Zipkin spans → :9411
                               │ Metrics :20200/stats/prometheus
                               ▼
 ┌──────────────────── observability namespace ────────────────────────┐
 │  OTel Collector → Jaeger  (traces)                                  │
 │                 → Loki    (logs, with k8s attribute enrichment)     │
 │  Promtail DaemonSet → Loki (pod stdout)                             │
 │  Prometheus (scrapes Consul + Envoy sidecars via pod annotations)   │
 │  Grafana (queries Prometheus + Loki + Jaeger)                       │
 └─────────────────────────────────────────────────────────────────────┘
```

---

## Configuration reference

### Docker Compose

| File | Purpose |
|------|---------|
| `docker/docker-compose.yml` | All services, network, volumes |
| `docker/consul/consul.hcl` | Consul server config + service registrations |
| `docker/envoy/envoy-access-log.json` | Envoy static bootstrap (proxy to web:9090, JSON access logs, Zipkin tracing) |
| `docker/prometheus/prometheus.yml` | Scrape configs (consul:8500, envoy:20200, otel-collector:8888) |
| `docker/otel/otel-collector.yml` | Zipkin + filelog receivers → Jaeger + Loki exporters |
| `docker/loki/loki-config.yml` | Loki single-binary, filesystem storage, 7-day retention |
| `docker/grafana/provisioning/` | Datasource + dashboard auto-provisioning |
| `docker/grafana/dashboards/` | Three dashboard JSON files |

### Kubernetes

| File | Purpose |
|------|---------|
| `kubernetes/consul/values.yaml` | Consul Helm values (Connect inject, ACLs, TLS, metrics) |
| `kubernetes/services/fake-service/` | Deployments + Services for all 5 fake-service pods |
| `kubernetes/observability/` | Prometheus, Loki, OTel Collector, Jaeger, Grafana, Promtail |

---

## Operator commands

```bash
cd docker

task up          # Start stack (detached)
task down        # Stop + remove volumes
task restart     # Restart all services
task logs        # Tail all logs
task ps          # Show container status
task validate    # Print all endpoints + quick health checks
task pull        # Pre-pull all images

task k8s-setup   # Bootstrap kind cluster
task k8s-down    # Delete kind cluster
task k8s-forward # Port-forward all UIs
task k8s-status  # Show pod status
task k8s-validate # Check service health
```

## Environment variables

```bash
# docker/.env (copy from .env.example)
GRAFANA_ADMIN_PASSWORD=admin
```
