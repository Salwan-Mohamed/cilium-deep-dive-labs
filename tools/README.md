# Packet Capture and Analysis Tools

## Overview

This directory contains tools for capturing and analyzing network traffic in Cilium-enabled clusters. These tools help troubleshoot connectivity issues, verify policy enforcement, and understand data plane behavior.

## Tools Included

1. **cilium-pcap.sh** - Capture packets from Cilium interfaces
2. **analyze-drops.sh** - Analyze dropped packets
3. **flow-analyzer.py** - Parse and visualize Hubble flows
4. **policy-tester.sh** - Test network policies

## Quick Start

```bash
# Make scripts executable
chmod +x tools/*.sh

# Capture traffic on a specific pod
./tools/cilium-pcap.sh --pod frontend --namespace demo --duration 30

# Analyze recent drops
./tools/analyze-drops.sh --namespace demo --since 5m

# Test policy connectivity
./tools/policy-tester.sh --from demo/frontend --to demo/backend --port 8080
```

## Tool Documentation

### 1. cilium-pcap.sh

Captures packet traces from Cilium's data path.

**Usage**:
```bash
./cilium-pcap.sh [OPTIONS]

Options:
  --pod NAME          Pod name to capture from (required)
  --namespace NS      Namespace (default: default)
  --duration SECS     Capture duration in seconds (default: 60)
  --interface TYPE    Interface type: any, cilium_host, cilium_net (default: any)
  --output FILE       Output pcap file (default: capture-TIMESTAMP.pcap)
  --filter FILTER     BPF filter expression
```

**Examples**:
```bash
# Capture all traffic from frontend pod for 30 seconds
./cilium-pcap.sh --pod frontend --namespace demo --duration 30

# Capture only HTTP traffic (port 80)
./cilium-pcap.sh --pod backend --filter "port 80"

# Capture from specific interface
./cilium-pcap.sh --pod frontend --interface cilium_host
```

**Output**:
- Creates `.pcap` file
- Can be opened in Wireshark
- Shows actual packets in data path

### 2. analyze-drops.sh

Analyzes dropped packets using Hubble and cilium monitor.

**Usage**:
```bash
./analyze-drops.sh [OPTIONS]

Options:
  --namespace NS      Namespace to analyze
  --since DURATION    Time range (e.g., 5m, 1h, 24h)
  --reason REASON     Filter by drop reason
  --summary           Show summary only
  --detail            Show detailed analysis
```

**Examples**:
```bash
# Show all drops in demo namespace in last 5 minutes
./analyze-drops.sh --namespace demo --since 5m

# Analyze policy denials
./analyze-drops.sh --reason "Policy denied" --detail

# Get drop summary
./analyze-drops.sh --namespace prod --summary
```

**Output**:
```
=== Drop Analysis Report ===
Time Range: Last 5 minutes
Namespace: demo

Total Drops: 42

Drop Reasons:
  Policy denied: 38 (90%)
  Invalid source: 3 (7%)
  CT entry invalid: 1 (3%)

Top Source Pods:
  frontend-xyz: 30 drops
  crawler-abc: 8 drops

Top Destinations:
  backend:8080: 25 drops
  database:5432: 13 drops

Recommendation:
  Check network policies for frontend -> backend:8080
```

### 3. flow-analyzer.py

Python tool for advanced Hubble flow analysis.

**Installation**:
```bash
pip install -r tools/requirements.txt
```

**Usage**:
```bash
python3 tools/flow-analyzer.py [OPTIONS]

Options:
  --input FILE        Read from Hubble JSON export
  --live              Stream live flows
  --namespace NS      Filter by namespace
  --visualize         Create network graph
  --export FORMAT     Export format: json, csv, html
```

**Examples**:
```bash
# Export flows to JSON
cilium hubble observe --namespace demo --output jsonpb > flows.json

# Analyze flows
python3 tools/flow-analyzer.py --input flows.json --visualize

# Live analysis with visualization
python3 tools/flow-analyzer.py --live --namespace demo --visualize

# Export to CSV for Excel
python3 tools/flow-analyzer.py --input flows.json --export csv
```

**Features**:
- Network topology visualization
- Traffic pattern analysis
- Latency percentiles
- Error rate calculation
- Interactive HTML reports

### 4. policy-tester.sh

Test connectivity between pods considering network policies.

**Usage**:
```bash
./policy-tester.sh [OPTIONS]

Options:
  --from POD          Source pod (format: namespace/pod)
  --to POD            Destination pod (format: namespace/pod)
  --port PORT         Destination port
  --protocol PROTO    Protocol: tcp, udp, icmp (default: tcp)
  --verbose           Show detailed output
```

**Examples**:
```bash
# Test TCP connectivity
./policy-tester.sh \
  --from demo/frontend \
  --to demo/backend \
  --port 8080

# Test with verbose output
./policy-tester.sh \
  --from demo/frontend \
  --to demo/backend \
  --port 8080 \
  --verbose

# Test UDP connectivity
./policy-tester.sh \
  --from demo/app \
  --to kube-system/kube-dns \
  --port 53 \
  --protocol udp
```

