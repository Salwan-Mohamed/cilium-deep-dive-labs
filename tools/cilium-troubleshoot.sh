#!/bin/bash
# Comprehensive Cilium Troubleshooting Script
# This script automates common troubleshooting workflows

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
NAMESPACE="default"
VERBOSE=false
OUTPUT_DIR="./troubleshooting-$(date +%Y%m%d-%H%M%S)"

usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    connectivity    Test pod-to-pod connectivity
    policy          Analyze network policies
    drops           Analyze dropped packets
    health          Check Cilium health
    capture         Capture packets
    diagnose        Full diagnostic report

Options:
    --namespace NS          Namespace (default: default)
    --from-pod POD         Source pod name
    --to-pod POD           Destination pod name
    --port PORT            Destination port
    --duration SECS        Duration for captures (default: 60)
    --output-dir DIR       Output directory
    --verbose              Verbose output
    -h, --help             Show this help

Examples:
    # Test connectivity
    $0 connectivity --from-pod frontend --to-pod backend --port 8080

    # Analyze policies
    $0 policy --namespace demo

    # Check drops
    $0 drops --namespace demo --from-pod frontend

    # Full diagnostic
    $0 diagnose --namespace demo
EOF
}

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    for cmd in kubectl cilium; do
        if ! command -v $cmd &>/dev/null; then
            error "$cmd is required but not found"
            exit 1
        fi
    done
}

test_connectivity() {
    local from_pod=$1
    local to_pod=$2
    local port=$3
    local namespace=$4

    log "Testing connectivity: $from_pod -> $to_pod:$port"
    
    # Get destination IP
    local dest_ip=$(kubectl get pod -n $namespace $to_pod -o jsonpath='{.status.podIP}')
    
    if [ -z "$dest_ip" ]; then
        error "Could not get IP for pod $to_pod"
        return 1
    fi
    
    log "Destination IP: $dest_ip"
    
    # Test DNS resolution
    log "Testing DNS resolution..."
    if kubectl exec -n $namespace $from_pod -- nslookup $to_pod 2>/dev/null | grep -q "Address:"; then
        log "✓ DNS resolution successful"
    else
        warn "✗ DNS resolution failed"
    fi
    
    # Test connectivity
    log "Testing TCP connection..."
    if kubectl exec -n $namespace $from_pod -- timeout 5 sh -c "echo > /dev/tcp/$dest_ip/$port" 2>/dev/null; then
        log "✓ TCP connection successful"
        
        # Show successful flow
        log "Recent successful flows:"
        cilium hubble observe \
            --namespace $namespace \
            --from-pod $namespace/$from_pod \
            --to-pod $namespace/$to_pod \
            --last 5
    else
        error "✗ TCP connection failed"
        
        # Check for drops
        log "Checking for dropped packets..."
        local drops=$(cilium hubble observe \
            --namespace $namespace \
            --from-pod $namespace/$from_pod \
            --verdict DROPPED \
            --last 10)
        
        if [ -n "$drops" ]; then
            echo "$drops"
            warn "Found dropped packets - likely policy issue"
        else
            warn "No drops found - possible routing or DNS issue"
        fi
    fi
    
    # Check policy
    log "\nPolicy trace:"
    cilium policy trace \
        --src-k8s-pod $namespace/$from_pod \
        --dst-k8s-pod $namespace/$to_pod \
        --dport $port
}

