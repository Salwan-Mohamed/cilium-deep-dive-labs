# Lab 03: Network Policy Enforcement

## Overview

This lab demonstrates Cilium's network policy capabilities, from basic Layer 3/4 policies to advanced Layer 7 policies, FQDN-based rules, and policy troubleshooting.

**Duration:** 60-75 minutes  
**Difficulty:** Intermediate

## Learning Objectives

- Understand Cilium Network Policy structure
- Implement Layer 3/4 (IP/Port) policies
- Create Layer 7 (HTTP/DNS) policies
- Use FQDN-based egress policies
- Troubleshoot policy issues
- Monitor policy verdicts with Hubble

## Prerequisites

- Completed Lab 01 (Packet Flow)
- Running Kind cluster with Cilium
- Demo applications deployed

## Part 1: Default Deny Policy

### Step 1: Observe Current Behavior

```bash
# Test connectivity (should work - cluster is open by default)
kubectl exec -n demo deployment/frontend -- curl -s http://backend:8080
# Should succeed

# View flows
cilium hubble observe --namespace demo --last 10
```

### Step 2: Apply Default Deny

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny
  namespace: demo
spec:
  endpointSelector: {}  # Matches all pods in namespace
  # No ingress or egress rules = deny all
EOF
```

### Step 3: Verify Denial

```bash
# This should now fail
kubectl exec -n demo deployment/frontend -- curl -s --max-time 5 http://backend:8080
# Timeout (connection denied)

# View drops in Hubble
cilium hubble observe --namespace demo --verdict DROPPED --last 20
```

## Part 2: Layer 3/4 Policies

### Step 4: Allow Frontend → Backend

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-frontend-to-backend
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
EOF
```

### Step 5: Test Connectivity

```bash
# Should work now
kubectl exec -n demo deployment/frontend -- curl -s http://backend:8080

# Verify with Hubble
cilium hubble observe \
  --namespace demo \
  --from-pod demo/frontend \
  --to-pod demo/backend \
  --last 5
```

### Step 6: Allow DNS Resolution

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: demo
spec:
  endpointSelector:
    matchLabels: {}  # All pods
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

## Part 3: Layer 7 HTTP Policies

### Step 7: Deploy HTTP Service

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: demo
spec:
  selector:
    app: httpbin
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
EOF

kubectl rollout status -n demo deployment/httpbin
```

### Step 8: Apply L7 HTTP Policy

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-http-policy
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: httpbin
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/get"
        - method: "POST"
          path: "/post"
        # Note: /delete is NOT allowed
EOF
```

### Step 9: Test L7 Policy

```bash
# GET /get - Should work
kubectl exec -n demo deployment/frontend -- \
  curl -s http://httpbin/get

# POST /post - Should work
kubectl exec -n demo deployment/frontend -- \
  curl -s -X POST http://httpbin/post -d "data=test"

# DELETE /delete - Should be denied
kubectl exec -n demo deployment/frontend -- \
  curl -s -X DELETE http://httpbin/delete -w "\nHTTP Code: %{http_code}\n"
# Should return 403 Forbidden

# View L7 denials
cilium hubble observe \
  --namespace demo \
  --protocol http \
  --verdict DROPPED \
  --last 10
```

## Part 4: FQDN-Based Egress

### Step 10: Allow External API Access

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-github-api
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  - toFQDNs:
    - matchName: "api.github.com"
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
EOF
```

### Step 11: Test FQDN Policy

```bash
# Should work
kubectl exec -n demo deployment/frontend -- \
  curl -s https://api.github.com

# Should fail (not allowed)
kubectl exec -n demo deployment/frontend -- \
  curl -s --max-time 5 https://google.com
# Timeout

# View DNS and FQDN enforcement
cilium hubble observe \
  --namespace demo \
  --protocol dns \
  --last 20
```

## Part 5: Policy Troubleshooting

### Step 12: Using `cilium policy trace`

```bash
# Get pod IDs
FRONTEND_POD=$(kubectl get pod -n demo -l app=frontend -o jsonpath='{.items[0].metadata.name}')
BACKEND_POD=$(kubectl get pod -n demo -l app=backend -o jsonpath='{.items[0].metadata.name}')

# Trace policy decision
cilium policy trace \
  --src-k8s-pod demo/$FRONTEND_POD \
  --dst-k8s-pod demo/$BACKEND_POD \
  --dport 8080

