# Lab 05: Production Features - Gateway API, Rate Limiting, and Monitoring

## Overview

This lab covers production-ready Cilium features essential for running at scale: Gateway API with TLS termination, pod rate limiting for traffic management, and comprehensive Grafana monitoring.

**Duration:** 90-120 minutes  
**Difficulty:** Advanced

## Learning Objectives

- Deploy Gateway API with TLS termination
- Configure pod bandwidth limits using eBPF
- Set up comprehensive Grafana monitoring
- Implement production-grade alerting
- Apply real-world best practices

## Prerequisites

- Completed Labs 01-04
- Understanding of TLS/certificates
- Basic Prometheus/Grafana knowledge
- Production mindset (we're going beyond labs here!)

## Part 1: Gateway API with TLS Termination

### Step 1: Install Gateway API CRDs

```bash
# Install Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

# Verify installation
kubectl get crd | grep gateway
```

### Step 2: Generate TLS Certificate

```bash
# Install mkcert (if not already installed)
# macOS
brew install mkcert
# Linux
wget -O mkcert https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64
chmod +x mkcert
sudo mv mkcert /usr/local/bin/

# Create local CA
mkcert -install

# Generate certificate
mkcert bookinfo.cilium.rocks

# Create Kubernetes secret
kubectl create secret tls bookinfo-tls \
  --cert=bookinfo.cilium.rocks.pem \
  --key=bookinfo.cilium.rocks-key.pem \
  --namespace=default
```

### Step 3: Deploy Sample Application

```bash
# Deploy bookinfo application
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: details
  namespace: default
spec:
  selector:
    app: details
  ports:
  - port: 9080
    targetPort: 9080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: details
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: details
  template:
    metadata:
      labels:
        app: details
    spec:
      containers:
      - name: details
        image: docker.io/istio/examples-bookinfo-details-v1:1.17.0
        ports:
        - containerPort: 9080
---
apiVersion: v1
kind: Service
metadata:
  name: reviews
  namespace: default
spec:
  selector:
    app: reviews
  ports:
  - port: 9080
    targetPort: 9080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: reviews
  template:
    metadata:
      labels:
        app: reviews
    spec:
      containers:
      - name: reviews
        image: docker.io/istio/examples-bookinfo-reviews-v1:1.17.0
        ports:
        - containerPort: 9080
EOF
```

### Step 4: Create Gateway and HTTPRoute

```bash
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: https-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: "bookinfo.cilium.rocks"
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: bookinfo-tls
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: bookinfo-route
  namespace: default
spec:
  parentRefs:
  - name: https-gateway
  hostnames:
  - "bookinfo.cilium.rocks"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /details
    backendRefs:
    - name: details
      port: 9080
  - matches:
    - path:
        type: PathPrefix
        value: /reviews
    backendRefs:
    - name: reviews
      port: 9080
EOF
```

### Step 5: Test HTTPS Access

```bash
# Get gateway IP
GATEWAY_IP=$(kubectl get svc -l "gateway.networking.k8s.io/gateway-name=https-gateway" \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')

echo "Gateway IP: $GATEWAY_IP"

# Add to /etc/hosts
echo "$GATEWAY_IP bookinfo.cilium.rocks" | sudo tee -a /etc/hosts

# Test HTTPS endpoint
curl https://bookinfo.cilium.rocks/details

# Should return book details JSON
```

### Step 6: Advanced HTTPRoute - Traffic Splitting

```bash
# Deploy v2 of reviews
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reviews-v2
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: reviews
      version: v2
  template:
    metadata:
      labels:
        app: reviews
        version: v2
    spec:
      containers:
      - name: reviews
        image: docker.io/istio/examples-bookinfo-reviews-v2:1.17.0
        ports:
        - containerPort: 9080
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v2
  namespace: default
spec:
  selector:
    app: reviews
    version: v2
  ports:
  - port: 9080
    targetPort: 9080
EOF

# Update HTTPRoute for canary (90% v1, 10% v2)
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: bookinfo-route
  namespace: default
spec:
  parentRefs:
  - name: https-gateway
  hostnames:
  - "bookinfo.cilium.rocks"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /reviews
    backendRefs:
    - name: reviews
      port: 9080
      weight: 90
    - name: reviews-v2
      port: 9080
      weight: 10
EOF

# Test multiple times to see distribution
for i in {1..20}; do
  curl -s https://bookinfo.cilium.rocks/reviews | jq .
done
```

## Part 2: Pod Rate Limiting

### Step 7: Enable Bandwidth Manager

```bash
# Verify bandwidth manager is enabled
kubectl -n kube-system exec ds/cilium -- cilium status | grep -i bandwidth

# If not enabled, upgrade Cilium
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set bandwidthManager.enabled=true \
  --reuse-values

# Restart Cilium agents
kubectl -n kube-system rollout restart ds/cilium

# Wait for restart
kubectl -n kube-system rollout status ds/cilium
```

### Step 8: Deploy netperf Server with Rate Limit

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: netperf-server
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: netperf-server
  template:
    metadata:
      labels:
        app: netperf-server
      annotations:
        kubernetes.io/egress-bandwidth: "10M"  # 10 Mbps limit
    spec:
      containers:
      - name: netperf
        image: networkstatic/netperf
        command: ["netserver", "-D"]
        ports:
        - containerPort: 12865
---
apiVersion: v1
kind: Service
metadata:
  name: netperf-server
  namespace: demo
spec:
  selector:
    app: netperf-server
  ports:
  - port: 12865
    targetPort: 12865
EOF
```

### Step 9: Deploy netperf Client (Different Node)

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: netperf-client
  namespace: demo
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: netperf-server
        topologyKey: kubernetes.io/hostname
  containers:
  - name: netperf
    image: networkstatic/netperf
    command: ["sleep", "infinity"]
EOF
```

### Step 10: Test Rate Limiting

```bash
# Get server IP
SERVER_IP=$(kubectl get pod -n demo -l app=netperf-server \
  -o jsonpath='{.items[0].status.podIP}')

# Run performance test
kubectl exec -n demo netperf-client -- netperf -H $SERVER_IP -l 10

# Expected: ~9.5 Mbps (just under 10 Mbps limit)
```

### Step 11: Verify eBPF Enforcement

```bash
# Find Cilium pod on same node as server
SERVER_NODE=$(kubectl get pod -n demo -l app=netperf-server \
  -o jsonpath='{.items[0].spec.nodeName}')

CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
  --field-selector spec.nodeName=$SERVER_NODE \
  -o jsonpath='{.items[0].metadata.name}')

# Check BPF bandwidth configuration
kubectl -n kube-system exec $CILIUM_POD -- cilium bpf bandwidth list

# Should show identity with 10 Mbit limit
```

### Step 12: Update Rate Limit

```bash
# Change to 100 Mbps
kubectl patch deployment -n demo netperf-server -p \
  '{"spec":{"template":{"metadata":{"annotations":{"kubernetes.io/egress-bandwidth":"100M"}}}}}'

# Wait for pod restart
kubectl rollout status deployment -n demo netperf-server

# Re-test
SERVER_IP=$(kubectl get pod -n demo -l app=netperf-server \
  -o jsonpath='{.items[0].status.podIP}')

kubectl exec -n demo netperf-client -- netperf -H $SERVER_IP -l 10

# Expected: ~95 Mbps
```

## Part 3: Comprehensive Grafana Monitoring

### Step 13: Deploy Monitoring Stack

```bash
# Create monitoring namespace
kubectl create namespace cilium-monitoring

# Deploy Prometheus and Grafana
kubectl apply -f https://raw.githubusercontent.com/cilium/cilium/v1.15.0/examples/kubernetes/addons/prometheus/monitoring-example.yaml

# Wait for pods
kubectl -n cilium-monitoring get pods -w
```

### Step 14: Configure Cilium Metrics

```bash
# Verify Hubble metrics are enabled
kubectl -n kube-system get configmap cilium-config -o yaml | grep hubble-metrics

# Should include: dns, drop, tcp, flow, http

# If not, update via Helm
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}" \
  --set hubble.metrics.serviceMonitor.enabled=true \
  --set prometheus.enabled=true \
  --set prometheus.serviceMonitor.enabled=true \
  --reuse-values
```

### Step 15: Access Grafana

```bash
# Port forward Grafana
kubectl -n cilium-monitoring port-forward svc/grafana 3000:3000

# Get admin password
kubectl -n cilium-monitoring get secret grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d

# Open browser: http://localhost:3000
# Login: admin / <password>
```

### Step 16: Import Custom Dashboards

```bash
# Download custom dashboards from repository
cd ../../grafana-dashboards

# Import via Grafana UI or API
for dashboard in *.json; do
  curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer <grafana-api-key>" \
    -d @$dashboard \
    http://localhost:3000/api/dashboards/db
done
```

### Step 17: Generate Traffic for Monitoring

```bash
# Run Cilium connectivity test to generate varied traffic
cilium connectivity test

# Or generate custom traffic
kubectl run traffic-generator -n demo --image=busybox --restart=Never -- \
  sh -c 'while true; do wget -q -O- http://backend:8080; sleep 1; done'
```

### Step 18: Explore Dashboards

In Grafana, explore:

1. **Cilium Metrics Dashboard**:
   - Agent CPU/memory per node
   - eBPF map pressure
   - API rate limiting
   - Endpoint count

2. **Hubble Dashboard**:
   - Flow distribution by namespace
   - TCP/UDP/DNS/HTTP breakdown
   - Policy verdicts (allow/deny)
   - Drop reasons

3. **HTTP Golden Signals**:
   - Request rate per service
   - Error rate (5xx responses)
   - Latency percentiles (P50, P95, P99)
   - Throughput

### Step 19: Create Custom Alert

```yaml
# Add to Prometheus rules
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-rules
  namespace: cilium-monitoring
data:
  cilium.rules: |
    groups:
    - name: cilium
      rules:
      - alert: CiliumAgentDown
        expr: up{job="cilium-agent"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Cilium agent down on node {{ \$labels.instance }}"
          
      - alert: HighPolicyDropRate
        expr: rate(hubble_drop_total{reason="Policy denied"}[5m]) > 10
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High policy drop rate in namespace {{ \$labels.namespace }}"
          
      - alert: BPFMapPressure
        expr: cilium_bpf_map_pressure > 0.8
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "eBPF map pressure high on node {{ \$labels.instance }}"
EOF

# Reload Prometheus
kubectl -n cilium-monitoring rollout restart deployment/prometheus
```

## Part 4: Production Scenarios

### Scenario 1: Troubleshooting High Drop Rate

```bash
# Alert fires: High policy drop rate

# Step 1: Identify affected namespace
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --verdict DROPPED \
  --since 5m \
  --output json | jq -r '.flow.source.namespace' | sort | uniq -c

# Step 2: Find specific sources/destinations
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --namespace production \
  --verdict DROPPED \
  --last 50

# Step 3: Identify missing policy
cilium policy trace \
  --src-pod production/frontend-xyz \
  --dst-pod production/backend-abc \
  --dport 8080

# Step 4: Apply fix
# (Create appropriate network policy)
```

### Scenario 2: Capacity Planning

```bash
# Question: Do we need more nodes?

# Check eBPF map utilization
kubectl -n kube-system exec ds/cilium -- cilium metrics list | \
  grep bpf_map_pressure

# Check connection tracking
kubectl -n kube-system exec ds/cilium -- cilium bpf ct list global | wc -l

# Check Cilium agent resource usage
kubectl top pods -n kube-system -l k8s-app=cilium

# Decision criteria:
# - Map pressure > 80%: Need more capacity
# - CPU consistently > 80%: Need more nodes
# - Memory > 80%: Increase limits or add nodes
```

## Review and Key Takeaways

### Production Checklist

- [ ] Gateway API with TLS configured
- [ ] Rate limiting tested and working
- [ ] Grafana dashboards accessible
- [ ] Alerts configured and tested
- [ ] Runbooks created for common issues
- [ ] Backup/restore procedures documented
- [ ] Upgrade strategy defined

### Performance Metrics

- **Gateway API**: <5ms added latency for TLS termination
- **Rate Limiting**: <1% CPU overhead
- **Monitoring**: Comprehensive visibility with <2% overhead

### Best Practices Applied

1. **Security**: TLS termination at edge, mTLS between services
2. **Reliability**: Rate limiting prevents cascade failures
3. **Observability**: Golden signals + detailed metrics
4. **Operations**: Alerts, runbooks, automated responses

## Next Steps

- **Production Deployment**: Apply these patterns to your clusters
- **Advanced Features**: Explore Cluster Mesh, Tetragon
- **Community**: Share your experiences, learn from others

## Additional Resources

- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [Cilium Bandwidth Manager](https://docs.cilium.io/en/stable/operations/performance/bandwidth-manager/)
- [Production Best Practices](https://docs.cilium.io/en/stable/operations/best-practices/)

---

**Congratulations!** You've mastered production-grade Cilium features and are ready for real-world deployments.
