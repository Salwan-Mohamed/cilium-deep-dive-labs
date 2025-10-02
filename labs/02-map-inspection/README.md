# Lab 02: eBPF Map Inspection

## Overview

eBPF maps are the kernel data structures that store Cilium's state, configuration, and runtime information. In this lab, you'll explore the various map types Cilium uses and learn how to inspect and understand their contents.

**Duration:** 45-60 minutes  
**Difficulty:** Intermediate

## Learning Objectives

- Understand different eBPF map types (hash, array, LRU)
- Inspect endpoint maps and policy maps
- Explore service load balancing maps
- View connection tracking state
- Understand identity mappings

## Prerequisites

- Completed Lab 01
- Running cluster with Cilium installed
- Demo applications deployed

## eBPF Map Types in Cilium

Cilium uses several map types:

| Map Type | Purpose | Key Type | Value Type |
|----------|---------|----------|------------|
| **ENDPOINTS_MAP** | Pod IP → Endpoint ID | IP Address | Endpoint Info |
| **POLICY_MAP** | Policy decisions | {EP_ID, Identity} | Allow/Deny |
| **LB4_SERVICES_MAP** | Service → Backends | Service IP:Port | Backend IDs |
| **LB4_BACKEND_MAP** | Backend details | Backend ID | Pod IP:Port |
| **CT_MAP** | Connection tracking | 5-tuple | CT State |
| **IDENTITY_MAP** | Identity → Labels | Identity ID | Label Array |

## Part 1: Endpoint Maps

### Step 1: List All Endpoints

```bash
# View all Cilium endpoints
kubectl -n kube-system exec ds/cilium -- cilium bpf endpoint list

# Output shows:
# IP ADDRESS    LOCAL ENDPOINT ID   IDENTITY ID   FLAGS
# 10.0.1.50     1234                12345         [synced]
```

### Step 2: Detailed Endpoint Inspection

```bash
# Get detailed endpoint info
kubectl -n kube-system exec ds/cilium -- cilium endpoint list -o json | jq '.[] | select(.status.networking.addressing[0].ipv4 == "10.0.1.50")'

# Key fields:
# - id: Local endpoint identifier
# - identity.id: Security identity
# - status.policy: Policy enforcement status
```

## Part 2: Policy Maps

### Step 3: View Policy Map Entries

```bash
# List policies for specific endpoint
ENDPOINT_ID=$(kubectl get cep -n demo -l app=frontend -o jsonpath='{.items[0].status.id}')

kubectl -n kube-system exec ds/cilium -- cilium bpf policy get $ENDPOINT_ID
```

## Part 3: Service Load Balancing Maps

### Step 4: Service Map Inspection

```bash
# List all services
kubectl -n kube-system exec ds/cilium -- cilium service list

# Detailed service info
kubectl -n kube-system exec ds/cilium -- cilium service list --verbose
```

## Part 4: Connection Tracking

### Step 5: View Active Connections

```bash
# List all connection tracking entries
kubectl -n kube-system exec ds/cilium -- cilium bpf ct list global

# Filter for demo namespace
kubectl -n kube-system exec ds/cilium -- cilium bpf ct list global | grep "10.0."
```

## Part 5: Identity Maps

### Step 6: Identity to Label Mapping

```bash
# List all identities
kubectl -n kube-system exec ds/cilium -- cilium identity list
```

## Exercises

See `exercises.md` for hands-on challenges.

## Next Steps

Continue to Lab 03: Policy Enforcement
