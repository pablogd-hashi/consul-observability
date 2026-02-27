# Consul Observability Demo

A hands-on demo of the three pillars of observability — **metrics**, **logs**, and **traces** — with a Consul service mesh. Runs identically on Docker Compose, Podman Compose (rootless; RHEL/Fedora/macOS), and Kubernetes (kind/minikube/EKS/GKE).

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
# Pre-pull images (avoids timeout on first startup)
task docker:pull

# Start the full stack
task docker:up

# Verify everything is running
task validate
```

Without Task:

```bash
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml ps
```

### Endpoints

| Service | URL | Notes |
|---------|-----|-------|
| App entry point | http://localhost:21000 | Through Envoy proxy |
| App UI | http://localhost:21000/ui | Fake-service topology UI |
| Consul UI | http://localhost:8500 | Service health + topology |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger UI | http://localhost:16686 | Search service: `web` |
| Prometheus | http://localhost:9090 | |
| Envoy metrics | http://localhost:20200/stats/prometheus | Raw Prometheus metrics |
| Loki | http://localhost:3100 | |

---

## Podman Compose

Same stack, same config files — the `podman/podman-compose.yml` points back to `docker/` for all configs. Bind mounts include `:z` for SELinux relabeling (no-op on macOS).

### Prerequisites

```
podman        >= 4.0
podman-compose    brew install podman-compose  (or: pip3 install podman-compose)
```

> **Important**: install `podman-compose` explicitly. Without it, `podman compose` falls back to
> Docker's CLI plugin (`docker-compose`), which runs containers against the Docker daemon instead
> of Podman. The brew/pip package ensures the stack runs under Podman.

macOS only — start the Podman machine first:

```bash
podman machine init    # one-time setup (creates a Linux VM)
podman machine start
```

### Quick start

```bash
# Pre-pull images
task podman:pull

# Start the full stack
task podman:up

# Verify everything is running
task validate
```

Without Task:

```bash
cd podman
cp .env.example .env
podman compose -f podman-compose.yml up -d
podman compose -f podman-compose.yml ps
```

### Endpoints

Identical to Docker Compose — same ports, same URLs:

| Service | URL | Notes |
|---------|-----|-------|
| App entry point | http://localhost:21000 | Through Envoy proxy |
| App UI | http://localhost:21000/ui | Fake-service topology UI |
| Consul UI | http://localhost:8500 | |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger UI | http://localhost:16686 | |
| Prometheus | http://localhost:9090 | |
| Loki | http://localhost:3100 | |

### Podman notes

- **Rootless**: containers run without root privileges. `user: root` inside the Envoy container maps to your host user UID — the `envoy-logs` named volume is always writable.
- **SELinux**: the `:z` flag on bind mounts relabels the host path so the container can read it. Silently ignored on macOS and systems without SELinux enforcing.
- **macOS**: `podman machine` runs a lightweight Linux VM. `podman machine stop` when you're done to free resources.

---

## Demo walkthrough

> The load generator starts automatically and drives traffic through the full chain every 2 seconds. Allow ~30 seconds after startup for traces and logs to appear in Grafana.

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

- **Services** tab: all 5 services (web, api, payments, currency, cache) with health check status
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

### 5 — Fault injection demo

The interactive demo script auto-detects whether Docker, Podman, or Kubernetes is running and routes all actions correctly:

```bash
task demo
```

Menu options:

| Choice | What it does |
|--------|-------------|
| 1) Inject errors | Set `ERROR_RATE` on a service (e.g. payments fails 30% → HTTP 500) |
| 2) Inject latency | Set `TIMING_*` on a service (e.g. api adds 500ms per request) |
| 3) Load test | 30 seconds of burst traffic — spike visible in metrics |
| 4) Reset all faults | Restore baseline (0% errors, 1ms latency) |
| 5) Circuit breaking | 100% errors on web → Envoy ejects backend → fast 503s |
| 6) Show URLs | Print Grafana / Jaeger / Consul / Prometheus links |
| 7) Open all UIs | Launch dashboards in your browser |

Non-interactive (useful from scripts):

```bash
# Inject 30% errors on payments
./scripts/demo.sh --inject-errors payments 0.3

# Add 500ms latency to api
./scripts/demo.sh --inject-latency api 500ms

# Reset everything
./scripts/demo.sh --reset
```

---

## Kubernetes (kind)

Same topology, same observability stack — deployed on Kubernetes with Consul Connect automatically injecting Envoy sidecars into each pod.

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
```

