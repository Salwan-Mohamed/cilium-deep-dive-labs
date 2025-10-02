# Lab 04: Observability Internals - Hubble Deep Dive

## Overview

In this lab, you'll explore Hubble's observability capabilities in depth, learning how to monitor network flows, analyze service dependencies, implement golden signals monitoring, and troubleshoot issues using Hubble's powerful toolset.

**Duration:** 45-60 minutes  
**Difficulty:** Intermediate

## Learning Objectives

- Understand Hubble's architecture and event generation
- Use the Hubble UI for service dependency mapping
- Implement golden signals (latency, traffic, errors, saturation) monitoring
- Enable Layer 7 (HTTP/gRPC/DNS) visibility
- Integrate Hubble with Prometheus and Grafana
- Export flows for compliance and audit

## Prerequisites

- Completed Labs 01-02
- Hubble enabled in cluster (done in setup)
- Demo applications running
- Basic understanding of HTTP and DNS protocols

## Lab Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Observability Stack                       │
│  ┌──────────┐    ┌───────────┐    ┌──────────┐             │
│  │  Hubble  │───→│ Prometheus│───→│ Grafana  │             │
│  │   Relay  │    └───────────┘    └──────────┘             │
│  └────┬─────┘                                                │
│       │                                                      │
│  ┌────┴───────────────────────────┐                         │
│  │  Hubble Agents (per node)      │                         │
│  └────┬───────────────────────────┘                         │
│       │                                                      │
│  ┌────┴──────────────────┐                                  │
│  │  eBPF Programs         │                                  │
│  │  (event generation)    │                                  │
│  └────────────────────────┘                                  │
└─────────────────────────────────────────────────────────────┘
```

## Part 1: Hubble UI Exploration

### Step 1: Access Hubble UI

```bash
# Port forward Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Open in browser
open http://localhost:12000
```

### Step 2: Generate Traffic

```bash
# Create continuous traffic between services
kubectl exec -n demo deployment/frontend -- sh -c \
  'while true; do curl -s http://backend:8080; sleep 2; done' &

TRAFFIC_PID=$!

# Let it run for 2 minutes
sleep 120
```

### Step 3: Explore Service Map

In Hubble UI:
1. Select namespace: `demo`
2. Observe the service dependency map
3. Click on services to see details
4. Note the protocols and traffic volume

**Questions to answer:**
- Which services are communicating?
- What protocols are being used?
- Are there any external connections?
- What's the traffic volume between services?

### Step 4: View Flow Details

In the UI, switch to "Flows" tab:
- See individual network flows
- Filter by service, protocol, or verdict
- Examine source and destination identities

```bash
# Alternative: CLI flow observation
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --last 20
```

### Step 5: Analyze Policy Verdicts

Filter for different verdicts:
```bash
# View forwarded traffic
hubble observe --verdict FORWARDED --namespace demo

# View drops (should be none yet)
hubble observe --verdict DROPPED --namespace demo

# View all verdicts with counts
hubble observe --namespace demo --last 100 | \
  grep -o "verdict=[A-Z]*" | sort | uniq -c
```

## Part 2: Layer 7 Visibility

### Step 6: Enable HTTP Visibility

Apply L7 policy to enable HTTP parsing:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: http-visibility
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: "GET"
        - method: "POST"
EOF
```

### Step 7: Observe HTTP Details

```bash
# View HTTP requests with details
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --protocol http \
  --http-status 200

# Expected output includes:
# - HTTP method (GET, POST)
# - URL path
# - Response code
# - Response time
```

### Step 8: DNS Visibility

Enable DNS observability:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: dns-visibility
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s:k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
      rules:
        dns:
        - matchPattern: "*"
EOF
```

Observe DNS queries:

```bash
# Trigger some DNS lookups
kubectl exec -n demo deployment/frontend -- sh -c \
  'for i in {1..5}; do nslookup backend; sleep 1; done'

# View DNS queries
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --protocol dns

# Expected: DNS queries for backend.demo.svc.cluster.local
```

## Part 3: Golden Signals Monitoring

### Step 9: Enable Hubble Metrics

Verify Hubble metrics are enabled:

```bash
# Check current metrics config
kubectl -n kube-system get configmap cilium-config -o yaml | grep -A 10 "hubble-metrics"

# Should include: dns, drop, tcp, flow, http
```

### Step 10: Access Prometheus Metrics

```bash
# Port forward Prometheus (if installed)
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Or directly query Hubble metrics
kubectl -n kube-system exec ds/cilium -- \
  curl -s localhost:9091/metrics | grep hubble