**Output**:
```
Testing connectivity: demo/frontend -> demo/backend:8080

✓ DNS resolution: backend.demo.svc.cluster.local -> 10.0.2.100
✓ Policy check: ALLOWED (matched policy: allow-frontend-to-backend)
✓ TCP connection: SUCCESS (latency: 2.3ms)
✓ Hubble flow: FORWARDED

Result: CONNECTION SUCCESSFUL
```

## Advanced Techniques

### Capturing at Different Layers

**Layer 2 (Ethernet)**:
```bash
# Capture from physical interface
kubectl -n kube-system exec -it ds/cilium -- \
  tcpdump -i eth0 -w /tmp/eth0.pcap

# Download
kubectl -n kube-system cp \
  cilium-xxxxx:/tmp/eth0.pcap \
  eth0.pcap
```

**Layer 3 (IP)**:
```bash
# Capture from cilium_host (host-facing)
kubectl -n kube-system exec -it ds/cilium -- \
  tcpdump -i cilium_host -w /tmp/host.pcap

# Capture from cilium_net (container-facing)
kubectl -n kube-system exec -it ds/cilium -- \
  tcpdump -i cilium_net -w /tmp/net.pcap
```

### Using cilium monitor

Real-time event monitoring:

```bash
# Monitor all events
cilium monitor

# Filter by event type
cilium monitor --type drop         # Only drops
cilium monitor --type trace        # Only traces
cilium monitor --type policy-verdict  # Only policy decisions

# Filter by pod
cilium monitor --related-to demo:frontend

# Show detailed output
cilium monitor -v
```

### BPF Filter Examples

**Capture HTTP traffic**:
```bash
tcpdump -i any 'tcp port 80 or tcp port 8080'
```

**Capture to specific IP**:
```bash
tcpdump -i any 'dst host 10.0.2.100'
```

**Capture DNS**:
```bash
tcpdump -i any 'udp port 53'
```

**Capture SYN packets only**:
```bash
tcpdump -i any 'tcp[tcpflags] & tcp-syn != 0'
```

## Wireshark Analysis

After capturing packets, analyze with Wireshark:

**Install Wireshark**:
```bash
# macOS
brew install --cask wireshark

# Ubuntu
sudo apt-get install wireshark
```

**Open Capture**:
```bash
wireshark capture.pcap
```

**Useful Filters**:
```
# Show only HTTP
http

# Show TCP retransmissions
tcp.analysis.retransmission

# Show packets to specific port
tcp.dstport == 8080

# Show packets with specific TTL
ip.ttl == 64

# Show ICMP
icmp
```

## Troubleshooting Scenarios

### Scenario 1: Connection Timeout

```bash
# 1. Capture traffic
./cilium-pcap.sh --pod frontend --duration 60 &

# 2. Reproduce issue
kubectl exec -n demo frontend -- curl --max-time 5 backend:8080

# 3. Analyze capture in Wireshark
# Look for:
# - TCP SYN sent?
# - TCP SYN-ACK received?
# - TCP RST received? (connection refused)
# - No response? (firewall/policy drop)
```

### Scenario 2: High Latency

```bash
# 1. Capture with timestamp
./cilium-pcap.sh --pod backend --duration 120

# 2. In Wireshark:
# Statistics -> TCP Stream Graphs -> Round Trip Time
# Look for:
# - High RTT values
# - Retransmissions
# - Window size issues
```

### Scenario 3: Policy Drops

```bash
# 1. Check drops
./analyze-drops.sh --namespace demo --detail

# 2. Verify with monitor
cilium monitor --type drop --related-to demo:frontend

# 3. Test policy
cilium policy trace \
  --src-k8s-pod demo/frontend \
  --dst-k8s-pod demo/backend \
  --dport 8080
```

## Performance Impact

Packet capture has minimal impact:
- **tcpdump**: <1% CPU overhead
- **cilium monitor**: <0.5% CPU overhead
- **Hubble**: <1% CPU overhead (always running)

For production:
- Limit capture duration
- Use specific BPF filters
- Capture on specific interfaces only

## Tips and Best Practices

1. **Start with Hubble**: Check flows before packet capture
2. **Use filters**: Don't capture everything
3. **Know your interfaces**: cilium_host vs cilium_net vs eth0
4. **Time-box captures**: Don't leave running indefinitely
5. **Correlate with logs**: Check Cilium agent logs simultaneously

## Additional Resources

- [tcpdump Tutorial](https://danielmiessler.com/study/tcpdump/)
- [Wireshark User Guide](https://www.wireshark.org/docs/wsug_html_chunked/)
- [BPF Filter Syntax](https://biot.com/capstats/bpf.html)
- [Cilium Monitoring](https://docs.cilium.io/en/stable/operations/troubleshooting/)

---

**Master packet analysis = Master troubleshooting**