The script:
1. Creates a kind cluster with host port mappings
2. Pre-pulls `fake-service:v0.26.2` into the kind node
3. Installs Consul via Helm with ACLs, TLS, Connect inject
4. Deploys the observability stack (Prometheus, Loki, OTel, Jaeger, Grafana, Promtail)
5. Deploys the 5 fake-service pods + load generator in the `default` namespace

### Access the services

```bash
kubectl port-forward svc/web          9090:9090  -n default       &
kubectl port-forward svc/consul-ui    8500:80    -n consul        &
kubectl port-forward svc/grafana      3000:3000  -n observability &
kubectl port-forward svc/jaeger-query 16686:16686 -n observability &
kubectl port-forward svc/prometheus   9091:9090  -n observability &
```

| Service | URL |
|---------|-----|
| App (web) | http://localhost:9090 |
| Consul UI | http://localhost:8500 |
| Grafana | http://localhost:3000 (admin / admin) |
| Jaeger | http://localhost:16686 |
| Prometheus | http://localhost:9091 |

### Fault injection on Kubernetes

Use `task demo` — it auto-detects Kubernetes and uses `kubectl set env` to update deployments:

```bash
task demo
```

Or manually:

```bash
# Scale payments to 0 — watch 5xx spike in Grafana
kubectl scale deployment payments --replicas=0 -n default

# Restore
kubectl scale deployment payments --replicas=1 -n default
```

### Tear down

```bash
task k8s:down
```

---

## Architecture

### Docker Compose / Podman Compose

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
| `docker/.env.example` | Fault injection env vars (copy to `.env` to override) |

### Podman Compose

| File | Purpose |
|------|---------|
| `podman/podman-compose.yml` | Compose file; bind mounts point to `docker/` configs with `:z` SELinux flag |
| `podman/.env.example` | Fault injection env vars (copy to `.env` to override) |

All Consul, Envoy, Prometheus, OTel, Loki, and Grafana configs are shared from `docker/`.

### Kubernetes

| File | Purpose |
|------|---------|
| `kubernetes/consul/values.yaml` | Consul Helm values (Connect inject, ACLs, TLS, metrics) |
| `kubernetes/services/fake-service/` | Deployments + Services for all 5 fake-service pods |
| `kubernetes/observability/` | Prometheus, Loki, OTel Collector, Jaeger, Grafana, Promtail |

---

## Task reference

All tasks run from the repo root. Run `task` (no arguments) to list all available tasks.

### Docker

```bash
task docker:up       # Start stack (detached)
task docker:down     # Stop (keep volumes)
task docker:pull     # Pre-pull all images
task docker:ps       # Show container status
task docker:logs     # Tail all logs (Ctrl-C to stop)
```

### Podman

```bash
task podman:up       # Start stack (detached); creates .env from .env.example if missing
task podman:down     # Stop (keep volumes)
task podman:clean    # Stop and remove all volumes
task podman:pull     # Pre-pull all images with podman pull
task podman:ps       # Show container status
task podman:logs     # Tail all logs (Ctrl-C to stop)
task podman:restart  # Restart all services
```

### Kubernetes

```bash
task k8s:up          # Bootstrap kind cluster (~5-10 min)
task k8s:down        # Delete kind cluster (full teardown)
```

### Shared

```bash
task validate        # Health check — auto-detects Docker / Podman / K8s, prints status + URLs
task demo            # Interactive fault-injection demo — auto-detects Docker / Podman / K8s
```

---

## Environment variables

Fault injection is controlled via an `.env` file in the relevant directory:

```bash
# docker/.env or podman/.env  (copy from .env.example)

# Error rate per service (0.0 = no errors, 1.0 = 100% errors)
PAYMENTS_ERROR_RATE=0
CURRENCY_ERROR_RATE=0
CACHE_ERROR_RATE=0
API_ERROR_RATE=0
WEB_ERROR_RATE=0

# Latency per service (P50/P90/P99; set all three to the same value for a flat delay)
PAYMENTS_LATENCY_P50=1ms
PAYMENTS_LATENCY_P90=1ms
PAYMENTS_LATENCY_P99=1ms
# ... (repeated for currency, cache, api, web)

# Grafana admin password (default: admin)
GRAFANA_ADMIN_PASSWORD=admin
```

`task demo` manages these files automatically. Edit manually only if you need persistent fault state across `demo` sessions.