```

Key metrics to observe:
- `hubble_flows_processed_total` - Total flows observed
- `hubble_drop_total` - Dropped packets
- `hubble_http_requests_total` - HTTP request count
- `hubble_http_request_duration_seconds` - HTTP latency
- `hubble_dns_queries_total` - DNS query count

### Step 11: Create Latency Measurements

Generate traffic with varying latency:

```bash
# Deploy a slow endpoint
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: slow-backend
  namespace: demo
  labels:
    app: slow-backend
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo 'server { listen 8080; location / { return 200 "slow"; } }' > /etc/nginx/conf.d/default.conf
      sleep 2 && nginx -g 'daemon off;'
EOF

# Generate requests
for i in {1..50}; do
  kubectl exec -n demo deployment/frontend -- curl -s http://slow-backend:8080
  sleep 0.5
done
```

Query latency metrics:

```bash
# View HTTP duration histogram
kubectl -n kube-system exec ds/cilium -- \
  curl -s localhost:9091/metrics | \
  grep hubble_http_request_duration_seconds
```

### Step 12: Monitor Error Rates

Simulate errors:

```bash
# Create a pod that returns errors
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: error-backend
  namespace: demo
  labels:
    app: error-backend
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo 'server { listen 8080; location / { return 500 "error"; } }' > /etc/nginx/conf.d/default.conf
      nginx -g 'daemon off;'
EOF

# Generate error requests
for i in {1..20}; do
  kubectl exec -n demo deployment/frontend -- \
    curl -s -w "%{http_code}\n" -o /dev/null http://error-backend:8080
done
```

Observe error metrics:

```bash
# View HTTP status codes
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --http-status 500 \
  --last 20

# Check error rate in metrics
kubectl -n kube-system exec ds/cilium -- \
  curl -s localhost:9091/metrics | \
  grep 'hubble_http_requests_total.*code="500"'
```

## Part 4: Grafana Integration

### Step 13: Install Grafana (if not already installed)

```bash
# Add Grafana helm repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

# Install Grafana
helm install grafana grafana/grafana \
  --namespace monitoring \
  --create-namespace \
  --set adminPassword=admin \
  --set service.type=ClusterIP

# Get admin password
kubectl get secret --namespace monitoring grafana -o jsonpath="{.data.admin-password}" | base64 --decode

# Port forward
kubectl port-forward -n monitoring svc/grafana 3000:80
```

### Step 14: Add Prometheus Data Source

1. Open Grafana: http://localhost:3000
2. Login (admin/admin)
3. Go to Configuration → Data Sources
4. Add Prometheus
5. URL: `http://prometheus.monitoring:9090`
6. Save & Test

### Step 15: Import Hubble Dashboard

```bash
# Download pre-built dashboards from repository
cd ../../grafana-dashboards

# Import via UI or API
for dashboard in *.json; do
  curl -X POST \
    -H "Content-Type: application/json" \
    -d @$dashboard \
    http://admin:admin@localhost:3000/api/dashboards/db
done
```

Dashboards included:
1. **Network Overview** - Cluster-wide traffic
2. **HTTP Golden Signals** - Latency, errors, traffic
3. **DNS Analytics** - Query patterns
4. **Security Audit** - Policy drops and denials

### Step 16: Create Custom Dashboard

Create a simple dashboard:

1. In Grafana, click "+" → Dashboard
2. Add Panel
3. Query: `rate(hubble_http_requests_total[5m])`
4. Title: "HTTP Request Rate"
5. Save dashboard

**Exercise**: Create panels for:
- HTTP error rate: `rate(hubble_http_requests_total{code=~"5.."}[5m])`
- DNS query rate: `rate(hubble_dns_queries_total[5m])`
- Policy drops: `rate(hubble_drop_total[5m])`

## Part 5: Flow Export and Compliance

### Step 17: Export Flows to JSON

```bash
# Export last hour of flows
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --since=1h \
  --namespace demo \
  --output json > /tmp/hubble-flows.json

# Analyze with jq
cat /tmp/hubble-flows.json | \
  jq -r '.flow | "\(.source.namespace)/\(.source.pod_name) → \(.destination.namespace)/\(.destination.pod_name)"' | \
  sort | uniq -c | sort -rn
```

### Step 18: Create Audit Report

Generate a compliance report:

