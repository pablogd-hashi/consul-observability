# Consul Observability Demo

A hands-on demo of the three pillars of observability — **metrics**, **logs**, and **traces** — inside a Consul service mesh, extended with an **API Gateway** (north-south entry point) and a **Terminating Gateway** (controlled mesh exit to an external service). Runs identically on Docker Compose, Podman Compose (rootless; RHEL/Fedora/macOS), Kubernetes (kind/minikube/EKS/GKE), and OpenShift Local (CRC).

Each deployment flavour has its own README with key differences and detailed setup:
- [`docker/README.md`](docker/README.md) — Docker Compose
- [`kubernetes/README.md`](kubernetes/README.md) — Kubernetes (kind)
- [`openshift/README.md`](openshift/README.md) — OpenShift Local (CRC)

The demo app is [fake-service](https://github.com/nicholasjackson/fake-service), a lightweight configurable HTTP service that simulates a realistic multi-tier call chain — no custom code to build or maintain.

---

## Prerequisites

| Tool | Min version | Required for | Install |
|------|-------------|--------------|---------|
| Docker | 24 | Docker, K8s | https://docs.docker.com/get-docker/ |
| kind | 0.20 | K8s | https://kind.sigs.k8s.io/docs/user/quick-start/ |
| kubectl | 1.28 | K8s | https://kubernetes.io/docs/tasks/tools/ |
| Helm | 3.13 | K8s, OpenShift | https://helm.sh/docs/intro/install/ |
| Task | 3.x | All | https://taskfile.dev/installation/ |
| consul CLI | any | Optional | Gossip key generation; `openssl` fallback |
| crc | 2.x | OpenShift | https://console.redhat.com/openshift/create/local |
| oc | 4.x | OpenShift | Ships with CRC: `eval $(crc oc-env)` |

> **Docker Compose** is bundled with Docker Desktop. The Kubernetes path uses [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker) — no cloud account needed. The OpenShift path uses [CRC](https://developers.redhat.com/products/openshift-local/overview) (single-node OpenShift).

---

## Service topology

```
[client]
   └─► API Gateway :21001 (Docker/Podman) / :18080 (K8s) / Route (OpenShift)
         └─► web :9090
               └─► api :9090
                     ├─► payments :9090
                     │     └─► currency :9090
                     │           └─► Terminating Gateway → rates :9090 (external)
                     └─► cache :9090
```

All services send **Zipkin traces** to the OTel Collector → Jaeger.
Envoy writes **JSON access logs** → OTel filelog receiver (Docker/Podman) / Promtail (K8s) → Loki.
Prometheus scrapes **Envoy metrics** (`:20200/stats/prometheus`), **Consul** (`/v1/agent/metrics`), and **gateway metrics**.

---

## Docker Compose

### Stack

| Service | Image | Port(s) |
|---------|-------|---------|
| Consul | `hashicorp/consul:1.22.3` | 8500 |
| web, api, payments, currency, cache | `nicholasjackson/fake-service:v0.26.2` | 9090 (internal) |
| rates | `nicholasjackson/fake-service:v0.26.2` | 9090 (external, no connect) |
| Envoy sidecar | `envoyproxy/envoy:v1.32.2` | 20200 (metrics), 21000 (entry) |
| API Gateway | `envoyproxy/envoy:v1.32.2` | 21001 (HTTP), 20201 (admin/metrics) |
| Terminating Gateway | `envoyproxy/envoy:v1.32.2` | 9190 (egress), 20202 (admin/metrics) |
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

# Interactive demo (fault injection, load tests, gateway demo)
task demo
```

Without Task:

```bash
docker compose -f docker/docker-compose.yml up -d
docker compose -f docker/docker-compose.yml ps
```

### Endpoints — Docker Compose

| Service | URL | Notes |
|---------|-----|-------|
| App (sidecar Envoy) | http://localhost:21000 | Direct sidecar proxy |
| App (API Gateway) | http://localhost:21001 | North-south entry point |
| Consul UI | http://localhost:8500 | Service health + topology |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger UI | http://localhost:16686 | Search service: `web` |
| Prometheus | http://localhost:9090 | |
| Envoy sidecar metrics | http://localhost:20200/stats/prometheus | Raw sidecar metrics |
| API Gateway metrics | http://localhost:20201/stats/prometheus | Gateway raw metrics |
| Loki | http://localhost:3100 | |

---

## Podman Compose

Same stack, same config files — `podman/podman-compose.yml` points back to `docker/` for all configs. Bind mounts include `:z` for SELinux relabeling (no-op on macOS).

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

# Interactive demo
task demo
```

Without Task:

```bash
cd podman
cp .env.example .env
podman compose -f podman-compose.yml up -d
podman compose -f podman-compose.yml ps
```

### Endpoints — Podman Compose

Identical to Docker Compose — same ports, same URLs:

| Service | URL | Notes |
|---------|-----|-------|
| App (sidecar Envoy) | http://localhost:21000 | Direct sidecar proxy |
| App (API Gateway) | http://localhost:21001 | North-south entry point |
| Consul UI | http://localhost:8500 | |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger UI | http://localhost:16686 | |
| Prometheus | http://localhost:9090 | |
| API Gateway metrics | http://localhost:20201/stats/prometheus | |
| Loki | http://localhost:3100 | |

### Podman notes

- **Rootless**: containers run without root privileges. `user: root` inside Envoy containers maps to your host user UID — named volumes are always writable.
- **SELinux**: the `:z` flag on bind mounts relabels the host path so the container can read it. Silently ignored on macOS and systems without SELinux enforcing.
- **macOS**: `podman machine` runs a lightweight Linux VM. `podman machine stop` when you're done to free resources.
- **`podman-compose` required**: without it, `podman compose` falls back to Docker's CLI plugin and the stack runs under Docker, not Podman.

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
1. Creates a kind cluster with host port mappings (including port 18080 → API Gateway NodePort 30004)
2. Pre-pulls images into the kind node
3. Installs Gateway API CRDs (required for Consul API Gateway)
4. Installs Consul via Helm (ACLs, TLS, Connect inject, API Gateway, Terminating Gateway)
5. Deploys the observability stack (Prometheus, Loki, OTel, Jaeger, Grafana, Promtail)
6. Deploys the fake-service pods (web, api, payments, currency, cache, rates) + load generator
7. Applies Consul config entries (intentions, service defaults, gateway config)
8. Applies Kubernetes Gateway API resources (GatewayClass, Gateway, HTTPRoute)
9. Patches the API Gateway Service to NodePort 30004

> **Note:** If you have an existing cluster created before the gateways branch, run `task k8s:down && task k8s:up` — the new kind port mapping and Gateway API CRDs require a fresh cluster.

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
| App (API Gateway) | http://localhost:18080 | NodePort 30004, no port-forward needed |
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

## OpenShift Local (CRC)

Same topology, same observability stack — deployed on OpenShift Local (CRC). Reuses all Kubernetes manifests and adds OpenShift Routes, SCCs, and `global.openshift.enabled` in Consul Helm. See [`openshift/README.md`](openshift/README.md) for full details.

### Prerequisites

```
crc     >= 2.x   (running: crc start)
oc      CLI      (eval $(crc oc-env))
helm    >= 3.x
```

### Quick start

```bash
task openshift:up    # bootstrap (~5-10 min)
task validate        # health check + print Route URLs
task demo            # interactive demo (auto-detects OpenShift)
```

### Access the services

No port-forwarding — all services are exposed via OpenShift Routes (HTTPS):

```bash
oc get routes --all-namespaces
```

### Tear down

```bash
task openshift:down  # remove demo resources (CRC keeps running)
crc stop             # stop the CRC VM
```

---

## Gateways

### Architecture overview (Kubernetes)

Since **Consul 1.14**, client agents are no longer deployed on every node. Instead, `consul-dataplane` is injected as a sidecar container directly into each application pod. It embeds Envoy and registers the pod into the Consul catalog, talking directly to the Consul server over gRPC (xDS). There is no client DaemonSet.

| Component | Role | Where it runs |
|-----------|------|---------------|
| Consul server | Raft consensus, catalog, ACLs, config entries | `consul` namespace StatefulSet |
| `consul-dataplane` sidecar | Envoy proxy + pod registration | injected into every app pod (`default` ns) |
| API Gateway | North-south Envoy pod | `consul` namespace Deployment |
| Terminating Gateway | Mesh-exit Envoy pod | `consul` namespace Deployment |

Gateway API CRDs (including `TCPRoute` from the experimental channel) are installed and managed by the Consul Helm chart via `connectInject.apiGateway.manageExternalCRDs: true` — no manual CRD installation needed.

Transparent proxy (`connectInject.transparentProxy.defaultEnabled: true`) intercepts all pod egress via iptables rules injected by the Consul CNI plugin, so services can reach upstreams using plain DNS names (e.g. `http://rates:9090`) without explicit upstream annotations.

### Architecture diagram

```
                  ┌─────────────────────────────────────────────────────────────┐
 [external        │                   Consul Service Mesh                       │
  client]         │                                                              │
     │            │   ┌─────────────────────────────────────────────────────┐   │
     ▼            │   │  default namespace                                  │   │
 ┌──────────┐     │   │                                                     │   │
 │   API    │─────┼──►│  web ──► api ──►  payments ──► currency ───────────┼───┼──┐
 │ Gateway  │     │   │               └──► cache                           │   │  │
 │  :21001  │     │   └─────────────────────────────────────────────────────┘   │  │
 │  :18080  │     │                                                              │  │
 │          │     │   ┌──────────────────────────────────────────────────────┐   │  │
 │ N-S entry│     │   │  Terminating Gateway                                 │◄──┼──┘
 │ rate-lim.│     │   │   mTLS terminates here                               │   │
 └──────────┘     │   │   plain HTTP on last mile to rates                   │   │
                  │   └─────────────────────────────────┬────────────────────┘   │
                  └─────────────────────────────────────┼──────────────────────┘
                                                        │
                                                        ▼
                                               ┌─────────────────┐
                                               │  rates  :9090   │
                                               │  (external,     │
                                               │  no sidecar,    │
                                               │  no mTLS)       │
                                               └─────────────────┘

  Key:
    API Gateway   — north-south Envoy; single entry for all external traffic
    Sidecar       — east-west Envoy injected per pod; enforces mTLS + intentions
    Term. Gateway — controlled egress; the only exit path to external services

  Ports:
    Docker/Podman  →  API GW :21001  |  TGW :9190  |  sidecar :20200 (metrics)
    K8s            →  API GW :18080  |  TGW cluster-internal  |  sidecars :20200
    OpenShift      →  API GW Route   |  TGW cluster-internal  |  sidecars :20200
```

### API Gateway

The API Gateway is the **north-south entry point** — external clients send traffic here, and the gateway routes it into the mesh.

- **Docker/Podman**: static Envoy JSON config. Listener on `:21001`. Includes a local rate limiter (100 req/s fill rate, burst 200 — requests above this return HTTP 429).
- **K8s**: managed by the Consul Helm chart via the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/). `GatewayClass + Gateway + HTTPRoute` CRDs route traffic to the `web` service. Exposed as NodePort 30004 → `localhost:18080`.

**How it differs from a sidecar:**

| | Sidecar (east-west) | API Gateway (north-south) |
|---|---|---|
| Traffic | Service → Service inside the mesh | External client → mesh |
| Scope | One Envoy per pod, 1:1 with the app | Shared Envoy, single entry point |
| Features | mTLS, intentions, circuit breaking | Auth, rate limiting, routing rules at the edge |

### Terminating Gateway

The Terminating Gateway is the **controlled mesh exit point** — mesh services reach external or legacy services through it.

- **Docker/Podman**: static Envoy JSON on port `9190`. Routes `currency` → `rates` (external).
- **K8s**: enabled via `terminatingGateways` in the Consul Helm chart. A `TerminatingGateway` CRD declares which external services are reachable. `currency` uses transparent proxy; the Consul CNI intercepts the call to `rates` and routes it through the TGW.

Traffic flow: `payments → currency → TGW → rates (external)`. mTLS terminates at the TGW; the last mile to `rates` is plain HTTP.

### rates service

`rates` is an external service — it runs as a plain fake-service container **without** Consul Connect inject. It simulates a third-party pricing API that the mesh cannot directly reach (must go through the Terminating Gateway).

Fault injection works on `rates` the same way as any other service. Set `RATES_ERROR_RATE` in `docker/.env` (Docker/Podman) or `kubectl set env deployment/rates ERROR_RATE=0.3` (K8s) to inject errors on the external call.

---

## Circuit Breakers

Circuit breaking in the Consul service mesh is implemented by **Envoy outlier detection**. Each sidecar monitors the health of its upstream backends and automatically ejects misbehaving ones from the load balancing pool for a configurable period.

### How it works

```
payments (sidecar Envoy)
   │
   ├──► currency-pod-A  ✓  (healthy)
   ├──► currency-pod-B  ✗  (returning 5xx)  ← ejected after N consecutive failures
   └──► currency-pod-C  ✓  (healthy)
```

When a backend returns **N consecutive 5xx responses** (default: 5), Envoy marks it as ejected — requests are no longer sent to it. After a base ejection interval (default: 30 s) the backend is given a chance to recover. If it's still unhealthy, the ejection duration doubles (exponential backoff).

**Why this matters:** Without circuit breaking, a failing backend causes every caller to wait for the full request timeout before returning an error. With circuit breaking, Envoy fast-fails at the proxy layer — callers get immediate 503s with near-zero latency instead of a cascade of slow timeouts.

### Key metrics

| Metric | Type | What it shows |
|--------|------|---------------|
| `envoy_cluster_outlier_detection_ejections_active` | Gauge | Backends currently ejected (circuit is **open**) |
| `envoy_cluster_outlier_detection_ejections_consecutive_5xx` | Gauge | Ejections caused by consecutive 5xx errors |
| `envoy_cluster_outlier_detection_success_rate_ejections` | Gauge | Ejections caused by below-average success rate |

### Grafana dashboard

The **Service Health** dashboard has a **Circuit Breaker** section with two panels:

- **Active Circuit Breakers** — timeseries showing currently ejected hosts per service pair
- **Circuit Breakers Triggered** — bar gauge showing peak consecutive 5xx ejections over the selected time range

---

## Demo walkthrough

Run the interactive demo script — it auto-detects Docker, Podman, Kubernetes, or OpenShift:

```bash
task demo
```

| # | Action | What it shows |
|---|--------|---------------|
| 1 | Inject errors | Service returns N% HTTP 500 → error rate in Grafana, red spans in Jaeger |
| 2 | Inject latency | Service adds sleep → P99 spike in Grafana, wider spans in Jaeger |
| 3 | Load test | 30s burst of traffic → RPS spike in Service Health dashboard |
| 4 | Reset all faults | Restore baseline (0 errors, 1ms latency) |
| 5 | Circuit breaking | 100% errors → Envoy ejects backend → 503s with near-zero latency |
| 6 | Gateway load test | 30s of traffic through API Gateway → TGW → rates path |
| 7 | Show URLs | Print all dashboard URLs |
| 8 | Open all UIs | Open Grafana, Jaeger, Consul in browser |

Non-interactive (useful from scripts):

```bash
# Inject 30% errors on payments
./scripts/demo.sh --inject-errors payments 0.3

# Add 500ms latency to api
./scripts/demo.sh --inject-latency api 500ms

# Reset everything
./scripts/demo.sh --reset
```

### Fault injection

Each fake-service reads environment variables at startup:

| Variable | Effect | Example |
|----------|--------|---------|
| `ERROR_RATE` | Fraction of requests that return HTTP 500 | `0.3` = 30% errors |
| `TIMING_50_PERCENTILE` | P50 added sleep | `500ms` |
| `TIMING_90_PERCENTILE` | P90 added sleep | `500ms` |
| `TIMING_99_PERCENTILE` | P99 added sleep | `500ms` |

Docker/Podman: variables come from `docker/.env` or `podman/.env` (copy from `.env.example`). Each service has a prefixed variable: `PAYMENTS_ERROR_RATE=0.3`, `CACHE_LATENCY_P50=200ms`, `RATES_ERROR_RATE=0.5`, etc.

K8s/OpenShift: `kubectl set env deployment/<service> ERROR_RATE=0.3 -n default` (or `oc set env`) triggers a rolling restart.

---

## Dashboards

All dashboards auto-provision under **Consul Observability** in Grafana.

| Dashboard | Datasource(s) | What it shows |
|-----------|---------------|---------------|
| **Service-to-Service Traffic** | Prometheus + Jaeger | Entry-point RPS, error rate, latency percentiles, distributed trace waterfall, service dependency node graph |
| **Consul Service Health** | Prometheus | Cluster membership, registered services, health checks, raft stability, circuit breaker status |
| **Envoy Access Logs** | Loki | Live access log stream, request rate by status code, error counts |
| **Consul Gateways** | Prometheus | API Gateway RPS / error rate / P99 / rate limited requests; Terminating Gateway external RPS / error rate / active connections |

### Service Dependency Map (node graph)

The **Service-to-Service Traffic** dashboard includes a node graph panel that shows the live service topology derived from traces. The OTel Collector's `servicegraph` connector counts span pairs and emits `traces_service_graph_request_total{client, server}` → scraped by Prometheus → powers the graph in Grafana.

After running any load (background loadgen generates traffic every 2s), edges appear between services: `web → api → payments → currency → rates` and `api → cache`. The `rates` node appears as an extra hop via the Terminating Gateway.

---

## Architecture

### Docker Compose / Podman Compose

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
| `docker/envoy/envoy-access-log.json` | Sidecar Envoy (port 21000, JSON access logs, Zipkin tracing) |
| `docker/envoy/envoy-api-gateway.json` | API Gateway Envoy (port 21001, rate limiter 100 req/s, routes to web) |
| `docker/envoy/envoy-terminating-gateway.json` | Terminating Gateway Envoy (port 9190, routes to rates:9090) |
| `docker/prometheus/prometheus.yml` | Scrape configs (consul, envoy sidecar, api-gateway, terminating-gateway, otel-collector) |
| `docker/otel/otel-collector.yml` | Zipkin + filelog receivers → Jaeger + Loki exporters; servicegraph connector |
| `docker/loki/loki-config.yml` | Loki single-binary, filesystem storage, 7-day retention |
| `docker/grafana/provisioning/` | Datasource + dashboard auto-provisioning |
| `docker/grafana/dashboards/` | Four dashboard JSON files (service-health, service-to-service, logs, gateways) |
| `docker/.env.example` | Default fault-injection variables for all services including `rates` |

### Podman Compose

| File | Purpose |
|------|---------|
| `podman/podman-compose.yml` | Compose file; bind mounts point to `docker/` configs with `:z` SELinux flag |
| `podman/.env.example` | Fault injection env vars (copy to `.env` to override) |

All Consul, Envoy, Prometheus, OTel, Loki, and Grafana configs are shared from `docker/`.

### Kubernetes

| File | Purpose |
|------|---------|
| `kubernetes/consul/values.yaml` | Consul Helm values (Connect inject, ACLs, TLS, metrics, API Gateway, Terminating Gateway) |
| `kubernetes/consul/gateway/` | GatewayClass, Gateway, HTTPRoute, TerminatingGateway CRD resources |
| `kubernetes/consul/config-entries/` | ServiceIntentions, ServiceDefaults (protocol: http) |
| `kubernetes/services/fake-service/` | Deployments + Services for web, api, payments, currency, cache, rates |
| `kubernetes/observability/otel-collector.yaml` | OTel Collector with servicegraph connector |
| `kubernetes/observability/prometheus.yaml` | Prometheus with consul-gateways scrape job |
| `kubernetes/observability/promtail.yaml` | Promtail with pipeline stage for consul-dataplane access logs |
| `kubernetes/observability/grafana.yaml` | Grafana with all four dashboards embedded |
| `kubernetes/observability/jaeger.yaml` | Jaeger all-in-one |
| `kubernetes/observability/loki.yaml` | Loki single-binary |
| `scripts/kind-setup.sh` | Full bootstrap script (kind cluster, Gateway API CRDs, Consul Helm, observability, services) |

### OpenShift

| File | Purpose |
|------|---------|
| `openshift/consul/values.yaml` | Helm overlay: `global.openshift.enabled`, SCC-compatible securityContext, ClusterIP gateway |
| `openshift/consul/route.yaml` | Route for Consul UI |
| `openshift/services/*.yaml` | Routes for Grafana, Jaeger, Prometheus, web, API Gateway |
| `scripts/openshift-setup.sh` | Full bootstrap script (CRC login, SCCs, Consul Helm, observability, services, Routes) |

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

### OpenShift

```bash
task openshift:up     # Bootstrap CRC with Consul + observability + services
task openshift:down   # Remove demo resources (CRC keeps running)
task openshift:status # Show pods + routes
```

### Shared

```bash
task validate        # Health check — auto-detects Docker / Podman / K8s / OpenShift
task demo            # Interactive demo — auto-detects Docker / Podman / K8s / OpenShift
```

---

## Troubleshooting

### Grafana shows "No data" for the Service Dependency Map (K8s)

Both node and edge queries use `traces_service_graph_request_total` emitted by the OTel Collector's `servicegraph` connector. Verify the metric exists:

```bash
kubectl port-forward svc/otel-collector 8889:8889 -n observability &
curl -s http://localhost:8889/metrics | grep traces_service_graph
# Expected: traces_service_graph_request_total{client="web",server="api",...}
```

If missing, check that Envoy sidecars are sending Zipkin traces:
```bash
kubectl logs -n observability deploy/otel-collector | grep -i "zipkin\|spans\|error"
```

### Grafana shows "No data" for Envoy Access Logs panels (K8s)

Verify labels reached Loki:

```bash
kubectl port-forward svc/loki 3100:3100 -n observability &
curl -s 'http://localhost:3100/loki/api/v1/labels' | jq .
curl -s 'http://localhost:3100/loki/api/v1/label/service_name/values' | jq .
```

### Jaeger shows no traces

Envoy sidecars send Zipkin B3 spans to `otel-collector:9411`:

```bash
kubectl logs -n observability deploy/otel-collector | grep -i zipkin
```

### API Gateway not accessible (K8s)

The API Gateway is exposed on NodePort 30004 → `localhost:18080` (no port-forward needed for kind). If the cluster was created before the gateways branch, recreate it with `task k8s:down && task k8s:up`.

```bash
kubectl get svc api-gateway -n consul
curl -s http://localhost:18080/
```

### All services red in Consul UI

Consul's health checks call `/health` on each fake-service. This is a lightweight liveness endpoint — it does **not** call upstreams, so a slow chain startup cannot cause cascading failures. If services are still red, check:

```bash
# See exactly what's failing
curl -s http://localhost:8500/v1/health/state/critical | jq '.[].Output'
```

The most common cause is `connect { sidecar_service {} }` left in `consul.hcl` — it registers sidecar proxy slots with TCP checks that fail when no sidecar process is listening. Remove those blocks; they are not needed in Docker/Podman.

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
RATES_ERROR_RATE=0

# Latency per service (P50/P90/P99; set all three to the same value for a flat delay)
PAYMENTS_LATENCY_P50=1ms
PAYMENTS_LATENCY_P90=1ms
PAYMENTS_LATENCY_P99=1ms
# ... (repeated for currency, cache, api, web, rates)

# Grafana admin password (default: admin)
GRAFANA_ADMIN_PASSWORD=admin
```

`task demo` manages these files automatically. Edit manually only if you need persistent fault state across `demo` sessions.
