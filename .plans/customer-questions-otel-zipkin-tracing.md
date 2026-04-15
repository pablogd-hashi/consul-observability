# Customer Questions: OTEL Collector, Zipkin, and Envoy Tracing

## Context
Customer is deploying on OpenShift (OCP) with concerns about scaling the OTEL collector across many namespaces and applications. They want to understand the current Zipkin setup, OTLP support, and Envoy-level trace enrichment capabilities.

---

## Question 1: OTEL Collector Deployment Pattern Recommendations

### Current Setup Analysis
Based on the repository configuration:

**Kubernetes/OpenShift Deployment:**
- Single OTEL Collector deployment in `observability` namespace
- Configured as a `Deployment` with `replicas: 1`
- Receives telemetry from all namespaces via cluster-wide service endpoints
- Resource limits: 500m CPU, 512Mi memory

**Concerns with Current Pattern:**
- Single point of failure
- Limited horizontal scalability
- All telemetry flows through one namespace
- Potential bottleneck as applications scale

### Recommended Deployment Patterns for Scale

#### Option 1: DaemonSet Pattern (Recommended for Most Cases)
Deploy OTEL Collector as a DaemonSet on each node:

**Advantages:**
- Automatic scaling with cluster nodes
- Reduced network hops (local collection)
- Better resource distribution
- No single point of failure
- Lower latency for telemetry ingestion

**Configuration:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: otel-collector
  namespace: observability
spec:
  selector:
    matchLabels:
      app: otel-collector
  template:
    spec:
      hostNetwork: true  # Optional: for better performance
      containers:
      - name: otel-collector
        resources:
          requests:
            cpu: "200m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
```

**Service Configuration:**
```yaml
# Headless service for DaemonSet
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: observability
spec:
  clusterIP: None  # Headless
  selector:
    app: otel-collector
  ports:
  - name: otlp-grpc
    port: 4317
  - name: otlp-http
    port: 4318
  - name: zipkin
    port: 9411
```

**Application Configuration:**
Applications should use the node-local collector via hostPort or NodePort:
```yaml
env:
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://$(HOST_IP):4318"  # Use downward API for HOST_IP
- name: TRACING_ZIPKIN
  value: "http://$(HOST_IP):9411"
```

#### Option 2: Gateway + Sidecar Pattern (For High-Volume Environments)
Two-tier architecture:

**Tier 1: Sidecar Collectors** (per namespace or per application)
- Lightweight collectors deployed alongside applications
- Handle initial processing (batching, basic filtering)
- Forward to gateway collectors

**Tier 2: Gateway Collectors** (centralized)
- Heavier processing (enrichment, sampling, routing)
- Export to backends (Jaeger, Prometheus, Loki)
- Horizontal scaling with load balancing

**Example Sidecar Config:**
```yaml
# Per-namespace collector
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector-sidecar
  namespace: app-namespace
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: otel-collector
        args: ["--config=/etc/otel/sidecar-config.yml"]
        # Minimal processing, forward to gateway
```

**Gateway Config:**
```yaml
# Central gateway in observability namespace
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector-gateway
  namespace: observability
spec:
  replicas: 3  # Scale based on load
  template:
    spec:
      containers:
      - name: otel-collector
        args: ["--config=/etc/otel/gateway-config.yml"]
