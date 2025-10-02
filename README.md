# Cilium Deep Dive Labs

<div align="center">
  <img src="https://cilium.io/static/logo-4fd1c31bb9ae.svg" alt="Cilium Logo" width="300"/>
  
  [![Cilium](https://img.shields.io/badge/Cilium-1.15+-blue.svg)](https://cilium.io/)
  [![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
  [![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)
</div>

## 📖 About This Repository

This repository contains comprehensive hands-on labs and code examples for understanding **Cilium's eBPF-powered networking**. It serves as the companion repository for the technical deep dive article series.

## 🎯 What You'll Learn

- ✅ **Packet Flow Analysis**: Trace network packets through Cilium's eBPF data path
- ✅ **Identity Architecture**: Understand how Cilium implements identity-based security
- ✅ **eBPF Maps**: Inspect and manipulate kernel data structures
- ✅ **Policy Enforcement**: From Kubernetes YAML to kernel-level packet decisions
- ✅ **Observability Internals**: How Hubble captures events without packet capture
- ✅ **Advanced Features**: XDP, encryption, DSR, and performance optimization
- ✅ **Troubleshooting**: Debug connectivity issues and policy problems

## 🚀 Quick Start

### Prerequisites

- Linux machine or VM (Ubuntu 20.04+ or similar)
- Docker 20.10+
- kubectl 1.26+
- Kind 0.20+ or similar Kubernetes cluster tool
- 4GB RAM minimum (8GB recommended)
- Basic understanding of Kubernetes concepts

### Setup Your Lab Environment

```bash
# Clone the repository
git clone https://github.com/Salwan-Mohamed/cilium-deep-dive-labs.git
cd cilium-deep-dive-labs

# Run the automated setup
./setup/complete-setup.sh

# Verify installation
./setup/verify-installation.sh
```

This will:
1. Create a Kind Kubernetes cluster
2. Install Cilium with Hubble enabled
3. Deploy demo applications
4. Verify all components are running

## 📚 Lab Structure

### [Lab 01: Packet Flow Analysis](labs/01-packet-flow/)
Trace a packet's journey through Cilium's data path from application to network and back.

**Topics Covered:**
- Socket-level hooks
- TC egress/ingress processing
- VxLAN encapsulation
- Policy enforcement points
- Connection tracking

**Duration:** 30-45 minutes

### [Lab 02: eBPF Map Inspection](labs/02-map-inspection/)
Explore the kernel data structures that power Cilium.

**Topics Covered:**
- Endpoint maps
- Policy maps
- Service load balancing maps
- Connection tracking maps
- Identity maps

**Duration:** 45-60 minutes

### [Lab 03: Policy Enforcement](labs/03-policy-enforcement/)
Understand how Kubernetes NetworkPolicies become kernel-level enforcement.

**Topics Covered:**
- L3/L4 network policies
- L7 (HTTP, DNS, Kafka) policies
- FQDN-based policies
- Policy troubleshooting
- Audit mode

**Duration:** 60-90 minutes

### [Lab 04: Observability Internals](labs/04-observability-internals/)
Dive deep into Hubble's event generation and streaming.

**Topics Covered:**
- Event generation points
- Perf ring buffers
- Flow filtering
- Custom metrics
- Grafana dashboards

**Duration:** 45-60 minutes

### [Lab 05: Advanced Topics](labs/05-advanced-topics/)
Explore advanced Cilium features and optimizations.

**Topics Covered:**
- XDP acceleration
- WireGuard encryption
- Direct Server Return (DSR)
- BPF Host Routing
- Multi-cluster with Cluster Mesh

**Duration:** 90-120 minutes

## 🔧 Tools and Utilities

### [Packet Tracer](tools/packet-tracer.py)
Visualize packet flow through Cilium components.

```bash
python3 tools/packet-tracer.py --src frontend-pod --dst backend-pod
```

### [Policy Simulator](tools/policy-simulator.py)
Test network policies before applying them.

```bash
python3 tools/policy-simulator.py --policy my-policy.yaml --simulate
```

### [Performance Analyzer](tools/performance-analyzer.sh)
Benchmark Cilium performance in your environment.

```bash
./tools/performance-analyzer.sh --test latency,throughput
```

## 📝 eBPF Program Examples

The [ebpf-programs/](ebpf-programs/) directory contains annotated eBPF programs that demonstrate core Cilium concepts:

- **simple-drop.c**: Basic packet filtering
- **identity-extractor.c**: Extract security identities from packets
- **custom-parser.c**: Parse custom protocols
- **connection-tracker.c**: Implement stateful connection tracking
- **load-balancer.c**: Simple L4 load balancer

Each program includes:
- Detailed inline comments
- Compilation instructions
- Loading and testing procedures
- Expected output examples

## 🐛 Troubleshooting

Common issues and solutions are documented in:
- [Common Issues Guide](troubleshooting/common-issues.md)
- [Debug Scenarios](troubleshooting/debug-scenarios/)
- [Diagnostic Scripts](troubleshooting/diagnostic-scripts/)

### Quick Diagnostics

```bash
# Check Cilium status
kubectl -n kube-system exec ds/cilium -- cilium status

# View real-time events
kubectl -n kube-system exec ds/cilium -- hubble observe

# Check connectivity
kubectl -n kube-system exec ds/cilium -- cilium connectivity test
```

## 🌟 Features

- ✨ **Complete Lab Environment**: Automated setup with Kind clusters
- 📊 **Visual Learning**: Architecture diagrams and flow visualizations
- 🔍 **Deep Inspection**: Tools to explore eBPF maps and programs
- 🎓 **Progressive Learning**: Labs build on each other from basics to advanced
- 🧪 **Hands-On Exercises**: Real scenarios with step-by-step instructions
- 🛠️ **Production-Ready**: Examples based on real-world deployments
- 📈 **Performance Testing**: Benchmarking tools and best practices

## 🤝 Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Ways to Contribute:
- 🐛 Report bugs or issues
- 💡 Suggest new labs or improvements
- 📝 Improve documentation
- 🔧 Submit bug fixes or enhancements
- 🌍 Translate content

## 📖 Additional Resources

### Official Documentation
- [Cilium Documentation](https://docs.cilium.io)
- [eBPF Documentation](https://ebpf.io)
- [Cilium GitHub](https://github.com/cilium/cilium)

### Community
- [Cilium Slack](https://cilium.io/slack)
- [eCHO Office Hours](https://github.com/cilium/cilium/wiki/eCHO-Office-Hours) - Weekly livestream
- [Cilium Newsletter](https://cilium.io/newsletter)

### Books and Courses
- [Learning eBPF](https://www.oreilly.com/library/view/learning-ebpf/9781098135119/) by Liz Rice
- [Isovalent Labs](https://isovalent.com/labs) - Interactive tutorials

### Conference Talks
- [DockerCon 2017 - Cilium Introduction](https://www.youtube.com/watch?v=ilKlmTDdFgk)
- [KubeCon Cilium Talks](https://www.youtube.com/playlist?list=PLj6h78yzYM2O1wlsM-Ma-RYhfT5LKq0XC)

## 📜 License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- The Cilium team for building amazing technology
- The eBPF community for kernel innovations
- All contributors to this educational project

## 📧 Contact

For questions or feedback:
- Open an [Issue](https://github.com/Salwan-Mohamed/cilium-deep-dive-labs/issues)
- Join the discussion on [Cilium Slack](https://cilium.io/slack)

---

<div align="center">
  Made with ❤️ for the Cloud Native community
  
  **Star ⭐ this repository if you find it helpful!**
</div>