```bash
# Create report script
cat > /tmp/audit-report.sh <<'EOF'
#!/bin/bash
echo "=== Hubble Audit Report ==="
echo "Date: $(date)"
echo ""

echo "Total Flows:"
hubble observe --since=24h | wc -l

echo ""
echo "Denied Connections:"
hubble observe --since=24h --verdict DROPPED | wc -l

echo ""
echo "Top Talkers:"
hubble observe --since=24h --output json | \
  jq -r '.flow.source.pod_name' | sort | uniq -c | sort -rn | head -10

echo ""
echo "External Connections:"
hubble observe --since=24h --to-identity 2 | wc -l
EOF

chmod +x /tmp/audit-report.sh

# Run report
kubectl -n kube-system exec ds/cilium -- bash < /tmp/audit-report.sh
```

### Step 19: Continuous Export

Set up continuous export to external storage:

```bash
# Example: Export to S3 daily
cat > /tmp/export-cronjob.yaml <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: hubble-export
  namespace: kube-system
spec:
  schedule: "0 0 * * *"  # Daily at midnight
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: export
            image: amazon/aws-cli
            command:
            - /bin/sh
            - -c
            - |
              hubble observe --since=24h --output json | \
              aws s3 cp - s3://audit-logs/hubble/\$(date +%Y-%m-%d).json
          restartPolicy: OnFailure
EOF

# kubectl apply -f /tmp/export-cronjob.yaml
```

## Part 6: Troubleshooting with Hubble

### Step 20: Diagnose Connectivity Issues

Simulate a connectivity problem:

```bash
# Apply deny policy
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: deny-to-backend
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  - toEndpoints:
    - matchLabels:
        app: backend
    toPorts:
    - ports:
      - port: "9999"  # Wrong port!
EOF

# Try to connect
kubectl exec -n demo deployment/frontend -- curl -v --max-time 5 http://backend:8080
# Should fail!
```

Diagnose with Hubble:

```bash
# Find the drops
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --verdict DROPPED \
  --from-pod demo/frontend \
  --last 10

# Should show policy denial
```

Fix the issue:

```bash
# Correct the policy
kubectl patch ciliumnetworkpolicy deny-to-backend -n demo --type=json -p='[
  {"op": "replace", "path": "/spec/egress/0/toPorts/0/ports/0/port", "value": "8080"}
]'

# Verify it works
kubectl exec -n demo deployment/frontend -- curl http://backend:8080
```

### Step 21: Identify Performance Issues

Use Hubble to find slow services:

```bash
# Query for high-latency requests
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --protocol http \
  --output json \
  --last 100 | \
  jq 'select(.l7.latency_ns > 1000000000) | {
    source: .source.pod_name,
    destination: .destination.pod_name,
    latency_ms: (.l7.latency_ns / 1000000),
    url: .l7.http.url
  }'
```

### Step 22: Security Analysis

Find unusual connection patterns:

```bash
# Detect connections to external IPs
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --to-identity 2 \
  --last 100

# Find failed authentication attempts (if using L7 auth)
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace demo \
  --http-status 401 \
  --http-status 403
```

## Review and Key Takeaways

### Hubble Capabilities Summary

1. **Network Visibility**: Complete L3-L7 flow visibility
2. **Identity-Aware**: See services, not just IPs
3. **Golden Signals**: Monitor latency, traffic, errors without instrumentation
4. **Policy Observability**: See what's allowed and what's denied
5. **Integration**: Works with Prometheus, Grafana, and SIEM tools

### Performance Impact

- CPU overhead: <1%
- Memory per node: ~50-100MB
- No impact on application performance
- Scales to 100K+ events/second per node

### Best Practices

1. Start with basic flow visibility
2. Enable L7 only where needed (reduces overhead)
3. Export flows for compliance/audit
4. Use Grafana for operational dashboards
5. Integrate with existing monitoring stack

## Next Steps

- **Lab 05**: [Advanced Topics](../05-advanced-topics/) - XDP, encryption, multi-cluster
- **Grafana Dashboards**: Explore pre-built dashboards in `/grafana-dashboards`
- **Automation**: Check `/automation` for policy generation scripts

## Additional Resources

- [Hubble Documentation](https://docs.cilium.io/en/stable/gettingstarted/hubble/)
- [Hubble Metrics Reference](https://docs.cilium.io/en/stable/operations/metrics/)
- **Repository**: See `exercises.md` for additional challenges

---

**Congratulations!** You now understand Hubble's observability capabilities and can monitor production Kubernetes environments effectively.
