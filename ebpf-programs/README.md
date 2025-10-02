# Annotated eBPF Programs - Understanding Cilium's Core

This directory contains heavily annotated examples of the eBPF programs that power Cilium's data path. These are simplified educational versions of production code.

## Overview

Cilium uses eBPF programs attached to various kernel hooks:
- **TC (Traffic Control)**: Ingress/egress packet processing
- **XDP**: Ultra-fast packet processing at the NIC level
- **Socket**: Socket-level operations and policy enforcement
- **Tracepoints**: Observability and monitoring

## Program Examples

### 1. Basic Packet Filter (`01-basic-filter.c`)

The simplest eBPF program: allow or drop packets based on protocol.

### 2. Connection Tracking (`02-conntrack.c`)

How Cilium tracks connections using eBPF maps.

### 3. Policy Enforcement (`03-policy-enforcement.c`)

Identity-based policy decisions in the data path.

### 4. NAT (Network Address Translation) (`04-nat.c`)

Service load balancing with NAT in eBPF.

### 5. Observability Hook (`05-observability.c`)

How Hubble captures flow information.

## Compilation

To compile these examples (educational purposes):

```bash
# Install dependencies
sudo apt-get install -y clang llvm libelf-dev

# Compile
clang -O2 -target bpf -c 01-basic-filter.c -o 01-basic-filter.o
```

**Note**: These are simplified examples. Production Cilium uses more complex code generation and optimization.

## Understanding eBPF Maps

eBPF programs communicate with userspace and each other via **maps**:

```c
// Hash map example
struct bpf_map_def SEC("maps") connection_map = {
    .type = BPF_MAP_TYPE_HASH,
    .key_size = sizeof(__u64),    // Connection 4-tuple hash
    .value_size = sizeof(struct ct_entry),
    .max_entries = 1000000,
};
```

## Map Types Used by Cilium

1. **Hash Maps**: Fast lookups (policy cache, connection tracking)
2. **LRU Hash Maps**: Automatic eviction (connection tracking)
3. **Array Maps**: Per-CPU statistics
4. **LPM Trie**: CIDR-based policy (IP ranges)
5. **Tail Call Maps**: Program chaining

## Viewing Live eBPF Programs

```bash
# List all BPF programs
sudo bpftool prog list

# Show details of Cilium programs
sudo bpftool prog list | grep cilium

# Dump a specific program
sudo bpftool prog dump xlated id <ID>

# Show map contents
sudo bpftool map list
sudo bpftool map dump id <MAP_ID>
```

## Cilium-Specific Helpers

Cilium adds custom helpers beyond standard eBPF:

```c
// Send packet to Cilium agent for processing
cilium_redirect_to_proxy(skb, proxy_port);

// Drop with specific reason (for Hubble)
cilium_drop_notify(skb, DROP_POLICY_DENIED);

// Identity lookup
identity = cilium_lookup_identity(src_ip);
```

## Learning Path

1. Start with `01-basic-filter.c` - Understand structure
2. Study `02-conntrack.c` - Learn map usage
3. Review `03-policy-enforcement.c` - See identity model
4. Examine `04-nat.c` - Understand service load balancing
5. Explore `05-observability.c` - Learn Hubble integration

## Resources

- [eBPF Documentation](https://ebpf.io/)
- [Cilium eBPF Guide](https://docs.cilium.io/en/stable/concepts/ebpf/)
- [Kernel eBPF Helpers](https://man7.org/linux/man-pages/man7/bpf-helpers.7.html)
- [BPF CO-RE (Compile Once, Run Everywhere)](https://nakryiko.com/posts/bpf-portability-and-co-re/)

## Safety Notes

eBPF programs must:
- Be verifiable (pass kernel verifier)
- Have bounded loops (or use kernel 5.3+ for bounded loops)
- Not crash the kernel
- Have limited stack usage (<512 bytes)

The kernel verifier ensures safety before loading.