```

#### Option 3: Per-Namespace Collectors (For Multi-Tenancy)
Deploy one collector per application namespace:

**Advantages:**
- Namespace isolation
- Independent scaling per tenant
- Easier RBAC and resource quotas
- Fault isolation

**Disadvantages:**
- Higher resource overhead
- More complex management
- Duplicate configuration

**When to Use:**
- Strict multi-tenancy requirements
- Different telemetry backends per namespace
- Compliance/regulatory isolation needs

### Operational Recommendations

1. **Start with DaemonSet** for most OCP deployments
2. **Monitor collector metrics** (`otelcol_receiver_refused_*`, `otelcol_exporter_send_failed_*`)
3. **Set memory limits** with `memory_limiter` processor to prevent OOM
4. **Use batch processor** to reduce backend load
5. **Enable auto-scaling** for gateway pattern (HPA based on CPU/memory)
6. **Implement health checks** and readiness probes
7. **Use persistent queues** for critical telemetry (exporters with `sending_queue`)

### Resource Sizing Guidelines

**Per-Node Collector (DaemonSet):**
- Small clusters (<50 pods/node): 200m CPU, 256Mi memory
- Medium clusters (50-100 pods/node): 500m CPU, 512Mi memory
- Large clusters (>100 pods/node): 1000m CPU, 1Gi memory

**Gateway Collector:**
- Start with 3 replicas
- 1000m CPU, 1Gi memory per replica
- Scale horizontally based on `otelcol_receiver_accepted_spans` rate

---

## Question 2: Zipkin vs OTLP Support

### Current Configuration Analysis

**OTLP is ALREADY FULLY SUPPORTED** in this repository:

#### OTLP Receivers Configured
From `docker/otel/otel-collector.yml` and `kubernetes/observability/otel-collector.yaml`:

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"
  zipkin:
    endpoint: "0.0.0.0:9411"
```

**Both protocols are active simultaneously.**

#### Current Usage Pattern
Applications in this demo use **Zipkin** format:
```yaml
env:
- name: TRACING_ZIPKIN
  value: "http://otel-collector.observability.svc.cluster.local:9411"
```

### Why Zipkin is Currently Used

From `docs/observability.md`:
> **Why not use Envoy-level tracing?** Consul CE does not expose a tracing sampling rate configuration knob. Envoy's default is `random_sampling={} = 0%`, which injects `x-b3-sampled: 0` into every request header, causing B3-aware applications to suppress trace reporting entirely.

The demo uses **application-level tracing** with Zipkin format to avoid Envoy sampling issues.

### Migrating to OTLP

**OTLP is the recommended standard** for OpenTelemetry. Here's how to migrate:

#### Step 1: Update Application Configuration

**For applications using OTEL SDKs:**
```yaml
env:
# Remove Zipkin config
# - name: TRACING_ZIPKIN
#   value: "http://otel-collector:9411"

# Add OTLP config
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector.observability.svc.cluster.local:4318"
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: "http/protobuf"  # or "grpc" for port 4317
- name: OTEL_SERVICE_NAME
  value: "my-service"
- name: OTEL_RESOURCE_ATTRIBUTES
  value: "deployment.environment=production,service.namespace=default"
```

**For gRPC (preferred for performance):**
```yaml
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector.observability.svc.cluster.local:4317"
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: "grpc"
```

#### Step 2: Update OTEL Collector Pipeline

The collector already has OTLP pipelines configured:

```yaml
service:
  pipelines:
    traces/app:
      receivers: [otlp]  # ✓ Already configured
      processors: [memory_limiter, k8sattributes, attributes/mesh, batch]
      exporters: [otlp/jaeger, servicegraph]
```

**No changes needed** - the pipeline is ready.

#### Step 3: Verify OTLP Ingestion

```bash
# Check OTLP receiver metrics
kubectl port-forward -n observability svc/otel-collector 8888:8888
curl -s http://localhost:8888/metrics | grep otelcol_receiver_accepted_spans

# Should show:
# otelcol_receiver_accepted_spans{receiver="otlp",transport="grpc"} 1234
```

### OTLP vs Zipkin Comparison

