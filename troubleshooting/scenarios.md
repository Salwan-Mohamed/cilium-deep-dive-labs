# Troubleshooting Scenarios

## Real-World Troubleshooting Scenarios and Solutions

This document contains common Cilium issues encountered in production environments, with step-by-step resolution guides.

## Quick Reference

| Issue | Symptom | Quick Fix |
|-------|---------|-----------|
| Policy Not Applied | Traffic still works/blocked | Check endpoint status, restart pod |
| Connection Timeout | Curl times out | Check drops, verify policy |
| DNS Failures | nslookup fails | Check DNS policy, CoreDNS |
| High Latency | Slow responses | Check Hubble metrics, CPU |
| Agent Crash Loop | Pods stuck Creating | Check kernel version, logs |

---

## Scenario 1: Pod Can't Reach Service

### Symptoms
```bash
$ kubectl exec frontend -- curl backend:8080
curl: (28) Connection timed out
```

### Diagnosis Steps

**Step 1: Verify Service Exists**
```bash
kubectl get svc backend -n demo
# Should show service with ClusterIP
```

**Step 2: Check DNS**
```bash
kubectl exec frontend -n demo -- nslookup backend
# Should resolve to ClusterIP
```

**Step 3: Check for Drops**
```bash
cilium hubble observe \
  --namespace demo \
  --from-pod demo/frontend \
  --verdict DROPPED \
  --last 10
```

### Common Causes & Solutions

**Cause 1: Network Policy Blocking**
```bash
# Symptom: Hubble shows "Policy denied"
cilium hubble observe --namespace demo --verdict DROPPED

# Solution: Apply correct policy
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
EOF
```

**Cause 2: Wrong Port in Policy**
```bash
# Check service port
kubectl get svc backend -n demo -o jsonpath='{.spec.ports[0].port}'

# Verify policy port matches
kubectl get cnp -n demo -o yaml | grep -A 5 port
```

**Cause 3: DNS Policy Missing**
```bash
# Frontend can't resolve backend name
# Solution: Allow DNS
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: demo
spec:
  endpointSelector: {}
  egress:
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

---

## Scenario 2: Policy Not Taking Effect

### Symptoms
- Applied network policy
- Traffic still flowing (should be blocked)
- Or traffic blocked (should be allowed)

### Diagnosis Steps

**Step 1: Verify Policy Exists**
```bash
kubectl get cnp -n demo
kubectl describe cnp my-policy -n demo
```

**Step 2: Check Endpoint Status**
```bash
# Get endpoints
kubectl get cep -n demo

# Check if policy realized
kubectl get cep backend-xyz -n demo -o jsonpath='{.status.policy.realized}'
```

**Step 3: Check Policy Revision**
```bash
# Each endpoint tracks policy version
kubectl get cep -n demo -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.policy.revision}{"\n"}{end}'
```

### Solutions

**Solution 1: Policy Selector Doesn't Match**
```bash
# Check pod labels
kubectl get pods -n demo --show-labels

# Check policy selector
kubectl get cnp my-policy -n demo -o yaml | grep -A 5 endpointSelector

# Fix: Update policy with correct labels
kubectl patch cnp my-policy -n demo --type=json -p='[
  {"op": "replace", "path": "/spec/endpointSelector/matchLabels/app", "value": "correct-app-name"}
]'
```

**Solution 2: Policy Not Propagated**
```bash
# Force policy recalculation
kubectl delete pod backend-xyz -n demo

# Pod recreates and gets latest policy
```

**Solution 3: Conflicting Policies**
```bash
# List all policies affecting an endpoint
kubectl get cnp -n demo

# Check for conflicting rules
# Most specific policy wins
# Deny takes precedence over allow
```

---

## Scenario 3: Cilium Agent Crash Loop

### Symptoms
```bash
$ kubectl get pods -n kube-system -l k8s-app=cilium
NAME           READY   STATUS             RESTARTS   AGE
cilium-abc123  0/1     CrashLoopBackOff   5          3m
```

### Diagnosis Steps

**Step 1: Check Logs**
```bash
kubectl logs -n kube-system cilium-abc123 --previous

# Common errors:
# - "Failed to load eBPF program"
# - "Kernel version not supported"
# - "Cannot mount BPF filesystem"
```

**Step 2: Check Node**
```bash
# Get node name
NODE=$(kubectl get pod -n kube-system cilium-abc123 -o jsonpath='{.spec.nodeName}')

# Check kernel version
kubectl debug node/$NODE -it --image=ubuntu -- uname -r
# Cilium requires kernel 4.9.17+
```

**Step 3: Check BPF Filesystem**
```bash
# SSH to node or use debug pod
kubectl debug node/$NODE -it --image=ubuntu

# Check if BPF mounted
mount | grep bpf
# Should show: bpffs on /sys/fs/bpf type bpf
```

### Solutions

**Solution 1: Kernel Too Old**
```bash
# Minimum: 4.9.17
# Recommended: 5.10+

# Solution: Upgrade kernel or use different nodes
```

**Solution 2: BPF Filesystem Not Mounted**
```bash
# Mount BPF filesystem on node
mount -t bpf bpf /sys/fs/bpf

# Or add to /etc/fstab for persistence
echo "bpffs /sys/fs/bpf bpf defaults 0 0" >> /etc/fstab
```

**Solution 3: Resource Limits**
```bash
# Check resource usage
kubectl top pod -n kube-system -l k8s-app=cilium

# Increase limits if needed
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set resources.limits.memory=2Gi \
  --reuse-values
