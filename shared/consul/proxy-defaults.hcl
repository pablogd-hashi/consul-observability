# proxy-defaults.hcl
# Global proxy defaults for Docker/VM environments.
# Apply with: consul config write proxy-defaults.hcl
#
# For Kubernetes/OpenShift, see:
#   kubernetes/consul/config-entries/proxy-defaults.yaml
#
# This sets global Envoy behaviour for all services in the mesh:
#   - Prometheus metrics on :20200
#   - Zipkin-compatible tracing → OTel Collector → Jaeger
#   - JSON access logs to file (picked up by OTel filelog receiver)

Kind = "proxy-defaults"
Name = "global"

Config {
  # Expose Envoy Prometheus metrics endpoint on all sidecars
  envoy_prometheus_bind_addr = "0.0.0.0:20200"

  # Zipkin tracer — sends spans to OTel Collector which forwards to Jaeger.
  # shared_span_context = true ensures W3C traceparent headers propagate.
  envoy_tracing_json = <<EOF
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
EOF

  # Static cluster pointing to the OTel Collector's Zipkin receiver.
  # Must be STRICT_DNS so Envoy resolves the hostname at runtime.
  envoy_extra_static_clusters_json = <<EOF
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
              "address": "otel-collector",
              "port_value": 9411
            }
          }
        }
      }]
    }]
  }
}
EOF
}