| Aspect | Zipkin | OTLP |
|--------|--------|------|
| **Protocol** | HTTP JSON | gRPC (binary) or HTTP protobuf |
| **Performance** | Moderate | High (gRPC is more efficient) |
| **Span Model** | Shared span IDs (CLIENT/SERVER same ID) | Separate span IDs per span |
| **Context Propagation** | B3 headers (`x-b3-traceid`) | W3C Trace Context (`traceparent`) |
| **Ecosystem** | Legacy, Zipkin-specific | OpenTelemetry standard |
| **Metadata** | Limited | Rich (resource attributes, span events) |
| **Sampling** | B3 sampled flag | OTLP sampling decisions |
| **Future Support** | Maintenance mode | Active development |

### Recommendation

**Migrate to OTLP for new applications:**
1. OTLP is the OpenTelemetry standard
2. Better performance with gRPC
3. Richer metadata support
4. Future-proof

**Keep Zipkin support for:**
1. Legacy applications that can't be modified
2. Third-party services using Zipkin
3. Gradual migration period

**Both can coexist** - the OTEL Collector handles both simultaneously.

---

## Question 3: Envoy-Level Trace Enrichment

### Current Envoy Tracing Status

**Envoy-level tracing is INTENTIONALLY DISABLED** in the Kubernetes configuration.

From `kubernetes/consul/config-entries/proxy-defaults.yaml`:
```yaml
# ── Envoy tracing — INTENTIONALLY DISABLED ──────────────────────────
# Consul CE does not expose a tracing sampling-rate knob, so Envoy's
# HCM defaults to random_sampling={} → 0 %.  That injects the header
# x-b3-sampled: 0 into every request, which causes fake-service (and
# any B3-aware app) to suppress trace reporting entirely.
```

### Enabling Envoy-Level Tracing with Custom Attributes

To enable Envoy tracing with custom attributes, you need to configure three components:

#### 1. Enable Envoy Tracing in ProxyDefaults

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ProxyDefaults
metadata:
  name: global
  namespace: consul
spec:
  config:
    # Enable OTLP tracing
    envoy_tracing_json: |
      {
        "http": {
          "name": "envoy.tracers.opentelemetry",
          "typedConfig": {
            "@type": "type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig",
            "grpc_service": {
              "envoy_grpc": {
                "cluster_name": "opentelemetry-collector"
              }
            },
            "service_name": "envoy-proxy"
          }
        }
      }
    
    # Set sampling rate (CRITICAL - without this, sampling = 0%)
    envoy_listener_tracing_json: |
      {
        "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager.Tracing",
        "random_sampling": {
          "value": 100
        },
        "spawn_upstream_span": true
      }
    
    # Add static cluster for OTEL Collector
    envoy_extra_static_clusters_json: |
      {
        "name": "opentelemetry-collector",
        "type": "STRICT_DNS",
        "connect_timeout": "1s",
        "http2_protocol_options": {},
        "load_assignment": {
          "cluster_name": "opentelemetry-collector",
          "endpoints": [{
            "lb_endpoints": [{
              "endpoint": {
                "address": {
                  "socket_address": {
                    "address": "otel-collector.observability.svc.cluster.local",
                    "port_value": 4317
                  }
                }
              }
            }]
          }]
        }
      }
```

#### 2. Enrich Spans with Custom Attributes

**Option A: Using Envoy Bootstrap Config (Limited)**

Envoy's native tracing config has limited support for custom tags. You can add:
- Request headers as span tags
- Environment variables
- Metadata from the node

**Example with custom tags:**
```yaml
envoy_tracing_json: |
  {
    "http": {
      "name": "envoy.tracers.opentelemetry",
      "typedConfig": {
        "@type": "type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig",
        "grpc_service": {
          "envoy_grpc": {
            "cluster_name": "opentelemetry-collector"
          }
        },
        "service_name": "%ENVIRONMENT%.envoy-proxy"
      }
    }
  }