```

---

## Scenario 4: High CPU Usage

### Symptoms
- Cilium agent consuming >50% CPU
- Slow packet processing
- Increased latency

### Diagnosis Steps

**Step 1: Check Metrics**
```bash
kubectl top pods -n kube-system -l k8s-app=cilium

# Check what's consuming CPU
cilium status --verbose
```

**Step 2: Check eBPF Map Pressure**
```bash
cilium bpf ct list global | wc -l
# If close to max_entries, maps are full
```

**Step 3: Check Policy Count**
```bash
# Count policies across cluster
kubectl get cnp --all-namespaces | wc -l

# Check endpoints
kubectl get cep --all-namespaces | wc -l
```

### Solutions

**Solution 1: Increase Map Sizes**
```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set bpf.ctMax=524288 \
  --set bpf.natMax=524288 \
  --reuse-values

# Restart agents
kubectl rollout restart ds/cilium -n kube-system
```

**Solution 2: Enable Map Pressure Eviction**
```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set bpf.mapDynamicSizeRatio=0.0025 \
  --reuse-values
```

**Solution 3: Optimize Policies**
```bash
# Consolidate policies
# Use ClusterwideCiliumNetworkPolicy for common rules
# Remove unused policies
```

---

## Scenario 5: DNS Resolution Fails

### Symptoms
```bash
$ kubectl exec frontend -n demo -- nslookup backend
;; connection timed out; no servers could be reached
```

### Diagnosis Steps

**Step 1: Check CoreDNS**
```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns
# Should be Running
```

**Step 2: Test DNS from Node**
```bash
# Does host networking work?
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup google.com
```

**Step 3: Check DNS Policy**
```bash
cilium hubble observe \
  --namespace demo \
  --protocol dns \
  --verdict DROPPED
```

### Solutions

**Solution 1: Allow DNS in Network Policy**
```bash
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-dns
  namespace: demo
spec:
  endpointSelector: {}
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

**Solution 2: Fix CoreDNS**
```bash
# Restart CoreDNS
kubectl rollout restart deployment/coredns -n kube-system
```

**Solution 3: Check resolv.conf**
```bash
kubectl exec frontend -n demo -- cat /etc/resolv.conf
# Should show nameserver (usually cluster DNS IP)
```

---

## Scenario 6: Hubble Not Showing Flows

### Symptoms
- `cilium hubble observe` shows nothing
- Hubble UI empty

### Diagnosis Steps

**Step 1: Check Hubble Status**
```bash
cilium status | grep Hubble
# Should show: Hubble: Ok
```

**Step 2: Check Hubble Relay**
```bash
kubectl get pods -n kube-system -l k8s-app=hubble-relay
kubectl logs -n kube-system deployment/hubble-relay
```

**Step 3: Check Hubble Configuration**
```bash
kubectl get configmap -n kube-system cilium-config -o yaml | grep hubble
```

### Solutions

**Solution 1: Enable Hubble Metrics**
```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,http}" \
  --reuse-values
```

**Solution 2: Port Forward Issue**
```bash
# Kill existing port-forward
pkill -f "port-forward.*hubble"

# Start new one
kubectl port-forward -n kube-system svc/hubble-relay 4245:80
```

**Solution 3: Layer 7 Visibility Requires Policy**
```bash
# HTTP/DNS flows only visible with L7 policy
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: l7-visibility
  namespace: demo
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - {}
    toPorts:
    - ports:
      - port: "8080"
      rules:
        http: []
EOF
```

---

## Scenario 7: Service LoadBalancer Pending

### Symptoms
```bash
$ kubectl get svc
NAME      TYPE           EXTERNAL-IP   PORT(S)
my-app    LoadBalancer   <pending>     80:30000/TCP
```

### Diagnosis

```bash
# Check if LB IPAM is enabled
helm get values cilium -n kube-system | grep -A 5 ipam

# Check LB IP pools
kubectl get ippools
```

### Solutions

**Solution 1: Enable LB IPAM**
```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set l2announcements.enabled=true \
  --set externalIPs.enabled=true \
  --reuse-values

# Create IP pool
cat <<EOF | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: lb-pool
spec:
  cidrs:
  - cidr: "192.168.1.240/28"
EOF
```

**Solution 2: Use MetalLB**
```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.12/config/manifests/metallb-native.yaml

# Configure IP range
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 192.168.1.240-192.168.1.250
EOF
```

---

## Preventive Maintenance

### Weekly Checks
```bash
#!/bin/bash
# Weekly Cilium health check

echo "=== Cilium Agent Status ==="
kubectl get pods -n kube-system -l k8s-app=cilium

echo "=== Recent Agent Restarts ==="
kubectl get pods -n kube-system -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\n"}{end}'

echo "=== eBPF Map Pressure ==="
kubectl exec -n kube-system ds/cilium -- cilium metrics list | grep bpf_map_pressure

echo "=== Connection Tracking Entries ==="
kubectl exec -n kube-system ds/cilium -- cilium bpf ct list global | wc -l

echo "=== Policy Drop Rate ==="
cilium hubble observe --verdict DROPPED --since 24h | wc -l
```

### Monthly Tasks
- Review and cleanup unused policies
- Check for Cilium updates
- Validate backup procedures
- Review capacity metrics
- Update runbooks

---

## Additional Resources

- [Cilium Troubleshooting Guide](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [Cilium FAQ](https://docs.cilium.io/en/stable/faq/)
- [Cilium Slack #troubleshooting](https://cilium.slack.com)

---

**Remember**: Most issues are either policy misconfigurations or missing DNS policies. Start there!
