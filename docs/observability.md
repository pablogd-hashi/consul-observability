# Observability Reference

Technical reference for metrics, logs, and distributed tracing in this Consul service mesh stack. Covers both the Docker Compose and Kubernetes deployments.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Metrics](#metrics)
   - [Enabling Metrics](#enabling-metrics)
   - [Scrape Job Summary](#scrape-job-summary)
   - [Consul Server Metrics](#consul-server-metrics)
   - [Consul Dataplane Sidecar Metrics](#consul-dataplane-sidecar-metrics)
   - [Envoy Sidecar Metrics](#envoy-sidecar-metrics)
   - [OTel Servicegraph Metrics](#otel-servicegraph-metrics)
   - [OTel Collector Self-Metrics](#otel-collector-self-metrics)
3. [Logs](#logs)
   - [Envoy Access Logs](#envoy-access-logs)
   - [Kubernetes Pod Logs via Promtail](#kubernetes-pod-logs-via-promtail)
   - [Loki Label Strategy](#loki-label-strategy)
   - [Log-to-Trace Correlation](#log-to-trace-correlation)
4. [Distributed Tracing](#distributed-tracing)
   - [Envoy Zipkin Tracing](#envoy-zipkin-tracing)
   - [Application OTLP Tracing](#application-otlp-tracing)
   - [Trace Context Propagation](#trace-context-propagation)
   - [Sampling Configuration](#sampling-configuration)
5. [OpenTelemetry Collector Pipeline](#opentelemetry-collector-pipeline)
6. [Grafana Dashboards](#grafana-dashboards)
   - [1. Service Health](#1-service-health-service-healthjson)
   - [2. Consul Service Health](#2-consul-service-health-consul-healthjson)
   - [3. Service-to-Service Traffic](#3-service-to-service-traffic-service-to-servicejson)
   - [4. Envoy Access Logs](#4-envoy-access-logs-logsjson)
   - [5. Consul Gateways](#5-consul-gateways-gatewaysjson)
   - [Dashboard Quick Reference](#dashboard-quick-reference)
7. [Troubleshooting](#troubleshooting)

---

## Architecture

```
                        CONSUL CONTROL PLANE
                       ┌─────────────────────┐
                       │  consul-server       │
                       │  :8500 HTTP API      │
                       │  :8501 HTTPS         │
                       │  :8600 DNS           │
                       │  /v1/agent/metrics   │◄── Prometheus scrape
                       └──────────┬───────────┘
                                  │ xDS (gRPC)
                         ┌────────▼────────┐
                         │  consul-        │  (per pod, Kubernetes)
                         │  dataplane      │  (sidecar, Docker)
                         │  Envoy proxy    │
                         │  :20200/stats   │◄── Prometheus scrape
                         └────────┬────────┘
                   ┌──────────────┼──────────────┐
                   │              │              │
              access logs    Zipkin spans    passthrough
              (stdout/file)  :9411           traffic
                   │              │
                   ▼              ▼
         ┌──────────────────────────────────┐
         │   OpenTelemetry Collector        │
         │   - Receivers: OTLP, Zipkin,     │
         │     Prometheus, filelog          │
         │   - Processors: k8sattributes,   │
         │     memory_limiter, batch,       │
         │     resource/loki_labels         │
         │   - Exporters: Jaeger, Loki,     │
         │     Prometheus                   │
         └────────┬──────────┬──────────────┘
                  │          │          │
            OTLP/gRPC      Push      Scrape
                  │          │        endpoint
                  ▼          ▼          ▼
              Jaeger       Loki    Prometheus
              :16686       :3100     :9090
              (traces)     (logs)   (metrics)
                  │          │          │
                  └──────────┴──────────┘
                             │
                         Grafana :3000
                    (datasources: all three)
```

**Signal flow summary:**

| Signal | Source | Collector path | Storage | Visualization |
|--------|--------|---------------|---------|---------------|
| Metrics | Consul `/v1/agent/metrics`, Envoy `:20200/stats/prometheus` | Prometheus receiver | Prometheus | Grafana |
| Logs | Envoy access log (JSON, stdout) | Promtail (k8s) / filelog receiver (Docker) | Loki | Grafana |
| Traces | App OTLP `:4317`, Envoy Zipkin `:9411` | OTel Collector | Jaeger | Grafana / Jaeger UI |

---

## Metrics

### Enabling Metrics

#### Kubernetes

Metrics collection requires three separate configurations that must all be present:

**1. Consul Helm values** (`kubernetes/consul/values.yaml`):

```yaml
global:
  metrics:
    enabled: true
    enableAgentMetrics: true
    agentMetricsRetentionTime: "1m"

connectInject:
  metrics:
    defaultEnabled: true
    defaultEnableMerging: false      # CRITICAL — see note below
    defaultPrometheusScrapePort: 20200
```

> **`defaultEnableMerging`**: When `true`, consul-dataplane attempts to merge application `/metrics` with Envoy stats at port 20200. If the application does not expose a Prometheus `/metrics` endpoint, the merged output will contain error text (e.g. `"failed to fetch upstream metrics"`) which breaks Prometheus parsing with `strconv.ParseFloat` errors. Set to `false` unless your application explicitly exposes Prometheus metrics.

The Helm chart annotates each injected pod with:
```
prometheus.io/scrape: "true"
prometheus.io/port: "20200"
prometheus.io/path: "/stats/prometheus"
```

**2. ProxyDefaults CRD** (`kubernetes/consul/config-entries/proxy-defaults.yaml`):

```yaml
spec:
  config:
    envoy_prometheus_bind_addr: "0.0.0.0:20200"
```

This tells Envoy to bind its admin stats endpoint on all interfaces at port 20200 instead of the default localhost-only admin port.

**3. OTel Collector Prometheus receiver** (`shared/otel/otel-collector-k8s.yml`):

The collector scrapes both Consul agents and Envoy sidecars using Kubernetes service discovery.

#### Docker Compose

In Docker, service registration in `docker/consul/consul.hcl` includes:

```hcl
connect {
  sidecar_service {
    proxy {
      config { envoy_prometheus_bind_addr = "0.0.0.0:20200" }
    }
  }
}
```

And `docker/prometheus/prometheus.yml` directly scrapes:

```yaml
- job_name: consul
  metrics_path: /v1/agent/metrics
  params: { format: ['prometheus'] }
  static_configs: [{targets: ['consul:8500']}]

- job_name: envoy
  metrics_path: /stats/prometheus
  static_configs: [{targets: ['envoy-sidecar:20200']}]
```

---

### Scrape Job Summary

| Prometheus job | Target | Port / Path | Key metrics yielded |
|----------------|--------|-------------|---------------------|
| `consul-server` | `consul.consul.svc` | `:8500/v1/agent/metrics?format=prometheus` | `consul_raft_*`, `consul_catalog_*`, `consul_serf_*`, `consul_acl_*`, `consul_client_*`, `consul_state_*`, `consul_autopilot_*`, `consul_runtime_*` |
| `envoy-sidecars` | All pods with `prometheus.io/scrape="true"` annotation | `:20200/stats/prometheus` | `envoy_cluster_*`, `envoy_http_*`, `envoy_listener_*`, `envoy_server_*`, `envoy_tracing_*`, `consul_dataplane_*` |
| `api-gateway` | API Gateway Envoy pod | `:20200/stats/prometheus` | Same as envoy-sidecars; filtered by `job="api-gateway"` in dashboard queries |
| `terminating-gateway` | Terminating Gateway Envoy pod | `:20200/stats/prometheus` | `envoy_cluster_upstream_*`; filtered by `job="terminating-gateway"` |
| `otel-collector` | `otel-collector.observability.svc` | `:8888/metrics` | `otelcol_receiver_*`, `otelcol_exporter_*`, `otelcol_processor_*`, `otelcol_connector_*`, `otelcol_process_*` |
| `servicegraph` | `otel-collector.observability.svc` | `:8889/metrics` | `traces_service_graph_*` derived from Zipkin spans |

> **Label note:** Prometheus uses `honor_labels: false` by default, so the `job` label is always overwritten with the scrape job name. Metrics re-exported through the OTel Collector's Prometheus exporter on port `:8889` carry `job="servicegraph"` — not whatever job label the OTel receiver set internally.

---

### Consul Server Metrics

Exposed at `/v1/agent/metrics?format=prometheus` on `consul.consul.svc:8500`. All metrics are prefixed with `consul_`.

#### Cluster State (Point-in-Time)

These gauges snapshot the current state of the Consul cluster. Query them directly — no `rate()` needed.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_members_servers` | Gauge | Number of server agents in the datacenter | Consul Service Health → LAN Members |
| `consul_members_clients` | Gauge | Number of client / dataplane agents | Consul Service Health → LAN Members |
| `consul_state_service_instances` | Gauge | Total registered service instances | Consul Service Health → Registered Service Instances |
| `consul_state_billable_service_instances` | Gauge | Billable service instances (excludes Consul-internal services) | Consul Service Health → Service Instances |
| `consul_state_services` | Gauge | Number of unique service names registered | — |
| `consul_state_nodes` | Gauge | Number of nodes in the catalog | — |
| `consul_state_connect_instances` | Gauge | Connect-capable (mesh) service instances | — |
| `consul_state_config_entries` | Gauge | Config entries (ProxyDefaults, ServiceDefaults, ServiceIntentions, …) | — |
| `consul_state_kv_entries` | Gauge | Key/value store entries | — |
| `consul_autopilot_healthy` | Gauge | 1 = cluster is healthy per autopilot; 0 = degraded | Consul Service Health → Autopilot Healthy |
| `consul_autopilot_failure_tolerance` | Gauge | Server failures the cluster can absorb and still maintain quorum | — |
| `consul_agent_tls_cert_expiry` | Gauge | Seconds until this agent's TLS certificate expires | — |

#### Raft / Cluster Health

Raft is the consensus protocol keeping Consul servers in sync. These metrics reveal leader stability, replication lag, and throughput.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_raft_applied_index` | Gauge | Last log index applied to the FSM (state machine) | Consul Service Health → Raft Applied Index |
| `consul_raft_last_index` | Gauge | Latest log entry index in the leader's log | Consul Service Health → Raft Applied Index |
| `consul_raft_apply` | Counter | Raft log entries committed | — |
| `consul_raft_barrier` | Counter | Raft barrier operations (used to flush pending writes) | — |
| `consul_raft_commitTime` | Summary | Time (ms) to commit a log entry — high values indicate leader overload | — |
| `consul_raft_commitTime_sum` / `_count` | Counter | Sum/count for commitTime summary | — |
| `consul_raft_leader_lastContact` | Summary | Milliseconds since the leader last contacted a follower | — |
| `consul_raft_leader_lastContact_sum` / `_count` | Counter | Sum/count for lastContact summary | — |
| `consul_raft_leader_dispatchLog` | Summary | Time (ms) to dispatch a log entry to followers | — |
| `consul_raft_leader_oldestLogAge` | Gauge | Age (s) of the oldest uncompacted log entry | — |
| `consul_raft_fsm_apply` | Summary | Time (ms) for the FSM to apply a single log entry | — |
| `consul_raft_state_leader` | Counter | Times this node became Raft leader | — |
| `consul_raft_state_follower` | Counter | Times this node became a follower | — |
| `consul_raft_state_candidate` | Counter | Times this node started an election | — |
| `consul_raft_transition_heartbeat_timeout` | Counter | Leader heartbeat timeouts — indicates network instability | — |
| `consul_raft_snapshot_persist` | Summary | Time to persist a Raft snapshot | — |
| `consul_raft_thread_main_saturation` | Summary | Fraction (0–1) of time the main Raft thread is busy — >0.8 = saturated | — |
| `consul_raft_thread_fsm_saturation` | Summary | Fraction (0–1) of time the FSM apply thread is busy | — |
| `consul_raft_verify_leader` | Counter | Leadership verification checks — spikes indicate instability | — |
| `consul_raft_wal_log_appends` | Counter | WAL (write-ahead log) append operations | — |
| `consul_raft_wal_log_entries_written` | Counter | Log entries written to WAL | — |
| `consul_raft_wal_segment_rotations` | Counter | WAL segment rotations (file rollover) | — |
| `consul_raft_wal_last_segment_age_seconds` | Gauge | Age of the current WAL segment | — |

**Key thresholds:**
- `consul_raft_last_index - consul_raft_applied_index > 0` sustained → FSM is lagging behind the leader
- `consul_raft_leader_lastContact > 200 ms` → replication lag; `> 500 ms` → potential split-brain risk
- `consul_raft_state_candidate` increasing → repeated leader elections, indicates instability

#### Client API Activity

Tracks calls to the Consul HTTP API. Useful for understanding catalog registration churn and sidecar-driven lookups.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_client_api_success_catalog_register` | Counter | Successful `PUT /v1/catalog/register` API calls | Consul Service Health → Catalog API Activity |
| `consul_client_api_success_catalog_deregister` | Counter | Successful `PUT /v1/catalog/deregister` API calls | Consul Service Health → Catalog API Activity |
| `consul_client_api_catalog_register` | Counter | All catalog register attempts (success + error) | — |
| `consul_client_api_error_catalog_service_nodes` | Counter | Failed catalog service-node queries | — |
| `consul_client_api_success_catalog_service_nodes` | Counter | Successful catalog service-node queries (sidecar endpoint discovery) | — |
| `consul_client_rpc` | Counter | Total RPC calls the server made to process API requests | Consul Service Health → Consul RPC Request Rate |
| `consul_client_rpc_exceeded` | Counter | RPC calls that hit rate limits | — |
| `consul_client_rpc_failed` | Counter | Failed RPC calls | — |

#### Catalog & Health

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_catalog_register` | Summary | Time (ms) to process a service registration | — |
| `consul_catalog_deregister` | Summary | Time (ms) to process a service deregistration | — |
| `consul_catalog_service_query` | Counter | Catalog service queries served | — |
| `consul_catalog_connect_query` | Counter | Connect-capable service queries (sidecar discovery) | — |
| `consul_catalog_service_not_found` | Counter | Queries for services that do not exist | — |
| `consul_catalog_connect_not_found` | Counter | Connect service queries that returned no results | — |

#### Membership / Gossip

Consul uses the Serf library for cluster membership via gossip. These metrics reveal membership churn and gossip backpressure.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_serf_member_join` | Counter | Members joining the gossip pool | — |
| `consul_serf_events` | Counter | Gossip events processed (joins, leaves, failures) | — |
| `consul_serf_queue_Event` | Summary | Gossip event queue depth — spikes indicate processing backpressure | — |
| `consul_serf_queue_Intent` | Summary | Gossip intent queue depth — spikes indicate membership state divergence | — |
| `consul_serf_queue_Query` | Summary | Gossip query queue depth | — |
| `consul_serf_snapshot_appendLine` | Summary | Time to write a line to the gossip snapshot file | — |

#### ACL

ACL token resolution happens on every Consul RPC call. Latency here directly affects all control plane operations.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_acl_ResolveToken` | Summary | Time (ms) to resolve an ACL token | — |
| `consul_acl_ResolveToken_sum` / `_count` | Counter | Sum/count for ResolveToken | — |
| `consul_acl_token_cache_hit` | Counter | ACL token lookups served from cache (fast path) | — |
| `consul_acl_token_cache_miss` | Counter | ACL token lookups that required full resolution | — |
| `consul_acl_blocked_service_registration` | Counter | Service registrations blocked by ACL policy | — |
| `consul_acl_blocked_check_registration` | Counter | Health check registrations blocked by ACL policy | — |
| `consul_acl_login` | Summary | Time to complete a Consul login via auth method (token exchange) | — |

#### RPC

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_rpc_query` | Counter | RPC read queries handled | — |
| `consul_rpc_request` | Counter | Total RPC requests | — |
| `consul_rpc_request_error` | Counter | RPC requests that returned an error | — |
| `consul_rpc_consistentRead` | Summary | Time (ms) for a strongly-consistent linearizable read | — |
| `consul_rpc_queries_blocking` | Gauge | Blocking RPC queries currently in flight (long-poll watchers) | — |
| `consul_rpc_cross_dc` | Counter | Cross-datacenter RPC calls | — |
| `consul_rpc_rate_limit_exceeded` | Counter | RPC calls rate-limited by the server | — |
| `consul_rpc_accept_conn` | Counter | New RPC connections accepted | — |

#### Go Runtime

Present on all Consul server pods. Reflects Go runtime health.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_runtime_alloc_bytes` | Gauge | Bytes allocated and in use by the Go heap | Consul Service Health → Consul Runtime Memory |
| `consul_runtime_sys_bytes` | Gauge | Total bytes obtained from the OS by the Go runtime | Consul Service Health → Consul Runtime Memory |
| `consul_runtime_heap_objects` | Gauge | Objects on the Go heap — high values indicate GC pressure | — |
| `consul_runtime_num_goroutines` | Gauge | Active goroutines — unexpected growth = goroutine leak | Consul Service Health → Goroutines |
| `consul_runtime_gc_pause_ns` | Summary | GC pause duration in nanoseconds | — |

---

### Consul Dataplane Sidecar Metrics

Every pod injected with `consul.hashicorp.com/connect-inject: "true"` runs a `consul-dataplane` sidecar. This process manages the Envoy proxy and communicates with the Consul server over gRPC/xDS. Its metrics are prefixed `consul_dataplane_` and are scraped from `:20200` as part of the `envoy-sidecars` job.

#### Connectivity

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_dataplane_consul_connected` | Gauge | 1 = live gRPC connection to the Consul server; 0 = disconnected | — |
| `consul_dataplane_envoy_connected` | Gauge | 1 = live xDS connection to the local Envoy process; 0 = disconnected | — |
| `consul_dataplane_connection_errors` | Counter | Failed connection attempts to the Consul server | — |
| `consul_dataplane_connect_duration` | Summary | Time to establish the initial gRPC connection to Consul at startup | — |
| `consul_dataplane_discover_servers_duration` | Summary | Time to discover Consul server addresses at startup | — |
| `consul_dataplane_login_duration` | Summary | Time to authenticate and obtain an ACL token from Consul | — |

> **What to watch:** `consul_dataplane_consul_connected = 0` or `consul_dataplane_envoy_connected = 0` on any pod means that sidecar is cut off from the control plane. Traffic may continue using the last known xDS snapshot, but no configuration updates (new intentions, service routing changes) will take effect until reconnection.

#### Runtime

Standard Go process metrics emitted by the consul-dataplane binary itself.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `consul_dataplane_runtime_alloc_bytes` | Gauge | Go heap bytes in use | — |
| `consul_dataplane_runtime_num_goroutines` | Gauge | Active goroutines in consul-dataplane | — |
| `consul_dataplane_runtime_total_gc_pause_ns` | Counter | Cumulative GC pause time | — |
| `consul_dataplane_go_memstats_heap_alloc_bytes` | Gauge | Heap bytes allocated (Go standard metric) | — |
| `consul_dataplane_go_goroutines` | Gauge | Goroutines (Go standard prometheus metric) | — |

---

### Envoy Sidecar Metrics

Exposed at `:20200/stats/prometheus` on every consul-dataplane injected pod and on gateway pods. All metrics are prefixed with `envoy_`. The `envoy-sidecars` Prometheus job scrapes all pods with the `prometheus.io/scrape="true"` annotation set by the Helm chart.

Consul injects labels into cluster-level metrics that enable cross-service queries:

| Label | Meaning | Example |
|-------|---------|---------|
| `local_cluster` | The service this sidecar belongs to | `web` |
| `consul_source_service` | Service generating traffic (the caller) | `web` |
| `consul_destination_service` | Service receiving traffic (the callee) | `api` |
| `consul_destination_service_subset` | Traffic subset / canary variant | `v2` |
| `envoy_cluster_name` | Full internal Envoy cluster name | `api.default.dc1.internal…consul` |

#### Proxy / Server Health

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_server_live` | Gauge | 1 = Envoy is running; 0 = pre-initializing or draining | — |
| `envoy_server_state` | Gauge | 0=live, 1=draining, 2=pre-initializing, 3=initializing | — |
| `envoy_server_uptime` | Gauge | Seconds since this Envoy process started | — |
| `envoy_server_concurrency` | Gauge | Number of Envoy worker threads | — |
| `envoy_server_total_connections` | Gauge | All open TCP connections across all listeners | — |
| `envoy_server_memory_allocated` | Gauge | Bytes currently allocated by Envoy's allocator | — |
| `envoy_server_memory_heap_size` | Gauge | Total heap size reserved by the OS for Envoy | — |
| `envoy_server_memory_physical_size` | Gauge | Physical RAM consumed by the Envoy process | — |
| `envoy_server_days_until_first_cert_expiring` | Gauge | Days until the nearest mTLS leaf certificate expires — alert if <30 | — |
| `envoy_server_hot_restart_epoch` | Gauge | Hot restart generation (0 = never hot-restarted) | — |
| `envoy_server_version` | Gauge | Envoy version encoded as an integer | — |
| `envoy_server_main_thread_watchdog_miss` | Counter | Main thread watchdog misses — indicates event loop saturation | — |
| `envoy_server_worker_watchdog_miss` | Counter | Worker thread watchdog misses | — |

#### HTTP Downstream (Inbound)

Traffic arriving at this sidecar from within the mesh. In the Consul service mesh, inbound traffic arrives through Envoy's public listener and is routed to the local application container. For the **API Gateway**, all north-south HTTP traffic appears here.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_http_downstream_rq_total` | Counter | All HTTP requests received by this sidecar | Gateways → API GW Request Rate |
| `envoy_http_downstream_rq_http1_total` | Counter | HTTP/1.1 requests received | — |
| `envoy_http_downstream_rq_http2_total` | Counter | HTTP/2 requests received | — |
| `envoy_http_downstream_rq_active` | Gauge | Requests currently in flight (downstream perspective) | — |
| `envoy_http_downstream_rq_time_bucket` | Histogram | End-to-end request latency including upstream wait time | Gateways → API GW P99 Latency |
| `envoy_http_downstream_rq_time_sum` / `_count` | Counter | Sum/count for downstream latency histogram | — |
| `envoy_http_downstream_rq_xx` | Counter | Requests by response class; label `envoy_response_code_class` = 1/2/3/4/5 | — |
| `envoy_http_downstream_rq_2xx` | Counter | 2xx success responses | Gateways → API GW Request Rate by Status |
| `envoy_http_downstream_rq_4xx` | Counter | 4xx client error responses | Gateways → API GW Request Rate by Status |
| `envoy_http_downstream_rq_5xx` | Counter | 5xx server error responses | Gateways → API GW Error Rate |
| `envoy_http_downstream_rq_timeout` | Counter | Requests that timed out waiting for the upstream | — |
| `envoy_http_downstream_rq_idle_timeout` | Counter | Requests closed due to stream idle timeout | — |
| `envoy_http_downstream_rq_header_timeout` | Counter | Requests where headers took too long to arrive | — |
| `envoy_http_downstream_rq_overload_close` | Counter | Requests rejected by Envoy's overload manager | — |
| `envoy_http_downstream_rq_too_large` | Counter | Requests rejected because the body exceeded the buffer limit | — |
| `envoy_http_downstream_cx_total` | Counter | Total downstream connections established | — |
| `envoy_http_downstream_cx_active` | Gauge | Active downstream connections | — |
| `envoy_http_downstream_cx_ssl_total` | Counter | TLS-wrapped connections — should equal `cx_total` in an mTLS mesh | — |
| `envoy_http_downstream_cx_protocol_error` | Counter | Connections closed due to HTTP protocol errors | — |
| `envoy_http_downstream_cx_destroy_local` | Counter | Connections torn down by local Envoy | — |
| `envoy_http_downstream_cx_destroy_remote` | Counter | Connections torn down by the remote peer | — |
| `envoy_http_downstream_cx_rx_bytes_total` | Counter | Bytes received from downstream clients | — |
| `envoy_http_downstream_cx_tx_bytes_total` | Counter | Bytes sent to downstream clients | — |

#### Upstream Clusters (Outbound)

The most important metrics for inter-service traffic. Each upstream service has one Envoy cluster. These metrics appear on the **calling** sidecar, tagged with `consul_destination_service=<callee>`.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_cluster_upstream_rq_total` | Counter | Total requests sent to the upstream | Service Health → Request Volume; Service-to-Service → Request Rate; Gateways → TGW External RPS |
| `envoy_cluster_upstream_rq_active` | Gauge | Requests currently in flight to the upstream | — |
| `envoy_cluster_upstream_rq_xx` | Counter | Requests by response class (label `envoy_response_code_class` = 1/2/3/4/5) | Service Health → Error Rate; Service-to-Service → Error Rate & Status Class |
| `envoy_cluster_upstream_rq_time_bucket` | Histogram | Upstream request latency histogram (ms) — use for P50/P95/P99 | Service Health → P95 Latency; Service-to-Service → Response Time; Gateways → TGW P99 Latency |
| `envoy_cluster_upstream_rq_time_sum` / `_count` | Counter | Sum/count for upstream latency histogram | — |
| `envoy_cluster_upstream_rq_pending_active` | Gauge | Requests queued waiting for a free connection slot | — |
| `envoy_cluster_upstream_rq_pending_total` | Counter | Total requests that entered the pending queue | — |
| `envoy_cluster_upstream_rq_pending_overflow` | Counter | Requests dropped because the pending queue was full (circuit breaker) | — |
| `envoy_cluster_upstream_rq_pending_failure_eject` | Counter | Requests ejected from the pending queue due to outlier detection | — |
| `envoy_cluster_upstream_rq_timeout` | Counter | Requests that timed out waiting for an upstream response | — |
| `envoy_cluster_upstream_rq_per_try_timeout` | Counter | Individual retry attempt timeouts | — |
| `envoy_cluster_upstream_rq_retry` | Counter | Requests that triggered at least one retry | — |
| `envoy_cluster_upstream_rq_retry_success` | Counter | Retries that ultimately received a 2xx response | — |
| `envoy_cluster_upstream_rq_retry_limit_exceeded` | Counter | Requests that exhausted all retries | — |
| `envoy_cluster_upstream_rq_retry_overflow` | Counter | Retries dropped because the retry budget was exhausted | — |
| `envoy_cluster_upstream_rq_cancelled` | Counter | Requests cancelled before they could be sent | — |
| `envoy_cluster_upstream_rq_rx_reset` | Counter | Stream resets initiated by the upstream | — |
| `envoy_cluster_upstream_rq_tx_reset` | Counter | Stream resets initiated by this Envoy | — |
| `envoy_cluster_upstream_rq_completed` | Counter | Requests that received any response (2xx, 5xx, reset) | — |
| `envoy_cluster_upstream_cx_total` | Counter | Total TCP connections made to this upstream | — |
| `envoy_cluster_upstream_cx_active` | Gauge | Active persistent connections to the upstream | Service Health → Upstream Connections; Service-to-Service → Active Connections; Gateways → TGW Active Connections |
| `envoy_cluster_upstream_cx_connect_fail` | Counter | Failed TCP connection attempts | — |
| `envoy_cluster_upstream_cx_connect_timeout` | Counter | Connection attempts that exceeded the connect timeout | — |
| `envoy_cluster_upstream_cx_connect_attempts_exceeded` | Counter | Connection attempts that hit the maximum retry limit | — |
| `envoy_cluster_upstream_cx_none_healthy` | Counter | Requests dropped because all upstream endpoints were unhealthy | — |
| `envoy_cluster_upstream_cx_overflow` | Counter | Connections dropped because the per-cluster connection limit was reached | — |
| `envoy_cluster_upstream_cx_pool_overflow` | Counter | Connection pool exhausted — requests waited for a free connection | — |
| `envoy_cluster_upstream_cx_destroy_with_active_rq` | Counter | Connections closed while an active request was in progress | — |
| `envoy_cluster_upstream_cx_rx_bytes_total` | Counter | Bytes received from the upstream | — |
| `envoy_cluster_upstream_cx_tx_bytes_total` | Counter | Bytes sent to the upstream | — |
| `envoy_cluster_upstream_cx_http1_total` | Counter | HTTP/1.1 upstream connections | — |
| `envoy_cluster_upstream_cx_http2_total` | Counter | HTTP/2 upstream connections (used for Connect mTLS) | — |
| `envoy_cluster_upstream_cx_idle_timeout` | Counter | Connections closed after exceeding the idle timeout | — |

**Key PromQL examples:**

```promql
# P99 request latency from web to api
histogram_quantile(0.99,
  sum(rate(envoy_cluster_upstream_rq_time_bucket{
    consul_source_service="web",
    consul_destination_service="api"
  }[$__rate_interval])) by (le)
)

# 5xx error rate for the payments upstream (all callers)
sum(rate(envoy_cluster_upstream_rq_xx{
  consul_destination_service="payments",
  envoy_response_code_class="5"
}[$__rate_interval]))
/
sum(rate(envoy_cluster_upstream_rq_total{
  consul_destination_service="payments"
}[$__rate_interval]))
```

#### Listener (Connection Acceptance)

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_listener_downstream_cx_total` | Counter | Total connections accepted across all listeners | — |
| `envoy_listener_downstream_cx_active` | Gauge | Active connections across all listeners | — |
| `envoy_listener_downstream_cx_overflow` | Counter | Connections rejected because the per-listener connection limit was reached | — |
| `envoy_listener_downstream_cx_overload_reject` | Counter | Connections rejected by Envoy's overload manager (memory/CPU pressure) | — |
| `envoy_listener_downstream_global_cx_overflow` | Counter | Connections rejected due to the global connection limit | — |
| `envoy_listener_downstream_pre_cx_timeout` | Counter | Connections that timed out before a filter chain was selected | — |
| `envoy_listener_no_filter_chain_match` | Counter | Connections with no matching filter chain — misconfigured mTLS SNI or port | — |
| `envoy_listener_extension_config_missing` | Counter | ECDS filter config not yet downloaded — sidecar received traffic before xDS was ready | — |

Per-service inbound listeners are also exposed with the format `envoy_listener_http_<service>_<namespace>_<dc>_*`:

| Metric pattern | Description |
|----------------|-------------|
| `envoy_listener_http_<svc>_downstream_rq_completed` | Requests completed by this service's inbound listener |
| `envoy_listener_http_<svc>_downstream_rq_xx` | Responses by class on this service's inbound listener |

#### mTLS / TLS

Mutual TLS is used for all mesh traffic (SPIFFE certificates issued by Consul CA). These metrics verify that mTLS is working and that certificates are valid.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_listener_ssl_handshake` | Counter | Successful TLS handshakes on inbound connections | — |
| `envoy_listener_ssl_connection_error` | Counter | TLS handshake failures (certificate mismatch, expired cert, protocol error) | — |
| `envoy_listener_ssl_fail_verify_error` | Counter | Certificate verification failures | — |
| `envoy_listener_ssl_fail_verify_cert_hash` | Counter | Certificate hash mismatch during SPIFFE verification | — |
| `envoy_listener_ssl_fail_verify_san` | Counter | SAN (Subject Alternative Name) mismatch — wrong service identity | — |
| `envoy_listener_ssl_session_reused` | Counter | TLS sessions reused via session resumption (reduces handshake overhead) | — |
| `envoy_listener_ssl_certificate_expiration_unix_time_seconds` | Gauge | Unix timestamp of the nearest expiring leaf certificate | — |
| `envoy_listener_server_ssl_socket_factory_downstream_context_secrets_not_ready` | Counter | Times the TLS context had no valid certificate during a connection attempt | — |

> **What to watch:** `envoy_listener_ssl_fail_verify_san > 0` means a service is presenting a SPIFFE certificate for the wrong identity — this blocks all inbound traffic with TLS handshake failures. Correlate with Consul ACL policy changes, service name changes, or certificate rotation issues.

#### Health Checks

Envoy performs passive health checking based on upstream responses. Active health checks can also be configured but are not enabled by default in this stack.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_cluster_membership_healthy` | Gauge | Healthy endpoints in this upstream cluster | — |
| `envoy_cluster_membership_total` | Gauge | Total endpoints configured for this upstream | — |
| `envoy_cluster_membership_degraded` | Gauge | Endpoints in a degraded (partial health) state | — |
| `envoy_cluster_membership_excluded` | Gauge | Endpoints excluded by outlier detection | — |
| `envoy_cluster_membership_change` | Counter | Endpoint additions/removals driven by xDS updates from Consul | — |

> **What to watch:** `envoy_cluster_membership_healthy < envoy_cluster_membership_total` means some upstreams are unhealthy. When `envoy_cluster_membership_healthy = 0`, all traffic to that upstream is dropped with access log flag `UH` (no healthy upstream host).

#### Circuit Breakers (Capacity-Based)

Envoy enforces configurable limits on concurrent requests, connections, and retries per upstream cluster. When a limit is reached, Envoy immediately rejects new requests rather than queuing them. These are **gauge** metrics that flip between 0 and 1.

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_cluster_circuit_breakers_default_rq_open` | Gauge | 1 = max concurrent requests limit exceeded | — |
| `envoy_cluster_circuit_breakers_default_rq_pending_open` | Gauge | 1 = max pending requests limit exceeded | — |
| `envoy_cluster_circuit_breakers_default_rq_retry_open` | Gauge | 1 = max concurrent retries limit exceeded | — |
| `envoy_cluster_circuit_breakers_default_cx_open` | Gauge | 1 = max connections limit exceeded | — |
| `envoy_cluster_circuit_breakers_default_cx_pool_open` | Gauge | 1 = connection pool limit exceeded | — |
| `envoy_cluster_circuit_breakers_high_rq_open` | Gauge | Same as above for high-priority request traffic | — |
| `envoy_cluster_circuit_breakers_high_cx_open` | Gauge | Connection circuit breaker for high-priority traffic | — |

> **Effect:** When a circuit breaker opens (`= 1`), Envoy returns `503` to new requests with the response flag `UO` (upstream overflow) in the access log. The counter metric `envoy_cluster_upstream_rq_pending_overflow` increments for each rejected request.

#### Outlier Detection (Success-Rate-Based)

Consul configures Envoy with passive outlier detection. When an upstream endpoint returns consecutive 5xx errors or gateway failures it is temporarily ejected from the load-balancing pool — this is what the Grafana dashboards call "circuit breaking."

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_cluster_outlier_detection_ejections_active` | Gauge | Endpoints currently ejected from the upstream pool | Service Health → Active Circuit Breakers |
| `envoy_cluster_outlier_detection_ejections_consecutive_5xx` | Gauge | Running count of consecutive 5xx errors on the most-affected endpoint | Service Health → Circuit Breakers Triggered |
| `envoy_cluster_outlier_detection_ejections_total` | Counter | Total ejection events (endpoint declared unhealthy) | — |
| `envoy_cluster_outlier_detection_ejections_overflow` | Counter | Ejection attempts blocked because max ejection percentage was already reached | — |
| `envoy_cluster_outlier_detection_ejections_enforced_consecutive_5xx` | Counter | Ejections actually enforced for consecutive 5xx (vs detected but suppressed) | — |
| `envoy_cluster_outlier_detection_ejections_enforced_consecutive_gateway_failure` | Counter | Ejections enforced for consecutive gateway failures (connect errors, resets) | — |
| `envoy_cluster_outlier_detection_ejections_enforced_success_rate` | Counter | Ejections enforced because an endpoint's success rate fell below threshold | — |
| `envoy_cluster_outlier_detection_ejections_enforced_failure_percentage` | Counter | Ejections enforced based on failure percentage threshold | — |
| `envoy_cluster_outlier_detection_ejections_detected_consecutive_5xx` | Counter | Ejections detected (includes some suppressed by max_ejection_percent) | — |

> **Dashboard note:** The Service Health "Circuit Breakers Triggered" panel uses:
> ```promql
> sum(max_over_time(envoy_cluster_outlier_detection_ejections_consecutive_5xx[$__range]))
>   by (consul_destination_service)
> ```
> This is a **gauge** metric. Do **not** use `increase()` or `rate()` — Grafana will generate a warning and the result will be meaningless.

#### xDS / Control Plane

These metrics show how Envoy receives and applies configuration updates pushed by the Consul server via xDS (the Envoy discovery service API).

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_listener_manager_lds_update_success` | Counter | Successful LDS (Listener Discovery Service) config updates received | — |
| `envoy_listener_manager_lds_update_failure` | Counter | LDS updates that Envoy failed to apply | — |
| `envoy_listener_manager_lds_update_rejected` | Counter | LDS updates rejected by Envoy (schema validation failure) | — |
| `envoy_listener_manager_lds_update_attempt` | Counter | Total LDS update attempts from the control plane | — |
| `envoy_listener_manager_lds_update_duration` | Histogram | Time (ms) to apply an LDS update | — |
| `envoy_listener_manager_total_listeners_active` | Gauge | Number of active listeners currently configured | — |
| `envoy_listener_manager_total_listeners_warming` | Gauge | Listeners waiting for dependencies (e.g. TLS secrets) — should be 0 at steady state | — |
| `envoy_listener_manager_total_listeners_draining` | Gauge | Listeners draining connections before removal | — |
| `envoy_listener_manager_total_filter_chains_draining` | Gauge | Filter chains being drained during hot listener updates | — |
| `envoy_listener_manager_listener_create_failure` | Counter | Failures creating a new listener | — |

> **What to watch:** `envoy_listener_manager_lds_update_failure > 0` means Envoy is rejecting config pushed by Consul. Mesh config changes (new ServiceIntentions, ProxyDefaults edits) will not take effect. Check consul-dataplane container logs for the xDS rejection reason.

#### Tracing

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `envoy_tracing_zipkin_spans_sent` | Counter | Zipkin spans successfully delivered to the OTel Collector | — |
| `envoy_tracing_zipkin_timer_flushed` | Counter | Span batches flushed (one flush = multiple spans) | — |
| `envoy_tracing_zipkin_reports_sent` | Counter | Zipkin report batches sent (equivalent to `timer_flushed`) | — |
| `envoy_tracing_zipkin_reports_dropped` | Counter | Span batches dropped because the outbound queue was full | — |
| `envoy_tracing_zipkin_reports_failed` | Counter | Span batches that failed to reach the OTel Collector (network error) | — |
| `envoy_tracing_zipkin_reports_skipped_no_cluster` | Counter | Spans skipped because the `otel_zipkin` static cluster is not yet ready | — |

> **Troubleshooting:** If `envoy_tracing_zipkin_spans_sent` stays at 0 but `envoy_tracing_zipkin_reports_skipped_no_cluster` is incrementing, the static cluster pointing to the OTel Collector is misconfigured or the Collector is unreachable. Verify `envoy_extra_static_clusters_json` in the `ProxyDefaults` CRD.

---

### OTel Servicegraph Metrics

The OTel Collector's **servicegraph connector** consumes Zipkin spans emitted by Envoy sidecars, matches client/server span pairs, and derives metrics that describe the call graph between services. These are exported via Prometheus on port `:8889` and scraped by Prometheus under `job="servicegraph"`.

| Metric | Type | Labels | Description | Dashboard |
|--------|------|--------|-------------|-----------|
| `traces_service_graph_request_total` | Counter | `client`, `server`, `connection_type`, `failed`, `status_code` | Total requests observed between a service pair. Powers both the node list and the edge weights in the Service Dependency Map. | Service-to-Service → Service Dependency Map |
| `traces_service_graph_request_client_seconds_bucket` | Histogram | `client`, `server`, … | Client-side latency (span duration from the caller's perspective). Use for cross-service P99 derived from traces. | Service-to-Service → Response Time |
| `traces_service_graph_request_client_seconds_sum` / `_count` | Counter | Same | Sum/count for client-side latency histogram | — |
| `traces_service_graph_request_server_seconds_bucket` | Histogram | `client`, `server`, … | Server-side latency (span duration from the callee's perspective). Includes processing time only, not network round-trip. | — |
| `traces_service_graph_request_server_seconds_sum` / `_count` | Counter | Same | Sum/count for server-side latency histogram | — |

**Label reference for servicegraph metrics:**

| Label | Description | Example |
|-------|-------------|---------|
| `client` | Service name of the caller (extracted from the local root span) | `web` |
| `server` | Service name of the callee (extracted from span peer attributes) | `api` |
| `connection_type` | `virtual_node`, `virtual_server`, or empty (direct mesh call) | `` |
| `failed` | `true` if the request resulted in an error span | `false` |
| `status_code` | gRPC/HTTP status code class | `STATUS_CODE_UNSET` |

**How the Service Dependency Map is built:**

```promql
# Edges — service-to-service links with request rate as weight
sum by (client, server) (
  rate(traces_service_graph_request_total{client!="", server!=""}[5m])
)

# Nodes — individual services extracted from the server label
sum by (node_id) (
  label_replace(
    rate(traces_service_graph_request_total{server!=""}[5m]),
    "node_id", "$1", "server", "(.+)"
  )
)
```

> **Why `label_replace`?** Grafana's Node Graph panel requires a `node_id` field in the nodes data frame and `source`/`target` fields in the edges data frame. Both frames come from the same metric, so `label_replace` creates a distinct `node_id` label from the `server` label to differentiate the two query results without adding a new Prometheus label.

**Servicegraph connector self-metrics** (scraped from `:8888` under `job="otel-collector"`):

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `otelcol_connector_servicegraph_total_edges` | Counter | Total span pairs matched (client + server spans combined into one edge) | — |
| `otelcol_connector_servicegraph_expired_edges` | Counter | Edges that expired before the matching span arrived — indicates span pairing timeouts | — |

> **Troubleshooting:** If `traces_service_graph_request_total` has no data but `otelcol_connector_servicegraph_expired_edges` is rising, the connector is receiving only client **or** server spans — not both. Ensure both the calling and the called service have Connect inject enabled so both sidecars emit Zipkin spans.

---

### OTel Collector Self-Metrics

The OTel Collector exposes its own operational metrics at `:8888/metrics` (scraped as `job="otel-collector"`). These are essential for verifying that the telemetry pipeline is functioning end-to-end.

#### Receivers (Ingestion)

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `otelcol_receiver_accepted_spans` | Counter | Spans accepted into the pipeline. Labels: `receiver` (zipkin, otlp), `transport` | — |
| `otelcol_receiver_refused_spans` | Counter | Spans rejected — parse errors or capacity exceeded | — |
| `otelcol_receiver_accepted_metric_points` | Counter | Metric data points accepted from Prometheus scrapes | — |
| `otelcol_receiver_refused_metric_points` | Counter | Metric points rejected | — |

#### Processors

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `otelcol_processor_accepted_spans` | Counter | Spans accepted by the processor chain | — |
| `otelcol_processor_dropped_spans` | Counter | Spans dropped, usually by `memory_limiter` when RAM is constrained | — |
| `otelcol_processor_refused_spans` | Counter | Spans refused by a processor | — |
| `otelcol_processor_batch_batch_send_size` | Histogram | Spans per batch sent to exporters — larger batches are more efficient | — |
| `otelcol_processor_batch_batch_size_trigger_send` | Counter | Batches sent because the size threshold was reached | — |
| `otelcol_processor_batch_timeout_trigger_send` | Counter | Batches sent because the timeout fired (batch not yet full) | — |
| `otelcol_processor_batch_metadata_cardinality` | Gauge | Unique metadata combinations in the batcher — high values indicate label cardinality explosion | — |

#### Exporters (Delivery)

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `otelcol_exporter_sent_spans` | Counter | Spans successfully exported. Labels: `exporter` (jaeger, otlp) | — |
| `otelcol_exporter_send_failed_spans` | Counter | Spans that failed to export — backend down or timeout | — |
| `otelcol_exporter_sent_metric_points` | Counter | Metric data points exported | — |
| `otelcol_exporter_send_failed_metric_points` | Counter | Metric points that failed to export | — |
| `otelcol_exporter_queue_size` | Gauge | Current depth of the retry/send queue | — |
| `otelcol_exporter_queue_capacity` | Gauge | Maximum queue capacity | — |

#### Process

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `otelcol_process_uptime` | Counter | Seconds since the collector started | — |
| `otelcol_process_cpu_seconds` | Counter | CPU time consumed by the collector process | — |
| `otelcol_process_memory_rss` | Gauge | Resident set size — physical RAM consumed by the collector | — |
| `otelcol_process_runtime_heap_alloc_bytes` | Gauge | Go heap bytes currently in use | — |
| `otelcol_process_runtime_total_alloc_bytes` | Counter | Total bytes ever allocated by the Go runtime | — |

#### Kubernetes Metadata Enrichment

| Metric | Type | Description | Dashboard |
|--------|------|-------------|-----------|
| `otelcol_otelsvc_k8s_pod_added` | Counter | Pods added to the k8sattributes processor's watch cache | — |
| `otelcol_otelsvc_k8s_pod_updated` | Counter | Pod metadata updates processed by k8sattributes | — |
| `otelcol_otelsvc_k8s_pod_deleted` | Counter | Pods removed from the watch cache | — |
| `otelcol_otelsvc_k8s_pod_table_size` | Gauge | Current number of pods in the metadata cache | — |

**Pipeline health check:**

```promql
# Confirm spans are reaching Jaeger
rate(otelcol_exporter_sent_spans{exporter="jaeger"}[5m])

# Detect exporter failures
rate(otelcol_exporter_send_failed_spans[5m]) > 0

# Check if memory_limiter is dropping spans
rate(otelcol_processor_dropped_spans[5m]) > 0

# Verify servicegraph is producing edges
rate(otelcol_connector_servicegraph_total_edges[5m])
```

---

## Logs

### Envoy Access Logs

Envoy emits one JSON log record per HTTP transaction on its access log. In this stack:

- **Docker**: Written to a mounted file (`/var/log/envoy/access.log`) and collected by the OTel filelog receiver.
- **Kubernetes**: Written to stdout, collected by Promtail from `/var/log/pods/`.

**Access log JSON format** (configured in `docker/envoy/envoy-access-log.json`):

```json
{
  "start_time":            "%START_TIME%",
  "method":                "%REQ(:METHOD)%",
  "path":                  "%REQ(X-ENVOY-ORIGINAL-PATH?:PATH)%",
  "protocol":              "%PROTOCOL%",
  "response_code":         "%RESPONSE_CODE%",
  "response_flags":        "%RESPONSE_FLAGS%",
  "bytes_received":        "%BYTES_RECEIVED%",
  "bytes_sent":            "%BYTES_SENT%",
  "duration":              "%DURATION%",
  "upstream_service_time": "%RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%",
  "x_forwarded_for":       "%REQ(X-FORWARDED-FOR)%",
  "user_agent":            "%REQ(USER-AGENT)%",
  "request_id":            "%REQ(X-REQUEST-ID)%",
  "traceparent":           "%REQ(TRACEPARENT)%",
  "tracestate":            "%REQ(TRACESTATE)%",
  "authority":             "%REQ(:AUTHORITY)%",
  "upstream_host":         "%UPSTREAM_HOST%",
  "upstream_cluster":      "%UPSTREAM_CLUSTER%",
  "upstream_local_address":"%UPSTREAM_LOCAL_ADDRESS%",
  "downstream_local_address":"%DOWNSTREAM_LOCAL_ADDRESS%",
  "downstream_remote_address":"%DOWNSTREAM_REMOTE_ADDRESS%"
}
```

**Key fields:**

| Field | Description |
|-------|-------------|
| `start_time` | Request start timestamp (ISO 8601) |
| `method` | HTTP method |
| `path` | URL path (using original path when rewritten) |
| `response_code` | HTTP status code returned to the client |
| `response_flags` | Envoy flags for non-standard conditions (see below) |
| `duration` | Total request duration in milliseconds (Envoy end-to-end) |
| `upstream_service_time` | Time the upstream spent processing (from `x-envoy-upstream-service-time` header) |
| `upstream_cluster` | Name of the Envoy cluster that handled this request |
| `traceparent` | W3C trace context header — contains `trace_id` and `span_id` |
| `request_id` | Envoy-generated request ID (unique per transaction) |

**Response flags** (`response_flags` field values):

| Flag | Meaning |
|------|---------|
| `-` | No special condition |
| `UH` | No healthy upstream hosts |
| `UF` | Upstream connection failure |
| `UO` | Upstream overflow (circuit breaker) |
| `NR` | No route configured |
| `URX` | Upstream retry limit exceeded |
| `RL` | Rate limited |
| `UC` | Upstream connection termination |
| `DC` | Downstream connection termination |
| `LH` | Local service failed health check |

---

### Kubernetes Pod Logs via Promtail

In Kubernetes, Promtail runs as a DaemonSet and tails log files from the node's `/var/log/pods/` directory.

**How Kubernetes structures log files on the node:**

```
/var/log/pods/
  <namespace>_<pod-name>_<pod-uid>/
    <container-name>/
      0.log       ← current log file (rotates to 1.log, 2.log, ...)
```

**Promtail scrape config** (`kubernetes/observability/promtail.yaml`):

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # Only scrape namespaces relevant to this stack
      - source_labels: [__meta_kubernetes_namespace]
        regex: "default|consul|observability"
        action: keep

      # Construct the exact path from k8s metadata
      - source_labels:
          - __meta_kubernetes_namespace
          - __meta_kubernetes_pod_name
          - __meta_kubernetes_pod_uid
          - __meta_kubernetes_pod_container_name
        separator: _
        regex: '(.+)_(.+)_(.+)_(.+)'
        target_label: __path__
        replacement: /var/log/pods/${1}_${2}_${3}/${4}/*.log

      # Extract labels
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_container_name]
        target_label: container
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
```

**Promtail pipeline stages** (applied per log line):

```yaml
pipeline_stages:
  # Try to parse Envoy JSON access logs
  - json:
      expressions:
        trace_id: '"traceparent"'
        level: '"response_code"'
  # Extract trace ID from traceparent header
  - regex:
      expression: '00-(?P<trace_id>[a-f0-9]{32})-'
      source: trace_id
  # Promote extracted fields to labels
  - labels:
      trace_id:
      level:
```

**Promtail readiness check:**

```bash
# Port-forward to Promtail
kubectl port-forward -n observability daemonset/promtail 9080:9080

# Check readiness
curl http://localhost:9080/ready

# Metrics to verify log discovery
curl -s http://localhost:9080/metrics | grep -E \
  "promtail_files_active|promtail_targets_active|promtail_sent_entries"
```

---

### Loki Label Strategy

Labels in Loki are indexed. Choosing too many high-cardinality labels causes performance issues. This stack uses a minimal, stable set.

**Labels on all log streams:**

| Label | Source | Cardinality | Notes |
|-------|--------|-------------|-------|
| `namespace` | k8s namespace | Low (~3) | `default`, `consul`, `observability` |
| `pod` | pod name | Medium | Changes on restart |
| `container` | container name | Low | Stable per deployment |
| `app` | pod `app=` label | Low | Maps to service name |
| `k8s.deployment.name` | OTel k8sattributes (for OTLP logs) | Low | Deployment name |
| `level` | Extracted from log content | Low | `info`, `warn`, `error`, `debug` |

**Querying logs in Grafana / LogQL:**

```logql
# All logs from nginx service
{app="nginx"} | json

# Error logs across all default namespace services
{namespace="default"} |= "error" | json

# Trace-correlated logs (copy trace ID from Jaeger)
{namespace="default"} | json | trace_id="4bf92f3577b34da6a3ce929d0e0e4736"

# Envoy access logs for a specific upstream
{app="nginx"} | json | upstream_cluster =~ ".*frontend.*"

# Rate of 5xx responses in logs
rate({app="nginx"} | json | response_code >= 500 [1m])
```

---

### Log-to-Trace Correlation

The Grafana Loki datasource is configured with a derived field that extracts the trace ID from Envoy access logs and creates a deep link to Jaeger:

```yaml
# shared/grafana/provisioning/datasources/datasources.yml
- name: Loki
  type: loki
  jsonData:
    derivedFields:
      - name: TraceID
        matcherRegex: '"traceparent":"00-([0-9a-f]{32})-'
        url: "$${__value.raw}"
        datasourceUid: jaeger
```

When viewing Envoy access logs in Grafana, any log line containing a `traceparent` header shows a **TraceID** link button. Clicking it opens the corresponding trace in Jaeger, showing the full distributed trace for that specific HTTP request.

---

## Distributed Tracing

### Envoy Zipkin Tracing

Every Envoy sidecar in the mesh is configured to emit Zipkin-format spans to the OTel Collector. Configuration lives in the `ProxyDefaults` CRD (Kubernetes) or `consul.hcl` (Docker).

**How it works:**

1. A request arrives at the Envoy inbound listener.
2. Envoy checks for an existing `traceparent` header. If absent, it generates a new trace ID and span ID.
3. Envoy adds the `traceparent` header to the upstream request, propagating the trace context.
4. When the request completes, Envoy asynchronously flushes a Zipkin span to the `otel_zipkin` cluster.
5. The OTel Collector receives the span, enriches it with Kubernetes metadata, and forwards it to Jaeger via OTLP/gRPC.

**ProxyDefaults tracing config:**

```yaml
spec:
  config:
    envoy_tracing_json: |
      {
        "http": {
          "name": "envoy.tracers.zipkin",
          "typedConfig": {
            "@type": "type.googleapis.com/envoy.config.trace.v3.ZipkinConfig",
            "collector_cluster": "otel_zipkin",
            "collector_endpoint_version": "HTTP_JSON",
            "collector_endpoint": "/api/v2/spans",
            "shared_span_context": true
          }
        }
      }

    envoy_extra_static_clusters_json: |
      {
        "name": "otel_zipkin",
        "type": "STRICT_DNS",
        "connect_timeout": "5s",
        "load_assignment": {
          "cluster_name": "otel_zipkin",
          "endpoints": [{
            "lb_endpoints": [{
              "endpoint": {
                "address": {
                  "socket_address": {
                    "address": "otel-collector.observability.svc.cluster.local",
                    "port_value": 9411
                  }
                }
              }
            }]
          }]
        }
      }
```

**`shared_span_context: true`** causes Envoy to share the same span ID between the ingress and egress of a proxy hop (rather than creating a child span). This matches the Zipkin shared-span model.

**Span attributes added by Envoy:**

| Attribute | Example value |
|-----------|---------------|
| `http.method` | `GET` |
| `http.url` | `http://frontend:3000/` |
| `http.status_code` | `200` |
| `upstream_cluster` | `frontend.default.dc1.internal...consul` |
| `node_id` | `<pod-name>.default` |
| `component` | `proxy` |

---

### Application OTLP Tracing

Application services can send traces directly to the OTel Collector over OTLP. This produces application-level spans (function calls, DB queries, external HTTP calls) which can be correlated with Envoy proxy spans in the same trace.

**Docker environment variables** (set in `docker-compose.yml`):

```yaml
environment:
  - OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
  - OTEL_SERVICE_NAME=example-app
  - OTEL_TRACES_EXPORTER=otlp
  - OTEL_PROPAGATORS=tracecontext,baggage
```

**Kubernetes** (add to service Deployment spec):

```yaml
env:
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://otel-collector.observability.svc.cluster.local:4317"
  - name: OTEL_SERVICE_NAME
    value: "frontend"
  - name: OTEL_TRACES_EXPORTER
    value: "otlp"
  - name: OTEL_PROPAGATORS
    value: "tracecontext,baggage"
```

The HashiCups services (`frontend`, `public-api`, `product-api`, `payments`) do **not** have OTLP instrumented in their binaries by default. Only Envoy-level spans are available for these services in the current Kubernetes deployment.

---

### Trace Context Propagation

This stack uses the **W3C Trace Context** standard (`traceparent` / `tracestate` headers), not the legacy B3 format.

**`traceparent` header format:**

```
00-<trace-id-32hex>-<parent-span-id-16hex>-<flags-2hex>
```

Example:
```
00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
  ^  ^                                ^                ^
  |  trace ID (128-bit)               parent span ID   flags (01=sampled)
  version (always 00)
```

Envoy reads and writes `traceparent`. When a service mesh request passes through multiple Envoy sidecars (e.g. nginx → frontend → public-api → product-api), each hop creates a child span with the trace ID preserved, enabling full end-to-end trace assembly in Jaeger.

**Propagation through the HashiCups call chain:**

```
client → nginx:20200 → frontend:3000 → public-api:8080 → product-api:9090
           │ Envoy span  │ Envoy span     │ Envoy span       │ Envoy span
           └─────────────┴────────────────┴──────────────────┘
                         same trace ID, parent-child span chain
```

---

### Sampling Configuration

**Default behavior:** Consul configures Envoy's HTTP Connection Manager (HCM) tracing block. When `envoy_tracing_json` is set in ProxyDefaults, the sampling rate is controlled by the HCM `random_sampling` field.

**Consul 1.22.x known issue:** Consul 1.22.x sets `random_sampling: {}` (an empty `RuntimeFractionalPercent` proto) in the generated HCM config, which evaluates to **0% sampling**. This means zero spans are generated even though Zipkin is configured and the `otel_zipkin` cluster is reachable.

**Diagnosis:**

```bash
# Get Envoy config dump from a running pod
kubectl exec -n default <pod-name> -c consul-dataplane -- \
  wget -qO- http://localhost:19000/config_dump

# Look for tracing block — broken state shows:
# "tracing": { "random_sampling": {} }

# Confirm with stats
kubectl exec -n default <pod-name> -c consul-dataplane -- \
  wget -qO- http://localhost:19000/stats | grep "tracing\."
# tracing.not_traceable: <N>   ← non-zero = 0% sampling
# tracing.random_sampling: 0   ← never increments
```

**Workaround options:**

1. **Upgrade Consul**: Fixed in later 1.22.x patch releases. Check Consul changelogs.

2. **Override via `envoy_public_listener_json`** in ProxyDefaults: Provide a complete HCM JSON with `random_sampling` set explicitly. This is complex and version-sensitive.

3. **App-level OTLP tracing**: Bypass Envoy for spans entirely by adding OTLP SDKs to each application. This produces richer application-level spans and is unaffected by the HCM sampling bug.

---

## OpenTelemetry Collector Pipeline

The OTel Collector is the central telemetry hub. It handles all three signals (metrics, logs, traces) in a single process.

### Kubernetes Pipeline

```
RECEIVERS                  PROCESSORS                   EXPORTERS
─────────                  ──────────                   ─────────

otlp/:4317,4318 ──────►  memory_limiter ──────────►  otlp/jaeger
  (app traces)            k8sattributes               (Jaeger :4317)
                          attributes/mesh
                          batch

zipkin/:9411 ─────────►  memory_limiter ──────────►  otlp/jaeger
  (Envoy spans)           k8sattributes
                          attributes/mesh
                          attributes/envoy
                          batch

otlp (logs) ──────────►  memory_limiter ──────────►  loki
  (app OTLP logs)         k8sattributes               debug
                          resource/loki_labels
                          batch

prometheus ───────────►  memory_limiter ──────────►  prometheus exporter
  (consul, envoy)         k8sattributes               (:8889/metrics)
                          batch
```

### Processor Details

**`memory_limiter`**: Hard-limits the collector's memory usage. Drops telemetry if RSS exceeds the configured limit. Prevents OOM kills under load.

```yaml
memory_limiter:
  check_interval: 5s
  limit_mib: 512
  spike_limit_mib: 128
```

**`k8sattributes`**: Enriches every telemetry record with Kubernetes metadata by querying the API server based on the sender's IP address.

Adds:
- `k8s.namespace.name`
- `k8s.pod.name`
- `k8s.node.name`
- `k8s.deployment.name`
- `app` (from pod label)

**`resource/loki_labels`**: Promotes resource attributes to Loki stream labels using the `loki.resource.labels` hint. Only attributes listed here become indexed Loki labels.

```yaml
resource/loki_labels:
  attributes:
    - action: insert
      key: loki.resource.labels
      value: "k8s.namespace.name, k8s.pod.name, app, k8s.deployment.name"
```

**`batch`**: Buffers telemetry records and sends them in bulk to exporters. Reduces the number of HTTP/gRPC calls and improves throughput.

---

## Grafana Dashboards

All dashboards live under the **Consul Observability** folder in Grafana and are provisioned automatically at startup — no manual import needed. Credentials: `admin / admin`.

There are five dashboards, each covering a distinct observability concern. The sections below explain what each dashboard shows, why it matters, and how to read it.

---

### 1. Service Health (`service-health.json`)

**UID:** `ffbs6tb0gr4lcb` · **Datasource:** Prometheus

**Why it matters:** This is the first dashboard to open when something is wrong. It answers the question *"which service is unhealthy right now, and how bad is it?"* across the entire mesh simultaneously. Instead of checking services one by one, you get error rates, latency, and circuit breaker state for every service pair on a single screen.

#### Row: Services Health

| Panel | Type | What it shows | Why it matters |
|-------|------|---------------|----------------|
| **Services with High Error Rate** | Time series | Per service-pair 5xx error rate as a percentage. Threshold lines at 1% and 5%. | The first signal of a failing upstream. A spike here means callers are receiving errors — look at which `consul_destination_service` is the source. |
| **P95 Latency** | Time series | 95th-percentile upstream response time per service pair (ms). | Latency spikes before errors do. A rising P95 on `payments → currency` warns you before callers start timing out. |
| **Request Volume** | Time series | Requests per second per service pair. | Puts error rate in context. A 10% error rate at 1 RPS is noise; the same at 1000 RPS is an incident. Also shows the load-generator traffic baseline. |
| **Upstream Connections** | Time series | Active open connections per service pair. | Connection pool exhaustion shows up here before request failures do. Steady growth with no drop means connections are leaking. |

**PromQL used:**

```promql
-- Error rate per service pair
(1 - (
  sum(irate(envoy_cluster_upstream_rq_xx{
    envoy_response_code_class!="5",
    consul_destination_service!=""
  }[5m])) by (local_cluster, consul_destination_service)
  /
  sum(irate(envoy_cluster_upstream_rq_xx{
    consul_destination_service!=""
  }[5m])) by (local_cluster, consul_destination_service)
)) * 100

-- P95 latency per service pair
histogram_quantile(0.99,
  sum(rate(envoy_cluster_upstream_rq_time_bucket{
    consul_destination_service!~""
  }[5m])) by (le, local_cluster, consul_destination_service)
)
```

#### Row: Circuit Breaker

| Panel | Type | What it shows | Why it matters |
|-------|------|---------------|----------------|
| **Active Circuit Breakers** | Time series | Number of backends currently ejected by Envoy outlier detection, per service pair. | A value > 0 means Envoy has removed at least one backend pod from the load balancing pool. Callers are fast-failing instead of waiting. This is the circuit is **open**. |
| **Circuit Breakers Triggered** | Bar gauge | Peak count of consecutive 5xx ejections per destination service over the selected time range. | A summary of *which services caused circuit breaking* during a time window. Useful for post-incident review: "payments triggered circuit breaking 3 times during the incident." |

**How to use circuit breaker panels in a demo:**

1. Inject 100% errors on `payments`: `kubectl set env deployment/payments ERROR_RATE=1.0 -n default`
2. **Active Circuit Breakers** rises from 0 to 1 within seconds.
3. **P95 Latency** for `api → payments` drops (Envoy is fast-failing, not waiting).
4. **Error Rate** for `api → payments` climbs to 100%.
5. Restore: `kubectl set env deployment/payments ERROR_RATE=0 -n default`

---

### 2. Consul Service Health (`consul-health.json`)

**UID:** `consul-health` · **Datasource:** Prometheus

**Why it matters:** The mesh only works if Consul is healthy. This dashboard monitors the Consul control plane itself — not the services running inside the mesh. It answers *"is Consul operating correctly?"* A degraded Consul server means sidecars cannot get new service discovery updates, ACL tokens cannot be resolved, and config changes cannot be distributed.

#### Panels

| Panel | Type | What it shows | Why it matters |
|-------|------|---------------|----------------|
| **LAN Members** | Stat | Total Consul gossip members (servers + clients). Formula: `consul_members_servers + consul_members_clients`. | A number lower than expected means a node left or crashed the gossip pool. In this demo: expected value is 1 (single server, no clients). |
| **Service Instances** | Stat | Count of service instances registered in the Consul catalog (`consul_state_billable_service_instances`). | Tracks how many things Consul is tracking. Unexpected drops mean services deregistered — possibly due to health check failures or pod restarts. |
| **Autopilot Healthy** | Stat | Consul autopilot health check result (1 = healthy, 0 = degraded). | Green = the cluster is operationally sound. Red means Consul has detected a problem with its own state — raft cannot commit, or a server is unreachable. |
| **Catalog API Activity** | Time series | Rate of catalog register / deregister API calls per second. | Shows mesh churn. A burst of deregistrations followed by registrations means pods restarted. Sustained deregistrations with no re-registrations means services are gone. |
| **Consul RPC Request Rate** | Time series | Incoming RPC calls per second to the Consul server. | Baseline traffic from sidecars doing health checks and service discovery. A sudden spike can indicate a thundering herd after a restart. |
| **Raft Applied Index** | Time series | Monotonically increasing Raft commit index (applied vs last). | The gap between `applied_index` and `last_index` indicates replication lag. They should be equal or within 1-2 entries. A widening gap means the leader is struggling to replicate. |
| **Consul Runtime Memory** | Time series | Go heap allocated bytes and total reserved bytes. | Memory growth without a corresponding drop signals a leak. In a healthy single-server demo deployment, this should stay flat. |
| **Goroutines** | Time series | Active goroutines in the Consul server process. | Goroutines in Go are cheap, but unbounded growth (e.g. from stuck RPC connections) indicates a bug or leak. Should be stable. |
| **Registered Service Instances Over Time** | Time series | All service instances vs billable service instances over time. | Useful for showing how the mesh grows as services are deployed. In this demo, shows all six fake-service instances appearing after `task k8s:up`. |

**What to watch for:**

```
Autopilot Healthy = 0       → Consul cluster is degraded. Check server logs.
Raft applied_index stalls   → Leader cannot commit. Check network or disk.
Goroutines growing linearly → Goroutine leak. Restart the server pod.
Members drops by 1          → A node left gossip. Was a pod restarted?
```

---

### 3. Service-to-Service Traffic (`service-to-service.json`)

**UID:** `service-to-service` · **Datasources:** Prometheus + Jaeger

**Why it matters:** This is the primary demo dashboard. It gives a helicopter view of the entire fake-service topology — traffic entering the mesh, how it flows between services, the distributed trace for any individual request, and a live topology graph. It answers *"how is traffic flowing through the mesh right now?"* without needing to look at individual services.

#### Top-row Stats (whole-mesh aggregates)

| Panel | Type | What it shows |
|-------|------|---------------|
| **Request Rate (RPS)** | Stat | Total upstream requests per second across all services. The load generator drives ~0.5 RPS baseline. |
| **Error Rate (%)** | Stat | Percentage of all upstream requests returning 5xx. Should be 0% at baseline. |
| **P99 Latency (ms)** | Stat | 99th-percentile response time across all upstream calls. Shows tail latency. |
| **Active Connections** | Stat | Total open upstream connections across all service sidecars. |

These four stats implement the [Google SRE Golden Signals](https://sre.google/sre-book/monitoring-distributed-systems/) at the mesh level.

#### Time Series Panels

| Panel | What it shows | Why it matters |
|-------|---------------|----------------|
| **Request Rate by Status Class** | RPS split by 2xx / 4xx / 5xx response class. | Lets you see if errors are client-side (4xx) vs server-side (5xx). During fault injection, watch the 5xx line rise. |
| **Response Time (P50 / P95 / P99)** | Three latency percentiles over time. | P50 is median (most requests). P99 is the worst 1%. The gap between P50 and P99 reveals tail latency variance — a large gap means a small number of requests are very slow. |

#### Distributed Traces — Service Call Chain

**Type:** Traces panel · **Datasource:** Jaeger

Shows recent traces from Jaeger for the entire mesh. Each row is one end-to-end request from the load generator through the full chain: `load generator → API Gateway → web → api → [payments → currency → rates, cache]`.

**Why it matters:** Metrics tell you *something is slow*. Traces tell you *exactly which hop is slow* and for *which specific request*. Click any trace row to open a waterfall view showing every span, its duration, and its relationship to parent spans. This is how you pinpoint bottlenecks to the exact service and operation.

**What a healthy trace looks like:**
```
web (20ms total)
  └── api (18ms)
        ├── payments (12ms)
        │     └── currency (8ms)
        │           └── rates [via TGW] (5ms)
        └── cache (3ms)
```

**During latency injection** (e.g. `kubectl set env deployment/payments TIMING_99_PERCENTILE=500ms`): the `payments` span grows to 500ms and the entire trace duration reflects it.

#### Service Dependency Map

**Type:** Node graph · **Datasource:** Prometheus (servicegraph metrics)

A live topology graph showing which services call which other services, with request rate on the edges. Nodes are services; edges are call relationships derived from distributed traces.

**Why it matters:** This is the demo's headline visual. It shows the mesh topology *as traffic actually flows*, not as it was configured. You can see:
- The full call chain (`web → api → payments → currency → rates`)
- The cache branch (`api → cache`)
- Real-time request rates on every edge

**How it works technically:** The OTel Collector's `servicegraph` connector reads incoming Zipkin spans from Envoy, matches client and server spans for the same request, and emits `traces_service_graph_request_total{client="web", server="api"}` counters to Prometheus. Both the node query (unique services) and the edge query (call pairs) come from this single metric, so the graph appears as soon as traces flow — typically within 60 seconds of startup.

```promql
-- Nodes: unique services that receive traffic
sum by (node_id) (
  label_replace(
    rate(traces_service_graph_request_total{server!=""}[5m]),
    "node_id", "$1", "server", "(.+)"
  )
)

-- Edges: service-to-service call rates
sum by (client, server) (
  rate(traces_service_graph_request_total{client!="",server!=""}[5m])
)
```

**If the graph shows no data:** check that Envoy traces are reaching the OTel Collector:
```bash
kubectl port-forward svc/otel-collector 8889:8889 -n observability &
curl -s http://localhost:8889/metrics | grep traces_service_graph_request_total
```

---

### 4. Envoy Access Logs (`logs.json`)

**UID:** `envoy-logs-k8s` · **Datasource:** Loki

**Why it matters:** Metrics aggregate — they tell you *that* 5% of requests failed. Access logs tell you *which specific requests* failed, to which path, from which pod, at what time. This is the raw signal underneath the metrics, and it is the only place where you can see individual request details: exact URL, response code, upstream host, request ID, and latency for every single HTTP transaction.

In Kubernetes, every Consul-injected pod has a `consul-dataplane` sidecar that runs Envoy. Envoy writes one structured JSON log line per HTTP request to stdout, which Promtail picks up and ships to Loki with labels `service_name=envoy-sidecar` and `log_source=access-log`.

#### Log Format

Each log line is a JSON object with these fields (configured in `proxy-defaults.yaml`):

| Field | Description | Example |
|-------|-------------|---------|
| `start_time` | Request start (ISO 8601) | `2026-02-27T06:04:45.016Z` |
| `method` | HTTP method | `GET` |
| `path` | Request path | `/` |
| `protocol` | HTTP protocol version | `HTTP/1.1` |
| `http_status_code` | Response code | `200` |
| `response_flags` | Envoy condition flags | `-` (normal), `UH` (no healthy upstream) |
| `duration` | Total request time (ms) | `18` |
| `bytes_sent` | Response body size (bytes) | `2885` |
| `upstream_cluster` | Envoy cluster that handled it | `api.default.dc1.internal...consul` |
| `upstream_host` | Specific pod IP:port | `10.244.0.25:20000` |
| `authority` | HTTP `Host` / `:authority` header | `api:9090` |
| `request_id` | Unique per-request ID | `23fd21d6-c70f-...` |

#### Panels

| Panel | Type | What it shows | Why it matters |
|-------|------|---------------|----------------|
| **Total Requests (5m rate)** | Stat | Count of all Envoy access log lines in the past 5 minutes across all sidecar pods. | Sanity check — confirms Promtail is collecting logs and traffic is flowing. Should match the load generator cadence. |
| **5xx Errors (5m rate)** | Stat | Count of log lines where `response_code >= 500` in the past 5 minutes. | Absolute count of errors, not just a percentage. During fault injection this number climbs. |
| **Request Rate by Service** | Time series | Log line rate per second per application (`app` label). | Shows which services are handling the most traffic, broken out by pod label. Spikes indicate load shifts. |
| **Error Rate by Service** | Time series | Rate of 5xx log lines per second per application. | Shows *which service's sidecar* is logging errors — whether it's an inbound error (service returned 5xx) or an outbound error (upstream returned 5xx). |
| **Live Log Stream** | Logs | Raw JSON access log lines from all `consul-dataplane` containers in the `default` namespace. | The most direct view: you can read individual requests, filter by path or status code, and see them stream in real time. |

#### Useful LogQL queries

```logql
-- All access logs across all sidecars
{namespace="default", container="consul-dataplane"}

-- Only 5xx errors, parsed as JSON
{namespace="default", container="consul-dataplane"}
  | json
  | response_code >= 500

-- Slow requests (> 200ms)
{namespace="default", container="consul-dataplane"}
  | json
  | duration > 200

-- Traffic to a specific upstream
{namespace="default", container="consul-dataplane"}
  | json
  | upstream_cluster =~ ".*payments.*"

-- Errors from a specific service's sidecar
{namespace="default", container="consul-dataplane", app="api"}
  | json
  | response_code >= 500
```

**Pipeline from Envoy to Grafana:**

```
Envoy (in consul-dataplane container)
  writes JSON to stdout
    → Promtail DaemonSet reads /var/log/pods/default_*_*/consul-dataplane/*.log
      → adds labels: service_name=envoy-sidecar, log_source=access-log, namespace, pod, app
        → pushes to Loki
          → Grafana queries Loki with LogQL
```

> **Promtail requirement:** The DaemonSet must have `HOSTNAME` set from `spec.nodeName` via the downward API. Without it, Promtail's Kubernetes SD uses the pod name as a node filter and discovers zero targets. See [Troubleshooting](#troubleshooting).

---

### 5. Consul Gateways (`gateways.json`)

**UID:** `consul-gateways` · **Datasource:** Prometheus

**Why it matters:** Gateways are the entry and exit points of the mesh and are the most likely place for configuration problems to appear. This dashboard monitors both gateways independently:

- **API Gateway** — the north-south entry point where external clients enter the mesh. If this is slow or erroring, *every user* is affected.
- **Terminating Gateway** — the mesh's controlled exit point to external services. If this is unhealthy, the `currency → rates` path breaks, cascading into `payments → currency` failures.

The dashboard queries support both Docker (using `job` label) and Kubernetes (using `service` label) environments automatically by including both label selectors.

#### Row: API Gateway (north-south entry point)

| Panel | Type | What it shows | Why it matters |
|-------|------|---------------|----------------|
| **Request Rate** | Stat | Requests per second entering the mesh through the API Gateway's HTTP downstream listener. | The total inbound load. The load generator drives a steady baseline; spikes indicate external traffic bursts or test runs. |
| **Error Rate (5xx)** | Stat | Percentage of requests through the API Gateway returning 5xx. | An error here affects all users. A non-zero value means either the gateway itself is misconfigured or all downstream services are failing. |
| **P99 Latency** | Stat | 99th-percentile latency at the API Gateway downstream listener (ms). | The worst-case experience for users. Includes the full round-trip: gateway → web → api → all upstreams → back. |
| **Rate Limited (last 5m)** | Stat | Requests dropped by the API Gateway's local rate limiter (configured at 100 req/s fill, burst 200). | The only place in the stack where rate limiting is applied. Non-zero means external clients hit the limit. Useful during the load-test demo step to show the rate limiter activating. |
| **Request Rate by Status Class** | Time series | API Gateway requests split by 2xx / 4xx / 5xx over time. | Lets you distinguish between client errors (4xx, e.g. bad requests or auth failures) and server errors (5xx, e.g. backend failures or gateway misrouting). |
| **Latency Percentiles** | Time series | P50 / P95 / P99 over time at the API Gateway. | Shows how latency evolves. The P99 line is most sensitive to upstream problems — a single slow backend will push the P99 up while the P50 stays flat. |

**Metrics source:** The API Gateway Envoy pod exposes HTTP downstream metrics (traffic *entering* Envoy from outside the mesh) rather than upstream cluster metrics. This is different from sidecar metrics which track outbound calls.

```promql
-- API Gateway inbound RPS (Kubernetes)
sum(rate(envoy_http_downstream_rq_total{service="api-gateway"}[1m]))

-- API Gateway P99 latency (Kubernetes)
histogram_quantile(0.99,
  sum(rate(envoy_http_downstream_rq_time_bucket{service="api-gateway"}[1m])) by (le)
)
```

#### Row: Terminating Gateway (mesh-to-external)

| Panel | Type | What it shows | Why it matters |
|-------|------|---------------|----------------|
| **External RPS** | Stat | Requests per second from the Terminating Gateway to the external `rates` service. | Confirms the `currency → rates` path is active. Should match the `currency` service's upstream call rate. Zero means the path is broken. |
| **External Error Rate** | Stat | Percentage of calls from TGW to `rates` returning 5xx. | Errors here propagate up to `currency → payments → api → web`. This is where you inject faults on `rates` to demonstrate the Terminating Gateway error path. |
| **External P99 Latency** | Stat | 99th-percentile upstream latency from TGW to `rates` (ms). | Latency on the external call. Since `rates` is not inside the mesh (no sidecar), this is the raw TCP round-trip to the `rates` pod plus its processing time. |
| **Active Connections** | Stat | Open connections from the Terminating Gateway to `rates`. | Should be a small stable number. A connection count of zero with non-zero RPS would indicate connections are being rapidly opened and closed (misconfiguration or network issue). |
| **External Service Calls (currency → TGW → rates)** | Time series | Combined view: RPS, 5xx rate, and P99 latency for the TGW → rates path over time. | The full picture of the external call path in one panel. During the gateway load-test demo step, all three lines move together. |

**Why the Terminating Gateway matters for demos:** It demonstrates that the Consul service mesh can manage traffic to services that cannot be modified (legacy systems, third-party APIs). The `rates` service has no sidecar and no mTLS — traffic to it exits the mesh at the TGW boundary. This panel shows that Consul can observe and control even that last mile.

**Fault injection on the external path:**
```bash
# Inject 30% errors on the external rates service
kubectl set env deployment/rates ERROR_RATE=0.3 -n default

# Watch "External Error Rate" panel climb to ~30%
# Watch "Services with High Error Rate" in Service Health also rise
# (for currency → rates and payments → currency due to cascade)

# Restore
kubectl set env deployment/rates ERROR_RATE=0 -n default
```

---

### Dashboard Quick Reference

| Dashboard | Open when you need to… | Primary datasource |
|-----------|------------------------|-------------------|
| **Service Health** | Find which service is failing right now | Prometheus |
| **Consul Service Health** | Check if Consul itself is healthy | Prometheus |
| **Service-to-Service Traffic** | See overall mesh traffic + traces + topology map | Prometheus + Jaeger |
| **Envoy Access Logs** | Read individual request logs, debug specific failures | Loki |
| **Consul Gateways** | Monitor the API Gateway entry point or Terminating Gateway external path | Prometheus |

### Accessing Dashboards

**Kubernetes (after `task k8s:up`):**

```bash
kubectl port-forward svc/grafana 3000:3000 -n observability &
open http://localhost:3000   # admin / admin
# → Dashboards → Consul Observability → pick a dashboard
```

**Docker Compose (after `task docker:up`):**

```bash
open http://localhost:3000   # admin / admin, no port-forward needed
```

---

## Troubleshooting

### Prometheus targets show DOWN with `strconv.ParseFloat` error

**Cause:** `connectInject.metrics.defaultEnableMerging: true` in the deployed Helm values. consul-dataplane attempts to merge application metrics with Envoy stats, but the application does not expose `/metrics`, so error text is injected into the Prometheus output.

**Fix:**

```bash
# Verify current deployed value
helm get values consul -n consul | grep -A5 "metrics:"

# If defaultEnableMerging is true, upgrade
helm upgrade consul hashicorp/consul -n consul -f kubernetes/consul/values.yaml

# Restart pods to pick up new sidecar injection config
kubectl rollout restart deployment -n default
```

### Envoy tracing: all `random_sampling` counters at 0

**Cause:** Consul 1.22.x bug — HCM tracing block contains `random_sampling: {}` (empty proto = 0%).

**Verify:**

```bash
CONSUL_TOKEN=$(kubectl get secret consul-bootstrap-acl-token -n consul \
  -o jsonpath='{.data.token}' | base64 -d)

kubectl port-forward -n default deployment/nginx 19001:19000 &
sleep 2

# Stats check
curl -s http://localhost:19001/stats | grep tracing
# tracing.not_traceable: <high number>  → 0% sampling confirmed
```

**Workaround:** Add OTLP instrumentation directly to application services. Set `OTEL_EXPORTER_OTLP_ENDPOINT` to the OTel Collector service. This bypasses Envoy-level tracing entirely.

### Loki: Promtail reports "Unable to find any logs to tail"

**Cause:** The `__path__` relabeling in Promtail config does not correctly construct the pod log file path.

**Verify from inside the Promtail pod:**

```bash
PROMTAIL_POD=$(kubectl get pods -n observability -l app=promtail \
  -o jsonpath='{.items[0].metadata.name}')

# Check if log files exist at the expected path
kubectl exec -n observability $PROMTAIL_POD -- \
  sh -c "ls /var/log/pods/default_nginx-*/"
```

**Correct `__path__` relabeling** (uses all 4 metadata labels for explicit path construction):

```yaml
- source_labels:
    - __meta_kubernetes_namespace
    - __meta_kubernetes_pod_name
    - __meta_kubernetes_pod_uid
    - __meta_kubernetes_pod_container_name
  target_label: __path__
  separator: _
  regex: '(.+)_(.+)_(.+)_(.+)'
  replacement: /var/log/pods/${1}_${2}_${3}/${4}/*.log
```

### OTel Collector crashes with `invalid keys: attributes_as_labels`

**Cause:** `attributes_as_labels` is not a valid field in the Loki exporter for otelcol-contrib v0.103.0. The correct mechanism is the `loki.resource.labels` hint attribute.

**Fix:** Remove `attributes_as_labels` from the Loki exporter and add the `resource/loki_labels` processor (see [Loki Label Strategy](#loki-label-strategy)).

### Grafana Jaeger panel: "Failed to upgrade legacy queries"

**Cause:** The `traces` panel type in Grafana uses a different query schema depending on the Grafana version. In Grafana 11.x the Jaeger datasource `queryType: "search"` format changed.

**Fix:** Open the dashboard in edit mode, click on the affected traces panel, open the query editor, and re-save the query. Grafana will migrate the query format in place.

### No traces in Jaeger after generating traffic

**Checklist:**

```bash
# 1. Is the otel_zipkin cluster in Envoy's config?
curl -s http://localhost:19001/clusters | grep otel_zipkin

# 2. Is the cluster healthy?
curl -s http://localhost:19001/clusters | grep "otel_zipkin.*cx_active"

# 3. Are spans being flushed?
curl -s http://localhost:19001/stats | grep "tracing.zipkin.timer_flushed"

# 4. Are spans being sent (vs dropped)?
curl -s http://localhost:19001/stats | grep "tracing.zipkin.spans_sent"

# 5. Is OTel receiving them?
kubectl port-forward -n observability deployment/otel-collector 8888:8888
curl -s http://localhost:8888/metrics | grep "receiver_accepted_spans.*zipkin"

# 6. Is OTel forwarding to Jaeger?
curl -s http://localhost:8888/metrics | grep "exporter_sent_spans.*jaeger"
```
