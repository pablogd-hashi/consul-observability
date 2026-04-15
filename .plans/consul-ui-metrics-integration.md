# Consul UI Metrics Integration & Access URLs Plan

## Executive Summary

This plan addresses two key improvements to the Consul observability demo:

1. **Add Consul UI access URLs** to setup script outputs for Docker, Kubernetes, and OpenShift deployments
2. **Configure metrics integration** in Consul UI to enable direct links to Grafana dashboards and display Prometheus metrics

## Current State Analysis

### Docker/Podman Deployment
- **Consul UI Access:** `http://localhost:8500` (working)
- **Missing:** 
  - No metrics_proxy configuration
  - No dashboard_url_templates
  - URL not printed in script output

### Kubernetes Deployment
- **Consul UI Access:** Requires port-forward: `kubectl port-forward svc/consul-ui 8500:80 -n consul`
- **Current Config:** Basic metrics enabled in `values.yaml` but incomplete
- **Missing:**
  - metrics_proxy base_url not configured
  - No dashboard_url_templates
  - URL not printed in `kind-setup.sh` output

### OpenShift Deployment
- **Consul UI Access:** Via Route (HTTPS)
- **Missing:**
  - Same configuration gaps as Kubernetes
  - Route URL not printed in `openshift-setup.sh` output

## Requirements & Compatibility

### Version Compatibility
- **Consul Version:** 1.22.3 ✅ (well above 1.9.0 minimum for UI metrics)
- **Helm Chart:** Likely 0.40.0+ (supports native `ui.dashboardURLTemplates`)
- **Features Available:**
  - Built-in Prometheus provider
  - Dashboard URL templates with variable substitution
  - Metrics proxy for secure Prometheus access

### Template Variables Available
- `{{Service.Name}}` - Service name (all editions)
- `{{Service.Namespace}}` - Service namespace (Enterprise only, use "default" for OSS)
- `{{Service.Partition}}` - Service partition (Enterprise only)
- `{{Datacenter}}` - Datacenter name (all editions)

## Proposed Configuration Changes

### 1. Docker/Podman: `docker/consul/consul.hcl`

Add the following to the existing `ui_config` block:

```hcl
ui_config {
  enabled = true
  
  # Prometheus metrics integration
  metrics_provider = "prometheus"
  metrics_proxy {
    base_url = "http://prometheus:9090"
  }
  
  # Grafana dashboard deep links
  dashboard_url_templates {
    service = "http://localhost:3000/d/service-to-service?orgId=1&var-service={{Service.Name}}&var-dc={{Datacenter}}"
  }
}
```

**Rationale:**
- `prometheus:9090` uses Docker Compose service name (internal DNS)
- Dashboard URL uses `localhost:3000` since Grafana is exposed on host
- Uses existing "Service-to-Service Traffic" dashboard ID
- Only uses OSS-compatible variables (no Namespace/Partition)

### 2. Kubernetes: `kubernetes/consul/values.yaml`

Update the existing `ui` section:

```yaml
ui:
  enabled: true
  service:
    type: ClusterIP
  ingress:
    enabled: false
  
  # Prometheus metrics integration
  metrics:
    enabled: true
    provider: "prometheus"
    baseURL: http://prometheus.observability.svc.cluster.local:9090
  
  # Grafana dashboard deep links
  dashboardURLTemplates:
    service: "http://localhost:3000/d/service-to-service?orgId=1&var-service={{Service.Name}}&var-dc={{Datacenter}}"
```

**Rationale:**
- Uses Kubernetes service FQDN for Prometheus (cluster-internal)
- Dashboard URL uses `localhost:3000` (assumes port-forward for Grafana)
- Helm 0.40.0+ native syntax (no `server.extraConfig` needed)
- OSS-compatible variables only

**Alternative for External Grafana Access:**
If Grafana is exposed via Ingress/LoadBalancer, update the URL:
```yaml
dashboardURLTemplates:
  service: "https://grafana.example.com/d/service-to-service?orgId=1&var-service={{Service.Name}}&var-dc={{Datacenter}}"
```

### 3. OpenShift: `openshift/consul/values.yaml`

Add to the existing file (extends Kubernetes values):

```yaml
ui:
  # Grafana dashboard deep links (OpenShift Route URL)
  dashboardURLTemplates:
    service: "https://grafana-observability.apps-crc.testing/d/service-to-service?orgId=1&var-service={{Service.Name}}&var-dc={{Datacenter}}"
```

**Rationale:**
- Inherits `metrics.baseURL` from `kubernetes/consul/values.yaml`
- Uses OpenShift Route hostname pattern
- Route URL is dynamic (depends on cluster domain)
- Should be templated in setup script or documented as manual step

**Dynamic Route URL Approach:**
The `openshift-setup.sh` script should:
1. Deploy Grafana first
2. Get the Route URL: `oc get route grafana -n observability -o jsonpath='{.spec.host}'`
3. Update Helm values with actual Route URL before Consul installation

