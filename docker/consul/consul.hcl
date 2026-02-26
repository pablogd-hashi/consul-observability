datacenter = "dc1"
data_dir   = "/consul/data"
log_level  = "INFO"

# Single-server (dev-adjacent, but with persistence)
server           = true
bootstrap_expect = 1

# Bind to all interfaces so Docker networking works
bind_addr   = "0.0.0.0"
client_addr = "0.0.0.0"

# Enable the UI
ui_config {
  enabled = true
}

# Consul Connect (service mesh)
connect {
  enabled = true
}

# Prometheus telemetry
# 10m retention keeps stable gauges (serf_lan_members, catalog_registered_service_count,
# health_node_status, raft_leader_lastContact) alive between Prometheus scrapes.
# 60s was too short — gauges that don't change frequently would vanish from /metrics.
telemetry {
  prometheus_retention_time = "10m"
  disable_hostname          = true
}

# Allow non-TLS for this local dev stack
ports {
  http  = 8500
  grpc  = 8502
  dns   = 8600
}

# ── fake-service topology: web → api → [payments, cache] → currency → rates ──
# rates is an external service (no connect) fronted by the Terminating Gateway.

services {
  name = "web"
  id   = "web-1"
  port = 9090
  tags = ["v1", "frontend"]

  check {
    http     = "http://web:9090/"
    interval = "10s"
    timeout  = "3s"
  }

  connect {
    sidecar_service {}
  }
}

services {
  name = "api"
  id   = "api-1"
  port = 9090
  tags = ["v1", "backend"]

  check {
    http     = "http://api:9090/"
    interval = "10s"
    timeout  = "3s"
  }

  connect {
    sidecar_service {}
  }
}

services {
  name = "payments"
  id   = "payments-1"
  port = 9090
  tags = ["v1", "backend"]

  check {
    http     = "http://payments:9090/"
    interval = "10s"
    timeout  = "3s"
  }

  connect {
    sidecar_service {}
  }
}

services {
  name = "currency"
  id   = "currency-1"
  port = 9090
  tags = ["v1", "backend"]

  check {
    http     = "http://currency:9090/"
    interval = "10s"
    timeout  = "3s"
  }

  connect {
    sidecar_service {}
  }
}

services {
  name = "cache"
  id   = "cache-1"
  port = 9090
  tags = ["v1", "backend"]

  check {
    http     = "http://cache:9090/"
    interval = "10s"
    timeout  = "3s"
  }

  connect {
    sidecar_service {}
  }
}

# ── Gateways ──────────────────────────────────────────────────────────────────

# API Gateway: north-south entry point (external → web)
services {
  name = "api-gateway"
  id   = "api-gateway-1"
  port = 21001
  tags = ["gateway", "ingress", "api-gateway"]

  check {
    http     = "http://api-gateway:20201/ready"
    interval = "10s"
    timeout  = "3s"
  }
}

# Terminating Gateway: controlled mesh egress (currency → rates external)
services {
  name = "terminating-gateway"
  id   = "terminating-gateway-1"
  port = 9190
  tags = ["gateway", "terminating", "egress"]
}

# rates: external service (no consul connect — outside the mesh)
services {
  name = "rates"
  id   = "rates-1"
  port = 9090
  tags = ["v1", "external", "rates"]

  check {
    http     = "http://rates:9090/"
    interval = "10s"
    timeout  = "3s"
  }
}