```

**Envoy supports these dynamic values:**
- `%ENVIRONMENT%` - from `--service-cluster` flag
- `%REQ(header-name)%` - from request headers
- Node metadata (limited)

**Limitation:** You CANNOT directly add arbitrary custom attributes like `namespace.name=%namespacevariable%` at the Envoy level.

#### 3. Enrich Spans in OTEL Collector (RECOMMENDED)

**This is the correct approach** for adding standardized attributes:

```yaml
processors:
  # Kubernetes attributes processor - adds namespace, pod, deployment
  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.deployment.name
        - k8s.node.name
      labels:
        - tag_name: app
          key: app
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip
      - sources:
          - from: connection

  # Add custom mesh-level attributes
  attributes/mesh:
    actions:
      - key: mesh
        value: consul
        action: insert
      - key: datacenter
        value: dc1
        action: insert
      - key: environment
        value: production
        action: insert
  
  # Add custom namespace attribute (example)
  attributes/namespace_enrichment:
    actions:
      - key: service.namespace
        from_attribute: k8s.namespace.name
        action: insert
      - key: service.instance.id
        value: "%{k8s.pod.name}"
        action: insert

  # Transform processor for complex logic
  transform/custom_attributes:
    trace_statements:
      - context: span
        statements:
          # Add custom attribute based on existing attributes
          - set(attributes["custom.namespace"], resource.attributes["k8s.namespace.name"])
          - set(attributes["custom.cluster"], "ocp-prod-01")
          - set(attributes["custom.region"], "us-east-1")
          
          # Conditional attributes
          - set(attributes["custom.tier"], "frontend") where resource.attributes["app"] == "web"
          - set(attributes["custom.tier"], "backend") where resource.attributes["app"] == "api"

service:
  pipelines:
    traces/proxy:
      receivers: [zipkin, otlp]
      processors: 
        - memory_limiter
        - k8sattributes              # ← Adds k8s metadata
        - attributes/mesh            # ← Adds mesh attributes
        - attributes/namespace_enrichment  # ← Custom namespace attributes
        - transform/custom_attributes      # ← Complex transformations
        - batch
      exporters: [otlp/jaeger]
```

### Standardized Attributes for All Apps

To ensure **all applications in the mesh have standardized attributes**, use the OTEL Collector processors:

**Attributes automatically added by `k8sattributes` processor:**
- `k8s.namespace.name` - Kubernetes namespace
- `k8s.pod.name` - Pod name
- `k8s.deployment.name` - Deployment name
- `k8s.node.name` - Node name
- `app` - From pod label
- `version` - From pod label

**Custom attributes via `attributes` processor:**
- `mesh` - Service mesh identifier
- `datacenter` - Consul datacenter
- `environment` - Environment (dev/staging/prod)
- `cluster` - Kubernetes cluster name
- `region` - Cloud region

**Example span after enrichment:**
```json
{
  "traceId": "4bf92f3577b34da6a3ce929d0e0e4736",
  "spanId": "00f067aa0ba902b7",
  "name": "GET /api/payments",
  "attributes": {
    "http.method": "GET",
    "http.url": "/api/payments",
    "http.status_code": 200,
    "k8s.namespace.name": "default",
    "k8s.pod.name": "payments-7d8f9c5b6-x4k2m",
    "k8s.deployment.name": "payments",
    "app": "payments",
    "mesh": "consul",
    "datacenter": "dc1",
    "environment": "production",
    "custom.cluster": "ocp-prod-01",
    "custom.region": "us-east-1",
    "custom.tier": "backend"
  }
}
```

### Answer to Question 3

**Yes, you can enrich Envoy-level traces**, but the **recommended approach is to enrich spans in the OTEL Collector**, not at the Envoy level:

1. **Envoy generates basic spans** (method, path, status, duration)
2. **OTEL Collector enriches spans** with Kubernetes metadata and custom attributes
3. **All applications get standardized attributes** automatically via collector processors
4. **No application code changes required**

This ensures:
- ✅ Consistent attributes across all services
- ✅ Centralized attribute management
- ✅ Works for both Envoy spans and application spans
- ✅ Easy to update attributes without redeploying apps

---

## Question 4: Envoy Span Creation and End-to-End Traces

### Current Trace Flow

**In this repository, Envoy does NOT create spans** because Envoy-level tracing is disabled.

**Current flow (application-level tracing):**
```
App A → App A's Envoy → App B's Envoy → App B
  │                                        │
  └─ App A creates CLIENT span            └─ App B creates SERVER span
     (via TRACING_ZIPKIN)                    (via TRACING_ZIPKIN)