## Script Output Enhancements

### 4. Docker: `docker/README.md` & Script Output

Add to the "Endpoints" table:

```markdown
| Consul UI | http://localhost:8500 | Service health + topology + metrics |
```

Update `task docker:up` output to include:
```bash
echo "  Consul UI: http://localhost:8500"
echo "    - View service topology and health"
echo "    - Click any service → 'Metrics' tab to see Prometheus data"
echo "    - Click 'Dashboard' link to jump to Grafana service view"
```

### 5. Kubernetes: `scripts/kind-setup.sh` Output

Add to the final output section (after line 201):

```bash
echo "  Consul UI:"
echo "    kubectl port-forward svc/consul-ui 8500:80 -n consul &"
echo "    http://localhost:8500"
echo "    - View service mesh topology"
echo "    - Click any service → 'Metrics' tab for Prometheus data"
echo "    - Click 'Dashboard' link to open Grafana (requires Grafana port-forward)"
echo ""
```

### 6. OpenShift: `scripts/openshift-setup.sh` Output

Add dynamic Route URL retrieval:

```bash
CONSUL_UI_URL=$(oc get route consul-ui -n consul -o jsonpath='{.spec.host}' 2>/dev/null || echo "not-found")
GRAFANA_URL=$(oc get route grafana -n observability -o jsonpath='{.spec.host}' 2>/dev/null || echo "not-found")

echo "  Consul UI:"
echo "    https://${CONSUL_UI_URL}"
echo "    - View service mesh topology"
echo "    - Click any service → 'Metrics' tab for Prometheus data"
echo "    - Click 'Dashboard' link to open Grafana at https://${GRAFANA_URL}"
echo ""
```

## Grafana Dashboard Mapping

### Current Dashboards
Based on the repository structure, these dashboards exist:

| Dashboard File | Dashboard ID | Purpose |
|----------------|--------------|---------|
| `service-to-service.json` | `service-to-service` | Main service traffic view |
| `service-health.json` | `ffbs6tb0gr4lcb` | Service health metrics |
| `consul-health.json` | `consul-health` | Consul cluster health |
| `envoy-logs.json` | `envoy-access-logs` | Envoy access logs |
| `gateways.json` | `consul-gateways` | Gateway metrics |

### Recommended Dashboard for Consul UI Link

**Primary Choice:** `service-to-service` dashboard
- **Reason:** Most comprehensive service-level view
- **Variables:** Already supports `var-service` parameter
- **URL Pattern:** `http://localhost:3000/d/service-to-service?orgId=1&var-service={{Service.Name}}&var-dc={{Datacenter}}`

**Alternative:** `service-health` dashboard (ID: `ffbs6tb0gr4lcb`)
- More focused on health metrics (errors, latency, RPS)
- URL: `http://localhost:3000/d/ffbs6tb0gr4lcb?orgId=1&var-service={{Service.Name}}&var-dc={{Datacenter}}`

### Dashboard Variable Verification

**Action Required:** Verify that the Grafana dashboards support these variables:
1. Open each dashboard JSON file
2. Check the `templating.list` section for variable definitions
3. Ensure `var-service` and `var-dc` exist
4. If missing, add them to the dashboard JSON

**Example Variable Definition:**
```json
{
  "templating": {
    "list": [
      {
        "name": "service",
        "type": "query",
        "query": "label_values(envoy_cluster_upstream_rq_total, consul_service)",
        "current": {
          "text": "All",
          "value": "$__all"
        }
      },
      {
        "name": "dc",
        "type": "constant",
        "query": "dc1",
        "current": {
          "text": "dc1",
          "value": "dc1"
        }
      }
    ]
  }
}
```

## Security Considerations

### ACL Token Requirements

**Kubernetes/OpenShift:**
- Consul UI metrics require ACL token with read permissions
- Current setup: ACLs enabled (`acls.manageSystemACLs: true`)
- Token is auto-generated and stored in Secret: `consul-bootstrap-acl-token`
- **Action:** Verify that the UI can access metrics with the bootstrap token

**Docker/Podman:**
- No ACLs configured (dev environment)
- Metrics accessible without authentication
- **Recommendation:** Document that production deployments should enable ACLs

### Prometheus Access

**Current Setup:**
- Prometheus is cluster-internal (ClusterIP service)
- Consul UI accesses via `metrics_proxy` (server-side proxy)
- No direct browser → Prometheus connection needed

**Security Benefits:**
- Prometheus not exposed to external networks
- Consul server acts as authenticated proxy
- ACL token controls access to metrics

## Implementation Steps

### Phase 1: Configuration Updates (Plan Mode)
1. ✅ Research Consul UI configuration requirements
2. ✅ Document current state
3. ✅ Design metrics_proxy configuration for all deployments
4. ✅ Design dashboard_url_templates for all deployments
5. Create configuration file updates (requires switching to code mode)

