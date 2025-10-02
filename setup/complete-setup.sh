#!/bin/bash

###############################################################################
# Cilium Deep Dive Labs - Complete Setup Script
# 
# This script automates the complete lab environment setup:
# - Creates a Kind Kubernetes cluster
# - Installs Cilium with Hubble
# - Deploys demo applications
# - Verifies all components
#
# Usage: ./complete-setup.sh
###############################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
CLUSTER_NAME="cilium-lab"
CILIUM_VERSION="1.15.0"
KUBECTL_WAIT_TIMEOUT="300s"

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Cilium Deep Dive Labs - Environment Setup              ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function definitions
print_section() {
    echo ""
    echo -e "${BLUE}▶ $1${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_section "Checking Prerequisites"
    
    local missing_tools=()
    
    if ! command -v docker &> /dev/null; then
        missing_tools+=("docker")
    else
        print_success "Docker found: $(docker --version | head -n1)"
    fi
    
    if ! command -v kubectl &> /dev/null; then
        missing_tools+=("kubectl")
    else
        print_success "kubectl found"
    fi
    
    if ! command -v kind &> /dev/null; then
        missing_tools+=("kind")
    else
        print_success "Kind found: $(kind version)"
    fi
    
    if ! command -v helm &> /dev/null; then
        missing_tools+=("helm")
    else
        print_success "Helm found"
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        exit 1
    fi
    
    print_success "All prerequisites installed"
}

# Create Kind cluster
create_kind_cluster() {
    print_section "Creating Kind Kubernetes Cluster"
    
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        print_warning "Cluster exists. Delete and recreate? (y/N)"
        read -r REPLY
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            kind delete cluster --name "${CLUSTER_NAME}"
        else
            return 0
        fi
    fi
    
    cat > /tmp/kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: true
  kubeProxyMode: none
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
EOF
    
    kind create cluster --config /tmp/kind-config.yaml
    print_success "Kind cluster created"
    
    kubectl wait --for=condition=Ready nodes --all --timeout=${KUBECTL_WAIT_TIMEOUT}
    rm /tmp/kind-config.yaml
}

# Install Cilium
install_cilium() {
    print_section "Installing Cilium"
    
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm repo update
    
    helm install cilium cilium/cilium \
        --version ${CILIUM_VERSION} \
        --namespace kube-system \
        --set kubeProxyReplacement=strict \
        --set hubble.relay.enabled=true \
        --set hubble.ui.enabled=true \
        --wait
    
    print_success "Cilium installed"
}

# Deploy demo apps
deploy_demo_apps() {
    print_section "Deploying Demo Applications"
    
    kubectl create namespace demo 2>/dev/null || true
    
    kubectl apply -n demo -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: frontend
spec:
  selector:
    app: frontend
  ports:
  - port: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
EOF
    
    print_success "Demo apps deployed"
}

# Main execution
main() {
    check_prerequisites
    create_kind_cluster
    install_cilium
    deploy_demo_apps
    
    print_section "Setup Complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify installation: ./setup/verify-installation.sh"
    echo "  2. Start Lab 01: cd labs/01-packet-flow"
    echo ""
}

main