# Output shows:
# - Which policies matched
# - Allow or deny decision
# - Rule that caused decision
```

### Step 13: Check Endpoint Policy Status

```bash
# Get endpoint for backend
kubectl get cep -n demo -l app=backend -o yaml

# Look for:
# - policy-enabled: ingress, egress
# - policy-revision: Shows when last updated
# - realized: Policy successfully applied
```

### Step 14: Common Policy Issues

**Issue 1: Policy Not Taking Effect**

```bash
# Check if policy exists
kubectl get cnp -n demo

# Check policy status
kubectl describe cnp -n demo allow-frontend-to-backend

# Check endpoint policy
kubectl get cep -n demo

# Force policy recalculation
kubectl delete pod -n demo -l app=backend
```

**Issue 2: Port Mismatch**

```bash
# Bad policy (wrong port)
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: wrong-port
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
      - port: "80"  # Wrong! Should be 8080
EOF

# Test fails
kubectl exec -n demo deployment/frontend -- curl -s --max-time 5 http://backend:8080

# Debug with Hubble
cilium hubble observe --namespace demo --verdict DROPPED

# Fix
kubectl patch cnp wrong-port -n demo --type=json -p='[
  {"op": "replace", "path": "/spec/ingress/0/toPorts/0/ports/0/port", "value": "8080"}
]'
```

**Issue 3: Label Selector Typo**

```bash
# Check actual labels
kubectl get pods -n demo --show-labels

# Verify policy selector matches
kubectl get cnp -n demo allow-frontend-to-backend -o yaml | grep -A 5 endpointSelector
```

## Part 6: Advanced Scenarios

### Step 15: Multi-Tier Application

```bash
# Deploy database
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: database
  namespace: demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: database
      tier: data
  template:
    metadata:
      labels:
        app: database
        tier: data
    spec:
      containers:
      - name: postgres
        image: postgres:13
        env:
        - name: POSTGRES_PASSWORD
          value: password
        ports:
        - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: database
  namespace: demo
spec:
  selector:
    app: database
  ports:
  - port: 5432
EOF

# Create tiered policy
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: three-tier-policy
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      tier: data
  ingress:
  # Only backend tier can access data tier
  - fromEndpoints:
    - matchLabels:
        tier: backend
    toPorts:
    - ports:
      - port: "5432"
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-policy
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      tier: backend
  ingress:
  # Only frontend tier can access backend
  - fromEndpoints:
    - matchLabels:
        tier: frontend
    toPorts:
    - ports:
      - port: "8080"
EOF
```

### Step 16: Egress Gateway Pattern

```bash
# Allow egress only through specific pod
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: egress-gateway
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  # Must go through egress gateway
  - toEndpoints:
    - matchLabels:
        app: egress-proxy
  # Allow DNS
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s:k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
EOF
```

## Review and Key Takeaways

### Policy Best Practices

1. **Start with observation**: Use Hubble to understand traffic before creating policies
2. **Test incrementally**: Apply policies to one namespace/app at a time
3. **Use labels wisely**: Consistent labeling strategy is crucial
4. **Allow DNS first**: Most apps need DNS, create this policy early
5. **Layer 7 for sensitive services**: HTTP/gRPC rules for fine-grained control

### Common Patterns

```yaml
# Default deny
endpointSelector: {}
# (no rules)

# Allow from namespace
- fromEndpoints:
  - matchLabels:
      k8s:io.kubernetes.pod.namespace: prod

# Allow to external CIDR
- toCIDR:
  - 10.0.0.0/8

# Allow to service
- toServices:
  - k8sService:
      serviceName: my-service
      namespace: other-ns
```

### Debugging Checklist

- [ ] Policy exists: `kubectl get cnp`
- [ ] Labels match: `kubectl get pods --show-labels`
- [ ] Endpoint has policy: `kubectl get cep`
- [ ] Use policy trace: `cilium policy trace`
- [ ] Check Hubble drops: `cilium hubble observe --verdict DROPPED`

## Next Steps

- **Lab 04**: Observability Internals - Deep dive into Hubble
- **Lab 05**: Production Features - Gateway API, rate limiting

## Additional Resources

- [Cilium Network Policy](https://docs.cilium.io/en/stable/security/policy/)
- [Policy Examples](https://github.com/cilium/cilium/tree/master/examples/policies)
- [Troubleshooting Guide](https://docs.cilium.io/en/stable/operations/troubleshooting/)

---

**Congratulations!** You now understand Cilium network policies from basic to advanced scenarios.