### Phase 2: Script Updates (Code Mode)
1. Update `docker/consul/consul.hcl` with metrics config
2. Update `kubernetes/consul/values.yaml` with metrics config
3. Update `openshift/consul/values.yaml` with metrics config
4. Modify `scripts/kind-setup.sh` to output Consul UI URL
5. Modify `scripts/openshift-setup.sh` to output Consul UI URL
6. Update README files with new access information

### Phase 3: Dashboard Verification (Code Mode)
1. Check Grafana dashboard JSON files for required variables
2. Add missing variables if needed
3. Test dashboard URL with variable substitution

### Phase 4: Testing & Validation
1. Test Docker deployment with new config
2. Test Kubernetes deployment with new config
3. Test OpenShift deployment with new config
4. Verify metrics display in Consul UI
5. Verify dashboard links work correctly

## Testing Checklist

### Docker/Podman
- [ ] Consul UI accessible at `http://localhost:8500`
- [ ] Click on a service (e.g., "web")
- [ ] "Metrics" tab displays Prometheus data
- [ ] "Dashboard" link opens Grafana at correct URL
- [ ] Grafana dashboard shows service-specific data

### Kubernetes
- [ ] Port-forward to Consul UI works
- [ ] Consul UI accessible at `http://localhost:8500`
- [ ] Metrics tab shows data from Prometheus
- [ ] Dashboard link opens Grafana (with port-forward)
- [ ] Service name variable is correctly substituted

### OpenShift
- [ ] Consul UI Route is accessible (HTTPS)
- [ ] Metrics tab displays data
- [ ] Dashboard link opens Grafana Route
- [ ] No certificate errors (self-signed certs expected in CRC)

## Rollback Plan

If issues occur:

1. **Metrics not displaying:**
   - Check Prometheus connectivity: `curl http://prometheus:9090/-/healthy`
   - Verify ACL token permissions
   - Check Consul logs: `kubectl logs -n consul consul-server-0`

2. **Dashboard links broken:**
   - Verify Grafana dashboard IDs match
   - Check dashboard variable names
   - Test URL manually with hardcoded service name

3. **Complete rollback:**
   - Remove `metrics_proxy` and `dashboard_url_templates` sections
   - Restart Consul (Docker: `docker compose restart consul`, K8s: `helm upgrade`)

## Documentation Updates Required

### Files to Update
1. `README.md` - Add Consul UI access info to main endpoints table
2. `docker/README.md` - Add metrics integration notes
3. `kubernetes/README.md` - Add Consul UI port-forward instructions
4. `openshift/README.md` - Add Route URL information
5. `docs/observability.md` - Add section on Consul UI metrics integration

### New Documentation Sections

**Consul UI Metrics Integration:**
```markdown
## Consul UI Metrics Integration

The Consul UI is configured to display Prometheus metrics and link directly to Grafana dashboards.

### Accessing Metrics in Consul UI

1. Navigate to the Services page
2. Click on any service name
3. Click the "Metrics" tab to view:
   - Request rate (RPS)
   - Error rate
   - Latency percentiles (P50, P99)
   - Active connections

4. Click the "Dashboard" button to open the full Grafana dashboard for that service

### Configuration

The integration is configured via:
- **Docker/Podman:** `docker/consul/consul.hcl` → `ui_config` block
- **Kubernetes:** `kubernetes/consul/values.yaml` → `ui.metrics` and `ui.dashboardURLTemplates`
- **OpenShift:** Inherits Kubernetes config + Route-specific dashboard URLs
```

## Open Questions

1. **Dashboard ID Verification:** Need to confirm the actual dashboard IDs in the provisioned Grafana dashboards
2. **Helm Chart Version:** Should verify the exact Helm chart version to confirm 0.40.0+ features are available
3. **Enterprise Features:** If Enterprise is used, should we add Namespace/Partition variables?
4. **Multiple Dashboards:** Should we configure multiple dashboard types (service, node, etc.)?

## Success Criteria

### Must Have
- ✅ Consul UI URLs printed in all setup script outputs
- ✅ metrics_proxy configured for all deployments
- ✅ dashboard_url_templates configured for all deployments
- ✅ Configuration compatible with Consul 1.22.3
- ✅ Documentation updated with access instructions

### Nice to Have
- Dashboard variables verified and tested
- Multiple dashboard URL templates (service, node, etc.)
- Automated testing of metrics integration
- Screenshots in documentation

## Next Steps

**Immediate Actions:**
1. Switch to `code` mode to implement configuration changes
2. Update `docker/consul/consul.hcl` with metrics config
3. Update Kubernetes and OpenShift Helm values
4. Modify setup scripts to output Consul UI URLs
5. Test each deployment type

**User Decision Required:**
- Which Grafana dashboard should be the primary link? (Recommend: `service-to-service`)
- Should we add multiple dashboard URL templates?
- Any specific URL format preferences for OpenShift Routes?
