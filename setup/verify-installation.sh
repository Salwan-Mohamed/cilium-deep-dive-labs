#!/bin/bash

###############################################################################
# Cilium Deep Dive Labs - Verification Script
# 
# Verifies that the lab environment is properly configured and ready
###############################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CLUSTER_NAME="cilium-lab"

print_header() {
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_check() {
    echo -e "${BLUE}▶ $1${NC}"
}

print_success() {
    echo -e "${GREEN}  ✓ $1${NC}"
}

print_error() {
    echo -e "${RED}  ✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}  ⚠ $1${NC}"
}

# Main verification
print_header "Cilium Lab Environment Verification"
echo ""

# Check cluster
print_check "Checking Kubernetes cluster..."
if kubectl cluster-info &>/dev/null; then
    print_success "Cluster is accessible"
    kubectl get nodes
else
    print_error "Cannot access cluster"
    exit 1
fi
echo ""

# Check Cilium
print_check "Checking Cilium installation..."
if kubectl -n kube-system get daemonset cilium &>/dev/null; then
    print_success "Cilium daemonset found"
    
    DESIRED=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.desiredNumberScheduled}')
    READY=$(kubectl -n kube-system get daemonset cilium -o jsonpath='{.status.numberReady}')
    
    if [ "$DESIRED" = "$READY" ]; then
        print_success "All Cilium pods ready ($READY/$DESIRED)"
    else
        print_warning "Cilium pods not fully ready ($READY/$DESIRED)"
    fi
else
    print_error "Cilium not found"
    exit 1
fi
echo ""

# Check Hubble
print_check "Checking Hubble components..."
if kubectl -n kube-system get deployment hubble-relay &>/dev/null; then
    print_success "Hubble Relay found"
else
    print_warning "Hubble Relay not found"
fi

if kubectl -n kube-system get deployment hubble-ui &>/dev/null; then
    print_success "Hubble UI found"
else
    print_warning "Hubble UI not found"
fi
echo ""

# Check demo namespace
print_check "Checking demo applications..."
if kubectl get namespace demo &>/dev/null; then
    print_success "Demo namespace exists"
    
    PODS=$(kubectl -n demo get pods --no-headers 2>/dev/null | wc -l)
    RUNNING=$(kubectl -n demo get pods --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    
    print_success "Demo pods: $RUNNING/$PODS running"
else
    print_warning "Demo namespace not found"
fi
echo ""

# Connectivity test
print_check "Testing Cilium connectivity..."
if command -v cilium &>/dev/null; then
    cilium connectivity test --test=pod-to-pod --test=pod-to-service 2>/dev/null || print_warning "Some connectivity tests failed"
else
    print_warning "Cilium CLI not installed - skipping connectivity test"
    print_warning "Install from: https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/#install-the-cilium-cli"
fi
echo ""

# Summary
print_header "Verification Summary"
echo ""
echo "Your lab environment is ready!"
echo ""
echo "Next steps:"
echo "  1. Explore Hubble UI: kubectl port-forward -n kube-system svc/hubble-ui 12000:80"
echo "  2. Start Lab 01: cd labs/01-packet-flow && cat README.md"
echo "  3. View Cilium status: kubectl -n kube-system exec ds/cilium -- cilium status"
echo ""