```

**Trace structure:**
```
Trace ID: abc123
├── web (CLIENT span from web app)
│   └── api (SERVER span from api app)
│       ├── payments (SERVER span from payments app)
│       │   └── currency (SERVER span from currency app)
│       │       └── rates (SERVER span from rates app)
│       └── cache (SERVER span from cache app)
```

**Envoy proxies are invisible** in the trace - they forward traffic but don't create spans.

### With Envoy-Level Tracing Enabled

If you enable Envoy tracing (as shown in Question 3), **Envoy WILL create its own spans**:

**Flow with Envoy tracing:**
```
App A → Envoy A → Envoy B → App B
  │       │         │         │
  │       │         │         └─ App B creates span (if instrumented)
  │       │         └─ Envoy B creates ingress span
  │       └─ Envoy A creates egress span
  └─ App A creates span (if instrumented)
```

**Trace structure with Envoy spans:**
```
Trace ID: abc123
├── web app span (200ms)
│   └── web envoy egress span (180ms)
│       └── api envoy ingress span (170ms)
│           └── api app span (160ms)
│               ├── api envoy egress → payments (120ms)
│               │   └── payments envoy ingress span (110ms)
│               │       └── payments app span (100ms)
│               └── api envoy egress → cache (30ms)
│                   └── cache envoy ingress span (28ms)
│                       └── cache app span (25ms)
```

### Span Types Created by Envoy

When Envoy tracing is enabled with `spawn_upstream_span: true`:

1. **Downstream (Ingress) Span**
   - Created when Envoy receives a request
   - Represents time from receiving request to sending response
   - Includes mTLS handshake time
   - Parent: caller's egress span

2. **Upstream (Egress) Span**
   - Created when Envoy makes an outbound call
   - Represents time from sending request to receiving response
   - Includes connection establishment, retries
   - Parent: local app span or downstream span

### Example End-to-End Trace

**Request: Client → API Gateway → web → api → payments**

**With Envoy tracing enabled:**
```
Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736

├── api-gateway envoy ingress (300ms)
│   └── web envoy ingress (280ms)
│       └── web app span (270ms)
│           └── web envoy egress → api (250ms)
│               └── api envoy ingress (240ms)
│                   └── api app span (230ms)
│                       └── api envoy egress → payments (200ms)
│                           └── payments envoy ingress (190ms)
│                               └── payments app span (180ms)
```

**Each span shows:**
- Service name (web, api, payments)
- Span kind (CLIENT, SERVER, INTERNAL)
- Duration
- Attributes (http.method, http.status_code, etc.)
- Envoy-specific attributes (upstream_cluster, response_flags)

### Enabling End-to-End Traces with Envoy

To get **App A → Envoy A → Envoy B → App B** traces:

#### Step 1: Enable Envoy Tracing (ProxyDefaults)

```yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ProxyDefaults
metadata:
  name: global
  namespace: consul
