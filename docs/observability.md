# Observability Reference

Technical reference for metrics, logs, and distributed tracing in this Consul service mesh stack. Covers both the Docker Compose and Kubernetes deployments.

---

## Table of Contents

1. [Architecture](#architecture)
2. [Metrics](#metrics)
   - [Enabling Metrics](#enabling-metrics)
   - [Consul Server Metrics](#consul-server-metrics)
   - [Envoy Sidecar Metrics](#envoy-sidecar-metrics)
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

### Consul Server Metrics

Exposed at `/v1/agent/metrics?format=prometheus`. Consul prefixes all its metrics with `consul_`.

#### Raft / Cluster Health

| Metric | Type | Description |
|--------|------|-------------|
| `consul_raft_leader` | Gauge | 1 if this node is the Raft leader, 0 otherwise |
| `consul_raft_peers` | Gauge | Number of Raft peers (including leader) |
| `consul_raft_commitTime_sum` | Counter | Total time (ms) spent committing log entries |
| `consul_raft_commitTime_count` | Counter | Number of Raft log commits |
| `consul_raft_leader_lastContact_sum` | Counter | Milliseconds since leader last had contact with a follower |
| `consul_raft_state_leader` | Counter | Number of times this node became leader |
| `consul_raft_state_follower` | Counter | Number of times this node became a follower |
| `consul_raft_replication_appendEntries_rpc_sum` | Counter | Time for AppendEntries RPC calls |

**Key alerts:** `consul_raft_leader = 0` means no leader (split-brain or network partition). `consul_raft_leader_lastContact > 500ms` indicates replication lag.

#### Service Catalog

| Metric | Type | Description |
|--------|------|-------------|
| `consul_catalog_register` | Counter | Service registrations processed |
| `consul_catalog_deregister` | Counter | Service deregistrations processed |
| `consul_catalog_service_query` | Counter | Catalog service queries served |
| `consul_catalog_service_query_tag` | Counter | Tag-filtered catalog queries |
| `consul_health_service_query` | Counter | Health endpoint queries (used by sidecars for discovery) |
| `consul_health_service_not_found` | Counter | Queries for services that do not exist |

#### Membership / Gossip

| Metric | Type | Description |
|--------|------|-------------|
| `consul_members_clients` | Gauge | Number of client agents in the datacenter |
| `consul_members_servers` | Gauge | Number of server agents in the datacenter |
| `consul_serf_member_join` | Counter | Members joining the gossip pool |
| `consul_serf_member_leave` | Counter | Members leaving the gossip pool |
| `consul_serf_member_failed` | Counter | Members declared failed (no heartbeat) |
| `consul_serf_msgs_sent_sum` | Counter | Gossip messages transmitted |
| `consul_serf_queue_Intent_sum` | Gauge | Pending gossip intents queued — spikes indicate gossip backpressure |

#### ACL & RPC

| Metric | Type | Description |
|--------|------|-------------|
| `consul_acl_ResolveToken` | Summary | Time to resolve an ACL token (latency) |
| `consul_rpc_query` | Counter | RPC queries handled |
| `consul_rpc_request` | Counter | Total RPC requests |
| `consul_rpc_cross_dc_query` | Counter | Cross-datacenter RPC queries |

#### Go Runtime (present on all Consul nodes)

| Metric | Type | Description |
|--------|------|-------------|
| `consul_runtime_alloc_bytes` | Gauge | Bytes allocated and in use by Go heap |
| `consul_runtime_heap_objects` | Gauge | Objects on the Go heap |
| `consul_runtime_num_goroutines` | Gauge | Active goroutines — unexpected growth indicates goroutine leaks |
| `consul_runtime_total_gc_pause_ns` | Counter | Cumulative GC pause time in nanoseconds |

---

### Envoy Sidecar Metrics

Exposed at `:20200/stats/prometheus` on each sidecar. Consul connect injects labels `consul_source_service` and `consul_destination_service` onto cluster-level metrics, enabling cross-service queries. All Envoy metrics are prefixed with `envoy_`.

#### Labels on Envoy Metrics

Envoy exposes metrics with tag-extracted labels. Key labels for service mesh:

| Label | Source | Example |
|-------|--------|---------|
| `local_cluster` | The name of this service | `nginx` |
| `consul_source_service` | Source service (where traffic originates) | `nginx` |
| `consul_destination_service` | Destination service (upstream) | `frontend` |
| `consul_destination_service_subset` | Traffic subset | `v2` |
| `envoy_cluster_name` | Full Envoy cluster name | `frontend.default.dc1.internal...consul` |

**Cross-service queries** use `consul_source_service` and `consul_destination_service` because Envoy's cluster-level metrics are tagged with both the calling and the called service. Example: to see all traffic from `nginx` to `frontend`:

```promql
envoy_cluster_upstream_rq_total{
  consul_source_service="nginx",
  consul_destination_service="frontend"
}
```

#### Proxy / Server Health

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_server_live` | Gauge | 1 if Envoy is running and serving traffic |
| `envoy_server_uptime` | Gauge | Seconds since Envoy started |
| `envoy_server_state` | Gauge | 0=live, 1=draining, 2=pre-initializing, 3=initializing |
| `envoy_server_hot_restart_epoch` | Gauge | Hot restart generation (0 = never hot-restarted) |
| `envoy_server_total_connections` | Gauge | Total open connections (all listeners) |
| `envoy_server_parent_connections` | Gauge | Connections from the previous hot-restart epoch |
| `envoy_server_memory_allocated` | Gauge | Bytes allocated by Envoy process |
| `envoy_server_memory_heap_size` | Gauge | Total heap size in bytes |
| `envoy_server_concurrency` | Gauge | Number of worker threads |
| `envoy_server_version` | Gauge | Envoy version as a numeric value |

#### HTTP Downstream (inbound to this sidecar)

These metrics describe traffic arriving at the sidecar from the Consul mesh inbound listener.

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_http_downstream_rq_total` | Counter | Total HTTP/1.x requests received |
| `envoy_http_downstream_rq_http2_total` | Counter | HTTP/2 requests received |
| `envoy_http_downstream_rq_http3_total` | Counter | HTTP/3 requests received |
| `envoy_http_downstream_rq_active` | Gauge | Requests currently being processed |
| `envoy_http_downstream_rq_time_bucket` | Histogram | Downstream request latency |
| `envoy_http_downstream_cx_total` | Counter | Total downstream connections established |
| `envoy_http_downstream_cx_active` | Gauge | Active downstream connections |
| `envoy_http_downstream_rq_1xx` | Counter | 1xx responses |
| `envoy_http_downstream_rq_2xx` | Counter | 2xx responses |
| `envoy_http_downstream_rq_4xx` | Counter | 4xx responses (client errors) |
| `envoy_http_downstream_rq_5xx` | Counter | 5xx responses (server errors) |

#### Upstream Clusters (outbound from this sidecar)

These are the most important metrics for inter-service traffic. Each upstream in the service mesh has a cluster.

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_cluster_upstream_rq_total` | Counter | Total requests sent to the upstream |
| `envoy_cluster_upstream_rq_active` | Gauge | Requests currently in flight to the upstream |
| `envoy_cluster_upstream_rq_pending_active` | Gauge | Requests queued waiting for a connection |
| `envoy_cluster_upstream_rq_pending_overflow` | Counter | Requests dropped because the pending queue was full |
| `envoy_cluster_upstream_rq_time_bucket` | Histogram | Request latency to the upstream (use for P50/P95/P99) |
| `envoy_cluster_upstream_rq_time_sum` | Counter | Sum of upstream latency (ms) |
| `envoy_cluster_upstream_rq_time_count` | Counter | Count of timed upstream requests |
| `envoy_cluster_upstream_rq_xx` | Counter | Requests by response class (label `envoy_response_code_class`: 1,2,3,4,5) |
| `envoy_cluster_upstream_rq_timeout` | Counter | Requests that timed out waiting for the upstream |
| `envoy_cluster_upstream_rq_retry` | Counter | Requests that were retried |
| `envoy_cluster_upstream_rq_retry_success` | Counter | Retries that ultimately succeeded |
| `envoy_cluster_upstream_cx_total` | Counter | Total connections made to the upstream |
| `envoy_cluster_upstream_cx_active` | Gauge | Active connections to the upstream |
| `envoy_cluster_upstream_cx_connect_timeout` | Counter | Connection attempts that timed out |
| `envoy_cluster_upstream_cx_connect_fail` | Counter | Failed connection attempts |

**P99 latency between two services:**

```promql
histogram_quantile(0.99,
  sum(rate(envoy_cluster_upstream_rq_time_bucket{
    consul_source_service="nginx",
    consul_destination_service="frontend"
  }[$__rate_interval])) by (le)
)
```

**Error rate (5xx) for a specific upstream:**

```promql
sum(rate(envoy_cluster_upstream_rq_xx{
  consul_destination_service="payments",
  envoy_response_code_class="5"
}[$__rate_interval]))
/
sum(rate(envoy_cluster_upstream_rq_total{
  consul_destination_service="payments"
}[$__rate_interval]))
```

#### Listener (connection acceptance)

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_listener_downstream_cx_total` | Counter | Total connections accepted by all listeners |
| `envoy_listener_downstream_cx_active` | Gauge | Active connections across all listeners |
| `envoy_listener_downstream_cx_overflow` | Counter | Connections rejected because the connection limit was reached |
| `envoy_listener_downstream_cx_overload_reject` | Counter | Connections rejected by overload manager (memory/CPU pressure) |
| `envoy_listener_downstream_global_cx_overflow` | Counter | Connections rejected due to global connection limit |
| `envoy_listener_no_filter_chain_match` | Counter | Connections with no matching filter chain (misconfigured SNI or port) |

#### Health Checks

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_cluster_health_check_success` | Counter | Health checks that returned healthy |
| `envoy_cluster_health_check_failure` | Counter | Health checks that returned unhealthy |
| `envoy_cluster_health_check_network_failure` | Counter | Health checks that failed due to network errors |
| `envoy_cluster_membership_healthy` | Gauge | Number of healthy endpoints in this cluster |
| `envoy_cluster_membership_total` | Gauge | Total endpoints configured for this cluster |
| `envoy_cluster_membership_degraded` | Gauge | Endpoints degraded (partial health) |

#### Circuit Breaker & Outlier Detection

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_cluster_upstream_rq_pending_overflow` | Counter | Requests dropped due to pending queue overflow (circuit breaker trigger) |
| `envoy_cluster_upstream_rq_cancelled` | Counter | Requests cancelled before they could be sent |
| `envoy_cluster_outlier_detection_ejections_active` | Gauge | Endpoints currently ejected by outlier detection |
| `envoy_cluster_outlier_detection_ejections_total` | Counter | Total ejections by outlier detection |

#### Tracing

| Metric | Type | Description |
|--------|------|-------------|
| `envoy_tracing_zipkin_timer_flushed` | Counter | Number of span batches flushed to Zipkin collector |
| `envoy_tracing_zipkin_spans_sent` | Counter | Total spans sent to the Zipkin endpoint |
| `envoy_tracing_zipkin_reports_dropped` | Counter | Spans dropped due to queue overflow |
| `envoy_tracing_random_sampling` | Counter | Requests that were sampled for tracing (increments per sampled request) |
| `envoy_tracing_not_traceable` | Counter | Requests that could not be traced (missing trace ID, sampling = 0%) |

> **Debugging tracing:** If `envoy_tracing_not_traceable` is non-zero and `envoy_tracing_random_sampling` stays at 0, the HCM `random_sampling` percentage is 0%. See [Troubleshooting](#troubleshooting) for the Consul 1.22.x workaround.

---

### OTel Collector Self-Metrics

The collector exposes its own Prometheus metrics at `:8888/metrics`. These are critical for pipeline health monitoring.

| Metric | Type | Description |
|--------|------|-------------|
| `otelcol_receiver_accepted_spans_total` | Counter | Spans accepted into the pipeline by receiver |
| `otelcol_receiver_refused_spans_total` | Counter | Spans refused (parse error, capacity) |
| `otelcol_receiver_accepted_metric_points_total` | Counter | Metric datapoints accepted |
| `otelcol_receiver_accepted_log_records_total` | Counter | Log records accepted |
| `otelcol_exporter_sent_spans_total` | Counter | Spans successfully sent to the exporter backend |
| `otelcol_exporter_send_failed_spans_total` | Counter | Spans that failed to export (backend down, timeout) |
| `otelcol_exporter_sent_metric_points_total` | Counter | Metric points exported |
| `otelcol_exporter_sent_log_records_total` | Counter | Log records exported to Loki |
| `otelcol_processor_dropped_spans_total` | Counter | Spans dropped by processors (usually memory_limiter) |
| `otelcol_processor_refused_spans_total` | Counter | Spans refused by processors |
| `otelcol_process_memory_rss` | Gauge | Resident set size (physical RAM) of the collector process |
| `otelcol_process_cpu_seconds_total` | Counter | CPU time consumed by the collector |
| `otelcol_batch_send_size_bucket` | Histogram | Distribution of batch sizes sent to exporters |
| `otelcol_batch_timeout_trigger_send_total` | Counter | Batches sent because the timeout fired (not size limit) |

**Pipeline health check:**

```promql
# Check exporter failure rate
rate(otelcol_exporter_send_failed_spans_total[5m]) > 0

# Confirm spans are flowing end-to-end
rate(otelcol_exporter_sent_spans_total[5m])
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

All dashboards are provisioned automatically at startup from ConfigMaps / provisioning directories.

### Data Plane Health (`data-plane-health.json`)

**Datasource:** Prometheus

Key panels:
- **Running HashiCups services** (Gauge): `sum(envoy_server_live{app!="traffic-generator"})` — shows count of live Envoy sidecars. Thresholds: 5=warning, 6=ok.
- **Connections Rejected** (Time series): `rate(envoy_listener_downstream_cx_overload_reject[$__interval])` — non-zero values indicate CPU/memory overload causing connection drops.
- **P99 Upstream Latency** (Time series): `histogram_quantile(0.99, sum(rate(envoy_cluster_upstream_rq_time_bucket[$__rate_interval])) by (le, consul_destination_service))`.

### Golden Signals (`golden-signals.json`)

**Datasource:** Prometheus

Implements the Google SRE four golden signals:
- **Request Rate**: `sum(rate(envoy_cluster_upstream_rq_total[$__rate_interval])) by (consul_destination_service)`
- **Error Rate**: `sum(rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class="5"}[$__rate_interval])) by (consul_destination_service)`
- **Latency P50/P95/P99**: `histogram_quantile` over `envoy_cluster_upstream_rq_time_bucket`
- **Saturation**: `envoy_cluster_upstream_cx_active` (active connections as proxy for saturation)

### Service Mesh Topology (`service-mesh.json` / `service-topology.json`)

**Datasource:** Prometheus

Shows the full request graph across the service mesh:
- Per-service request rates, error rates, and latency
- Active upstream connections per service pair
- Uses `consul_source_service` and `consul_destination_service` labels

### Envoy Access Logs (`envoy-logs.json`)

**Datasource:** Loki

- Live log stream from all Envoy sidecars
- Filters for specific response codes, upstream clusters, or paths
- Trace correlation via `traceparent` derived field

### Consul Health (`consul-health.json`)

**Datasource:** Prometheus

- Raft leader status and commit time
- Goroutine count (leak detection)
- Memory allocation
- Gossip member count and failed members

### Service Traceability (`service-traceability.json`)

**Datasources:** Prometheus + Jaeger

- Source/destination service selector variables
- Request rate, error rate, P99 latency filtered by selected service pair
- Active connections
- Direct Jaeger trace panels for selected source and destination service
- Data links from all metric panels to Jaeger Explore

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
