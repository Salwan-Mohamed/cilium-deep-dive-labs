# Lab 01: Packet Flow Analysis

## Overview

In this lab, you'll trace a network packet's journey through Cilium's eBPF data path, from the moment an application initiates a connection until the response returns. You'll observe how Cilium intercepts packets at multiple kernel hook points, enforces policies, and provides observability.

**Duration:** 30-45 minutes  
**Difficulty:** Beginner

## Learning Objectives

By the end of this lab, you will:
- Understand the complete packet journey through Cilium
- Identify key eBPF hook points (socket, TC egress/ingress, XDP)
- Observe policy enforcement in action
- Explore connection tracking mechanisms
- Use Hubble to visualize packet flows

## Prerequisites

- Completed cluster setup (`./setup/complete-setup.sh`)
- Basic understanding of networking concepts (IP, TCP/UDP, ports)
- Familiarity with kubectl commands

## Lab Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Node 1                                   │
│  ┌──────────────┐                                                │
│  │  Frontend    │                                                │
│  │  Pod         │                                                │
│  │  10.0.1.50   │                                                │
│  └──────┬───────┘                                                │
│         │                                                         │
│         │ ① Socket Hook                                          │
│         ↓                                                         │
│    [eBPF Program]                                                │
│         │                                                         │
│         │ ② TC Egress                                            │
│         ↓                                                         │
│    [Policy Check]                                                │
│    [Encapsulation]                                               │
│         │                                                         │
└─────────┼─────────────────────────────────────────────────────────┘
          │
    [Physical Network]
          │
┌─────────┼─────────────────────────────────────────────────────────┐
│         ↓                                  Node 2                 │
│    ③ TC Ingress                                                   │
│    [Decapsulation]                                                │
│    [Policy Check]                                                 │
│         │                                                         │
│         ↓                                                         │
│  ┌──────────────┐                                                │
│  │  Backend     │                                                │
│  │  Pod         │                                                │
│  │  10.0.2.100  │                                                │
│  └──────────────┘                                                │
└───────────────────────────────────────────────────────────────────┘
```

## Part 1: Preparation and Observation Setup

### Step 1: Verify Lab Environment

```bash
# Ensure you're in the lab directory
cd labs/01-packet-flow

# Check demo pods are running
kubectl get pods -n demo -o wide

# You should see frontend, backend, and database pods
```

Expected output:
```
NAME                        READY   STATUS    RESTARTS   AGE   IP           NODE
frontend-xxx                1/1     Running   0          5m    10.0.1.50    worker-1
frontend-yyy                1/1     Running   0          5m    10.0.1.51    worker-2
backend-xxx                 1/1     Running   0          5m    10.0.2.100   worker-2
backend-yyy                 1/1     Running   0          5m    10.0.2.101   worker-3
```

### Step 2: Enable Hubble Observability

```bash
# Port-forward Hubble UI (in a separate terminal)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80

# Access UI at: http://localhost:12000

# Or use CLI to observe flows
kubectl -n kube-system exec ds/cilium -- hubble observe --follow --namespace demo
```

### Step 3: Identify Pod Details

Let's gather detailed information about our test pods:

```bash
# Get frontend pod name
FRONTEND_POD=$(kubectl get pod -n demo -l app=frontend -o jsonpath='{.items[0].metadata.name}')
echo "Frontend Pod: $FRONTEND_POD"

# Get backend service IP
BACKEND_SVC=$(kubectl get svc -n demo backend -o jsonpath='{.spec.clusterIP}')
echo "Backend Service IP: $BACKEND_SVC"

# View Cilium endpoint for frontend pod
kubectl -n kube-system exec ds/cilium -- cilium endpoint list | grep frontend
```

## Part 2: Tracing the Outbound Path (Egress)

### Step 4: Examine the Socket Layer Hook

The journey begins when the application makes a system call.

```bash
# Execute a curl from frontend to backend
kubectl exec -n demo $FRONTEND_POD -- curl -s http://backend:8080

# Observe the socket-level hook
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --from-pod demo/$FRONTEND_POD \
  --to-service demo/backend \
  --last 5
```

**What's Happening:**
1. Application calls `connect()` syscall
2. cgroup/connect4 eBPF program intercepts
3. Service IP (e.g., 172.20.1.5) translated to backend pod IP
4. Identity marked on packet

**Observe:**
```
TIMESTAMP             SOURCE                 DESTINATION            TYPE      VERDICT
10:30:45.123          demo/frontend-xxx      demo/backend-yyy       L3-L4     FORWARDED
```

### Step 5: TC Egress Processing

```bash
# View policy enforcement details
kubectl -n kube-system exec ds/cilium -- cilium policy get \
  $(kubectl get cep -n demo $FRONTEND_POD -o jsonpath='{.status.id}')

# Check if policy is enforced
kubectl get ciliumendpoint -n demo $FRONTEND_POD -o jsonpath='{.status.policy.realized.policy-enabled}'
```

**Key Operations at TC Egress:**
- Identity lookup from eBPF map
- Policy enforcement (L3/L4)
- Connection tracking entry creation
- VxLAN encapsulation (for cross-node traffic)

### Step 6: Observe Encapsulation

For cross-node traffic, Cilium encapsulates packets:

```bash
# Check if pods are on different nodes
FRONTEND_NODE=$(kubectl get pod -n demo $FRONTEND_POD -o jsonpath='{.spec.nodeName}')
BACKEND_NODE=$(kubectl get pod -n demo $(kubectl get pod -n demo -l app=backend -o jsonpath='{.items[0].metadata.name}') -o jsonpath='{.spec.nodeName}')

echo "Frontend on: $FRONTEND_NODE"
echo "Backend on: $BACKEND_NODE"