spec:
  config:
    envoy_tracing_json: |
      {
        "http": {
          "name": "envoy.tracers.opentelemetry",
          "typedConfig": {
            "@type": "type.googleapis.com/envoy.config.trace.v3.OpenTelemetryConfig",
            "grpc_service": {
              "envoy_grpc": {
                "cluster_name": "opentelemetry-collector"
              }
            },
            "service_name": "envoy-proxy"
          }
        }
      }
    
    envoy_listener_tracing_json: |
      {
        "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager.Tracing",
        "random_sampling": {
          "value": 100
        },
        "spawn_upstream_span": true
      }
    
    envoy_extra_static_clusters_json: |
      {
        "name": "opentelemetry-collector",
        "type": "STRICT_DNS",
        "connect_timeout": "1s",
        "http2_protocol_options": {},
        "load_assignment": {
          "cluster_name": "opentelemetry-collector",
          "endpoints": [{
            "lb_endpoints": [{
              "endpoint": {
                "address": {
                  "socket_address": {
                    "address": "otel-collector.observability.svc.cluster.local",
                    "port_value": 4317
                  }
                }
              }
            }]
          }]
        }
      }
```

#### Step 2: Configure Applications for OTLP

```yaml
env:
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://otel-collector.observability.svc.cluster.local:4318"
- name: OTEL_SERVICE_NAME
  value: "my-service"
```

#### Step 3: Verify Trace Context Propagation

Envoy and applications must use compatible propagation formats:

**Envoy uses:** W3C Trace Context (`traceparent` header)
**Applications should use:** W3C Trace Context (OTLP default)

**OTEL SDK configuration:**
```yaml
env:
- name: OTEL_PROPAGATORS
  value: "tracecontext,baggage"  # W3C standard
```

### Answer to Question 4

**Yes, Envoy adds its own spans when tracing is enabled**, creating an end-to-end trace:

**Without Envoy tracing (current setup):**
- Trace: `App A → App B → App C`
- Only application spans visible
- Envoy is transparent

**With Envoy tracing enabled:**
- Trace: `App A → Envoy A → Envoy B → App B → Envoy B → Envoy C → App C`
- Both application and proxy spans visible
- Full visibility into proxy behavior (retries, circuit breaking, mTLS)

**Benefits of Envoy spans:**
1. ✅ See proxy-level latency (mTLS handshake, connection pooling)
2. ✅ Identify retry behavior in traces
3. ✅ Correlate circuit breaker events with specific requests
4. ✅ Debug routing issues (wrong upstream cluster)
5. ✅ Complete end-to-end visibility

**Trade-offs:**
- ❌ More spans = higher storage cost
- ❌ More complex traces (more spans to analyze)
- ❌ Requires careful sampling strategy

**Recommendation:**
- Enable Envoy tracing for **troubleshooting and deep visibility**
- Use **sampling** (10-20%) in production to control costs
- Keep application-level tracing for **business context**
- Use **both together** for complete observability

---

## Summary and Recommendations

### Question 1: OTEL Collector Deployment
**Recommendation:** Start with **DaemonSet pattern** for OCP deployments
- Automatic scaling with nodes
- Lower latency, better resource distribution
- Scale to gateway pattern if needed for high volume

### Question 2: OTLP Support
**Answer:** OTLP is **already fully supported** - both receivers are active
**Recommendation:** Migrate to OTLP for new applications
- Better performance (gRPC)
- OpenTelemetry standard
- Richer metadata support

### Question 3: Envoy Trace Enrichment
**Answer:** Yes, but enrich in **OTEL Collector, not Envoy**
**Recommendation:** Use `k8sattributes` + `attributes` + `transform` processors
- Centralized attribute management
- Standardized across all services
- No application changes required

### Question 4: Envoy Spans
**Answer:** Envoy creates spans when tracing is enabled
**Recommendation:** Enable Envoy tracing for complete visibility
- Configure `envoy_tracing_json` with OTLP exporter
- Set `random_sampling` to control sampling rate
- Use with application tracing for full end-to-end traces

---

## Next Steps

1. **Review current OTEL Collector deployment** - consider DaemonSet migration
2. **Test OTLP ingestion** - verify both gRPC and HTTP endpoints work
3. **Design attribute enrichment strategy** - define standard attributes for all services
4. **Plan Envoy tracing rollout** - start with low sampling rate (10%)
5. **Monitor collector performance** - set up alerts on `otelcol_receiver_refused_*` metrics