analyze_policy() {
    local namespace=$1
    
    log "Analyzing network policies in namespace: $namespace"
    
    # List policies
    log "\n=== Network Policies ==="
    kubectl get ciliumnetworkpolicies -n $namespace -o wide 2>/dev/null || log "No CiliumNetworkPolicies found"
    
    # Check endpoints
    log "\n=== Cilium Endpoints ==="
    kubectl get cep -n $namespace 2>/dev/null || log "No endpoints found"
    
    # Policy enforcement status
    log "\n=== Policy Enforcement Status ==="
    for ep in $(kubectl get cep -n $namespace -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo "Endpoint: $ep"
        kubectl get cep -n $namespace $ep -o jsonpath='{.status.policy}' 2>/dev/null | jq -r '
            "  Ingress: " + (.realized.allowed-ingress-identities // [] | join(", ")),
            "  Egress: " + (.realized.allowed-egress-identities // [] | join(", "))
        ' 2>/dev/null || echo "  Status unavailable"
        echo ""
    done
}

analyze_drops() {
    local namespace=$1
    local from_pod=$2
    local duration=${3:-5m}
    
    log "Analyzing drops in namespace: $namespace (last $duration)"
    
    local filter="--namespace $namespace --verdict DROPPED --since $duration"
    [ -n "$from_pod" ] && filter="$filter --from-pod $namespace/$from_pod"
    
    # Show drops
    log "\n=== Recent Drops ==="
    cilium hubble observe $filter --last 20
    
    # Summary by reason
    log "\n=== Drop Summary by Reason ==="
    cilium hubble observe $filter --output json 2>/dev/null | \
        jq -r 'select(.verdict == "DROPPED") | .drop_reason_desc // .drop_reason // "unknown"' | \
        sort | uniq -c | sort -rn
    
    # Summary by source
    log "\n=== Drop Summary by Source Pod ==="
    cilium hubble observe $filter --output json 2>/dev/null | \
        jq -r 'select(.verdict == "DROPPED") | .source.pod_name // "unknown"' | \
        sort | uniq -c | sort -rn | head -10
}

check_health() {
    log "Checking Cilium health..."
    
    # Cilium status
    log "\n=== Cilium Status ==="
    cilium status
    
    # Check all Cilium pods
    log "\n=== Cilium Pods ==="
    kubectl get pods -n kube-system -l k8s-app=cilium -o wide
    
    # Agent logs
    log "\n=== Recent Agent Errors ==="
    kubectl -n kube-system logs ds/cilium --tail=100 2>/dev/null | grep -i error | tail -20 || log "No recent errors"
    
    # Operator logs
    log "\n=== Recent Operator Errors ==="
    kubectl -n kube-system logs deployment/cilium-operator --tail=100 2>/dev/null | grep -i error | tail -20 || log "No recent errors"
    
    # Check connectivity
    log "\n=== Connectivity Test ==="
    cilium connectivity test --test-concurrency 1 --all-flows 2>&1 | head -50 || warn "Connectivity test failed or timed out"
}

capture_packets() {
    local pod=$1
    local namespace=$2
    local duration=${3:-60}
    local output_file="$OUTPUT_DIR/capture-$pod-$(date +%Y%m%d-%H%M%S).pcap"
    
    mkdir -p $OUTPUT_DIR
    
    log "Capturing packets from pod $pod in namespace $namespace for ${duration}s"
    log "Output file: $output_file"
    
    # Get Cilium pod on same node
    local node=$(kubectl get pod -n $namespace $pod -o jsonpath='{.spec.nodeName}')
    local cilium_pod=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}')
    
    if [ -z "$cilium_pod" ]; then
        error "Could not find Cilium pod on node $node"
        return 1
    fi
    
    # Get pod ID for filtering
    local pod_id=$(kubectl get pod -n $namespace $pod -o jsonpath='{.metadata.uid}')
    
    log "Using Cilium pod: $cilium_pod"
    
    # Capture
    kubectl -n kube-system exec $cilium_pod -- timeout $duration tcpdump -i any -w /tmp/capture.pcap 2>/dev/null &
    local capture_pid=$!
    
    log "Capturing... (PID: $capture_pid)"
    sleep $duration
    
    # Download capture
    kubectl -n kube-system cp $cilium_pod:/tmp/capture.pcap $output_file 2>/dev/null
    
    if [ -f "$output_file" ]; then
        log "✓ Capture complete: $output_file"
        log "  Analyze with: wireshark $output_file"
    else
        error "✗ Capture failed"
    fi
}

full_diagnostic() {
    local namespace=$1
    
    mkdir -p $OUTPUT_DIR
    local report="$OUTPUT_DIR/diagnostic-report.txt"
    
    log "Running full diagnostic for namespace: $namespace"
    log "Report will be saved to: $report"
    
    {
        echo "==================================="
        echo "Cilium Diagnostic Report"
        echo "Generated: $(date)"
        echo "Namespace: $namespace"
        echo "==================================="
        echo ""
        
        echo "=== Cluster Info ==="
        kubectl cluster-info
        echo ""
        
        echo "=== Node Status ==="
        kubectl get nodes -o wide
        echo ""
        
        echo "=== Cilium Status ==="
        cilium status
        echo ""
        
        echo "=== Cilium Pods ==="
        kubectl get pods -n kube-system -l k8s-app=cilium -o wide
        echo ""
        
        echo "=== Pods in Namespace ==="
        kubectl get pods -n $namespace -o wide
        echo ""
        
        echo "=== Services in Namespace ==="
        kubectl get svc -n $namespace
        echo ""
        
        echo "=== Network Policies ==="
        kubectl get cnp -n $namespace
        echo ""
        
        echo "=== Cilium Endpoints ==="
        kubectl get cep -n $namespace
        echo ""
        
        echo "=== Recent Drops ==="
        cilium hubble observe --namespace $namespace --verdict DROPPED --since 10m --last 50
        echo ""
        
        echo "=== Recent Flows ==="
        cilium hubble observe --namespace $namespace --last 100
        echo ""
        
    } > $report
    
    log "✓ Diagnostic report saved: $report"
    
    # Also save YAML dumps
    log "Saving resource dumps..."
    kubectl get cnp -n $namespace -o yaml > $OUTPUT_DIR/network-policies.yaml 2>/dev/null || true
    kubectl get cep -n $namespace -o yaml > $OUTPUT_DIR/endpoints.yaml 2>/dev/null || true
    kubectl get pods -n $namespace -o yaml > $OUTPUT_DIR/pods.yaml 2>/dev/null || true
    
    log "✓ Diagnostic complete. Files saved to: $OUTPUT_DIR"
}

# Main logic
COMMAND=$1
shift

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --from-pod)
            FROM_POD="$2"
            shift 2
            ;;
        --to-pod)
            TO_POD="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites

# Execute command
case $COMMAND in
    connectivity)
        if [ -z "$FROM_POD" ] || [ -z "$TO_POD" ] || [ -z "$PORT" ]; then
            error "connectivity requires --from-pod, --to-pod, and --port"
            usage
            exit 1
        fi
        test_connectivity "$FROM_POD" "$TO_POD" "$PORT" "$NAMESPACE"
        ;;
    policy)
        analyze_policy "$NAMESPACE"
        ;;
    drops)
        analyze_drops "$NAMESPACE" "$FROM_POD" "${DURATION:-5m}"
        ;;
    health)
        check_health
        ;;
    capture)
        if [ -z "$FROM_POD" ]; then
            error "capture requires --from-pod"
            usage
            exit 1
        fi
        capture_packets "$FROM_POD" "$NAMESPACE" "${DURATION:-60}"
        ;;
    diagnose)
        full_diagnostic "$NAMESPACE"
        ;;
    *)
        error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