# View encapsulation mode
kubectl -n kube-system exec ds/cilium -- cilium config | grep tunnel
```

Expected: `tunnel: vxlan` (default)

## Part 3: Tracing the Inbound Path (Ingress)

### Step 7: TC Ingress on Destination Node

```bash
# Observe ingress processing
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --to-pod demo/backend \
  --type trace \
  --last 10

# Check ingress policy enforcement
kubectl get cep -n demo -l app=backend -o yaml | grep -A 10 "ingress-enforcement"
```

**Key Operations at TC Ingress:**
- Decapsulation (remove VxLAN headers)
- Destination endpoint lookup
- Ingress policy verification
- Delivery to pod network namespace

### Step 8: End-to-End Flow Visualization

```bash
# Generate continuous traffic
kubectl exec -n demo $FRONTEND_POD -- sh -c 'while true; do curl -s http://backend:8080; sleep 1; done' &
TRAFFIC_PID=$!

# Watch in Hubble UI or CLI
kubectl -n kube-system exec ds/cilium -- hubble observe --follow \
  --from-pod demo/$FRONTEND_POD \
  --to-service demo/backend

# Stop traffic after observation
kill $TRAFFIC_PID
```

## Part 4: Connection Tracking

### Step 9: Explore Connection Tracking Map

```bash
# View connection tracking entries
kubectl -n kube-system exec ds/cilium -- cilium bpf ct list global | grep -A 2 "demo"

# Detailed CT entry
kubectl -n kube-system exec ds/cilium -- cilium monitor --type trace
```

**Connection Tracking Entry Structure:**
```
TCP IN 10.0.1.50:43210 -> 10.0.2.100:8080 expires=120s
  RxPackets=10 RxBytes=1500
  TxPackets=10 TxBytes=8000
  Flags=ESTABLISHED
```

### Step 10: Observe Stateful Behavior

```bash
# Establish connection
kubectl exec -n demo $FRONTEND_POD -- curl http://backend:8080 &

# Observe return path uses CT
kubectl -n kube-system exec ds/cilium -- hubble observe --type trace \
  --from-pod demo/backend \
  --to-pod demo/frontend
```

Notice: Return packets are fast-tracked using connection tracking!

## Part 5: Advanced Observations

### Step 11: Layer 7 Visibility

```bash
# Apply L7 visibility policy
kubectl apply -f l7-visibility-policy.yaml

# Generate HTTP traffic
kubectl exec -n demo $FRONTEND_POD -- curl -s http://backend:8080/api/users

# Observe HTTP details
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --protocol http \
  --from-pod demo/$FRONTEND_POD
```

Expected output includes HTTP method, path, status code:
```
HTTP/1.1 GET http://backend:8080/api/users → 200 OK
```

### Step 12: Performance Metrics

```bash
# View packet processing statistics
kubectl -n kube-system exec ds/cilium -- cilium metrics list | grep -i drop
kubectl -n kube-system exec ds/cilium -- cilium metrics list | grep -i forward

# BPF program statistics
kubectl -n kube-system exec ds/cilium -- cilium bpf metrics list
```

## Part 6: Troubleshooting Exercise

### Step 13: Simulated Connectivity Issue

```bash
# Apply a deny policy
kubectl apply -f deny-policy.yaml

# Try to connect
kubectl exec -n demo $FRONTEND_POD -- curl -v --max-time 5 http://backend:8080

# Observe the drop
kubectl -n kube-system exec ds/cilium -- hubble observe \
  --verdict DROPPED \
  --from-pod demo/$FRONTEND_POD
```

Expected:
```
DROPPED (Policy denied) demo/frontend-xxx → demo/backend-yyy
```

### Step 14: Policy Trace Simulation

```bash
# Use policy trace to understand why
kubectl -n kube-system exec ds/cilium -- cilium policy trace \
  --src-k8s-pod demo/$FRONTEND_POD \
  --dst-k8s-pod demo/$(kubectl get pod -n demo -l app=backend -o jsonpath='{.items[0].metadata.name}') \
  --dport 8080

# Remove deny policy
kubectl delete -f deny-policy.yaml
```

## Review and Key Takeaways

### Packet Journey Summary

1. **Socket Layer**: Application syscall → eBPF hook → Service translation
2. **TC Egress**: Policy enforcement → Connection tracking → Encapsulation
3. **Network**: Physical transmission (with VxLAN)
4. **TC Ingress**: Decapsulation → Policy check → Delivery
5. **Return Path**: Leverages connection tracking for fast-path

### Performance Impact

- **Socket Hook**: ~10-20 µs overhead
- **TC Processing**: ~30-50 µs per direction
- **Total**: ~100-150 µs added latency
- **Throughput**: Minimal impact (<1% for most workloads)

### Commands Reference

```bash
# Hubble observation
hubble observe --follow --namespace demo

# Endpoint details
cilium endpoint list
cilium endpoint get <id>

# Policy inspection
cilium policy get <endpoint-id>

# Connection tracking
cilium bpf ct list global

# Map inspection
cilium bpf lb list
cilium bpf endpoint list
```

## Next Steps

- **Lab 02**: [eBPF Map Inspection](../02-map-inspection/) - Deep dive into kernel data structures
- **Advanced**: Explore XDP acceleration (Lab 05)
- **Challenge**: Set up Cluster Mesh and trace cross-cluster traffic

## Additional Resources

- [Cilium Data Path Documentation](https://docs.cilium.io/en/stable/concepts/ebpf/intro/)
- [Life of a Packet Video](https://www.youtube.com/watch?v=XXX)
- **Repository**: See `exercises.md` for additional hands-on challenges

---

**Congratulations!** You've successfully traced a packet through Cilium's eBPF data path and understand the key hook points and operations.
