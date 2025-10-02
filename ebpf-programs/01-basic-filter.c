// SPDX-License-Identifier: GPL-2.0
/* Copyright (C) 2024 - Educational Example
 *
 * Basic Packet Filter - Educational eBPF Program
 * 
 * This is a simplified version of Cilium's packet filtering logic.
 * It demonstrates the core concepts without production complexity.
 *
 * LEARNING OBJECTIVES:
 * 1. Understand eBPF program structure
 * 2. Learn packet parsing
 * 3. See how decisions are made in data path
 * 4. Understand return codes (TC_ACT_OK vs TC_ACT_SHOT)
 */

#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/icmp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

/*
 * SECTION 1: MAP DEFINITIONS
 * 
 * Maps are how eBPF programs share data with userspace and each other.
 * Think of them as kernel-space hash tables.
 */

// Statistics map: Count packets by protocol
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 256);  // One counter per IP protocol
    __type(key, __u32);
    __type(value, __u64);
} stats_map SEC(".maps");

// Allowed protocols map: Which protocols to allow
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10);
    __type(key, __u8);     // Protocol number (6=TCP, 17=UDP, etc.)
    __type(value, __u8);   // 1=allow, 0=deny
} allowed_protocols SEC(".maps");

/*
 * SECTION 2: HELPER FUNCTIONS
 * 
 * These parse the packet and extract useful information.
 */

// Check if we can safely read 'size' bytes starting at 'ptr'
static __always_inline bool
can_read(void *ptr, void *data_end, __u32 size)
{
    // This check is REQUIRED by the eBPF verifier
    // It ensures we never read past the packet boundary
    return ptr + size <= data_end;
}

// Parse Ethernet header and return next protocol
static __always_inline __u16
parse_eth(struct __sk_buff *skb, void **l3_hdr)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;
    struct ethhdr *eth = data;

    // VERIFIER CHECK: Can we read Ethernet header?
    if (!can_read(eth, data_end, sizeof(*eth)))
        return 0;

    // Point to next header (IP)
    *l3_hdr = data + sizeof(*eth);
    
    // Return EtherType (0x0800 = IPv4, 0x86DD = IPv6)
    return bpf_ntohs(eth->h_proto);
}

/*
 * SECTION 3: MAIN PROGRAM
 * 
 * This is the entry point called for every packet.
 * Attached to TC (Traffic Control) ingress/egress.
 */

SEC("tc")
int packet_filter(struct __sk_buff *skb)
{
    void *data_end = (void *)(long)skb->data_end;
    void *l3_hdr = NULL;
    __u16 eth_proto;
    __u8 ip_proto = 0;
    
    /* STEP 1: Parse Ethernet header */
    eth_proto = parse_eth(skb, &l3_hdr);
    
    // Only handle IPv4 for this example
    if (eth_proto != ETH_P_IP)
        return TC_ACT_OK;  // Pass non-IPv4 traffic
    
    /* STEP 2: Parse IP header */
    struct iphdr *ip = l3_hdr;
    
    // VERIFIER CHECK: Can we read IP header?
    if (!can_read(ip, data_end, sizeof(*ip)))
        return TC_ACT_OK;
    
    // Extract protocol (TCP=6, UDP=17, ICMP=1)
    ip_proto = ip->protocol;
    
    /* STEP 3: Update statistics */
    __u32 stats_key = ip_proto;
    __u64 *count = bpf_map_lookup_elem(&stats_map, &stats_key);
    if (count) {
        // Atomic increment (safe for concurrency)
        __sync_fetch_and_add(count, 1);
    } else {
        // Initialize counter
        __u64 initial = 1;
        bpf_map_update_elem(&stats_map, &stats_key, &initial, BPF_ANY);
    }
    
    /* STEP 4: Check if protocol is allowed */
    __u8 *allowed = bpf_map_lookup_elem(&allowed_protocols, &ip_proto);
    
    if (!allowed) {
        // Protocol not in map = default allow
        return TC_ACT_OK;
    }
    
    if (*allowed == 0) {
        // Protocol explicitly denied
        // In production, Cilium would call drop_notify() here for Hubble
        return TC_ACT_SHOT;  // DROP packet
    }
    
    /* STEP 5: Protocol-specific inspection */
    void *l4_hdr = l3_hdr + (ip->ihl * 4);  // IP header length is variable
    
    switch (ip_proto) {
    case IPPROTO_TCP: {
        struct tcphdr *tcp = l4_hdr;
        if (!can_read(tcp, data_end, sizeof(*tcp)))
            break;
        
        // Example: Block port 23 (Telnet)
        __u16 dport = bpf_ntohs(tcp->dest);
        if (dport == 23) {
            return TC_ACT_SHOT;  // DROP
        }
        break;
    }
    
    case IPPROTO_UDP: {
        struct udphdr *udp = l4_hdr;
        if (!can_read(udp, data_end, sizeof(*udp)))
            break;
        
        // Example: Always allow DNS (port 53)
        __u16 dport = bpf_ntohs(udp->dest);
        if (dport == 53) {
            return TC_ACT_OK;  // ALLOW
        }
        break;
    }
    
    case IPPROTO_ICMP: {
        // Example: Always allow ICMP (ping)
        return TC_ACT_OK;
    }
    }
    
    /* STEP 6: Default action */
    return TC_ACT_OK;  // ALLOW by default
}

/*
 * UNDERSTANDING THE CODE:
 * 
 * 1. SEC("tc"): This tells the loader where to attach (TC = Traffic Control)
 * 2. struct __sk_buff *skb: The packet we're processing
 * 3. TC_ACT_OK: Continue processing (allow packet)
 * 4. TC_ACT_SHOT: Drop packet immediately
 * 
 * CILIUM'S ACTUAL IMPLEMENTATION:
 * - Much more complex policy evaluation
 * - Connection tracking integration
 * - Identity-based decisions
 * - Metrics and observability hooks
 * - NAT and load balancing
 * - Encryption support
 * 
 * But the core principle is the same:
 * 1. Parse packet headers
 * 2. Look up policy in maps
 * 3. Make allow/deny decision
 * 4. Return action code
 * 
 * COMPILING THIS PROGRAM:
 * 
 * clang -O2 -g -target bpf \
 *   -c 01-basic-filter.c \
 *   -o 01-basic-filter.o
 * 
 * LOADING WITH TC:
 * 
 * tc qdisc add dev eth0 clsact
 * tc filter add dev eth0 ingress bpf da obj 01-basic-filter.o sec tc
 * 
 * VIEWING STATISTICS:
 * 
 * bpftool map dump name stats_map
 * 
 * NOTES:
 * - eBPF verifier ensures this code is safe
 * - Can't have unbounded loops
 * - Can't crash the kernel
 * - All memory accesses must be verified
 * - Stack limited to 512 bytes
 */

char _license[] SEC("license") = "GPL";
