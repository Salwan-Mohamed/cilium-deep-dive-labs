#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Cilium Deep Dive Labs - Kind Cluster Setup ===${NC}"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || { echo -e "${RED}Docker is required but not installed. Aborting.${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed. Aborting.${NC}" >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { echo -e "${RED}kind is required but not installed. Aborting.${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}helm is required but not installed. Aborting.${NC}" >&2; exit 1; }

echo -e "${GREEN}All prerequisites found!${NC}"
echo ""

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-cilium-lab}"
CILIUM_VERSION="${CILIUM_VERSION:-1.15.0}"
NUM_WORKERS="${NUM_WORKERS:-2}"

echo "Configuration:"
echo "  Cluster name: $CLUSTER_NAME"
echo "  Cilium version: $CILIUM_VERSION"
echo "  Worker nodes: $NUM_WORKERS"
echo ""

# Create Kind configuration
cat > /tmp/kind-config-$CLUSTER_NAME.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER_NAME
networking:
  disableDefaultCNI: true      # Disable kindnet
  kubeProxyMode: none          # Disable kube-proxy (Cilium replaces it)
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "node-role.kubernetes.io/control-plane="
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    protocol: TCP
EOF

# Add worker nodes
for i in $(seq 1 $NUM_WORKERS); do
  cat >> /tmp/kind-config-$CLUSTER_NAME.yaml <<EOF
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "node-role.kubernetes.io/worker="
EOF
done

echo "Creating Kind cluster..."
kind create cluster --config /tmp/kind-config-$CLUSTER_NAME.yaml

echo ""
echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo ""
echo -e "${GREEN}Kind cluster created successfully!${NC}"
echo ""

# Install Cilium
echo "Installing Cilium $CILIUM_VERSION..."

# Add Cilium Helm repo
helm repo add cilium https://helm.cilium.io/
helm repo update

# Install Cilium with comprehensive features
helm install cilium cilium/cilium \
  --version $CILIUM_VERSION \
  --namespace kube-system \
  --set kubeProxyReplacement=strict \
  --set k8sServiceHost=cilium-lab-control-plane \
  --set k8sServicePort=6443 \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}" \
  --set hubble.metrics.serviceMonitor.enabled=false \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set bandwidthManager.enabled=true \
  --set ipam.mode=kubernetes \
  --set debug.enabled=true \
  --set debug.verbose=flow \
  --set monitor.enabled=true

echo ""
echo "Waiting for Cilium to be ready..."
kubectl -n kube-system rollout status ds/cilium --timeout=300s
kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s

# Wait for Hubble Relay
kubectl -n kube-system rollout status deployment/hubble-relay --timeout=300s
kubectl -n kube-system rollout status deployment/hubble-ui --timeout=300s

echo ""
echo -e "${GREEN}Cilium installed successfully!${NC}"
echo ""

# Install Cilium CLI if not present
if ! command -v cilium >/dev/null 2>&1; then
  echo "Installing Cilium CLI..."
  CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/master/stable.txt)
  CLI_ARCH=amd64
  if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
  curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
  sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
  sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
  rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
  echo -e "${GREEN}Cilium CLI installed!${NC}"
fi

# Verify installation
echo ""
echo "Verifying Cilium status..."
cilium status --wait

echo ""
echo "Creating demo namespace..."
kubectl create namespace demo

# Deploy demo applications
echo "Deploying demo applications..."
kubectl apply -f - <<YAML
apiVersion: v1
kind: Service
metadata:
  name: frontend
  namespace: demo
  labels:
    app: frontend
spec:
  selector:
    app: frontend
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
        tier: frontend
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: demo
  labels:
    app: backend
spec:
  selector:
    app: backend
  ports:
  - port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
        tier: backend
    spec:
      containers:
      - name: app
        image: hashicorp/http-echo
        args:
        - "-text=Backend Response"
        ports:
        - containerPort: 8080
YAML

echo ""
echo "Waiting for demo applications..."
kubectl -n demo rollout status deployment/frontend --timeout=120s
kubectl -n demo rollout status deployment/backend --timeout=120s

echo ""
echo -e "${GREEN}=== Setup Complete! ===${NC}"
echo ""
echo "Cluster Information:"
kubectl cluster-info --context kind-$CLUSTER_NAME
echo ""
echo "Nodes:"
kubectl get nodes -o wide
echo ""
echo "Cilium Pods:"
kubectl -n kube-system get pods -l k8s-app=cilium
echo ""
echo "Demo Applications:"
kubectl -n demo get pods,svc
echo ""
echo "Useful Commands:"
echo "  View Cilium status: cilium status"
echo "  Access Hubble UI: cilium hubble ui"
echo "  View flows: cilium hubble observe --follow"
echo "  Test connectivity: cilium connectivity test"
echo ""
echo "To delete cluster: kind delete cluster --name $CLUSTER_NAME"
echo ""
echo -e "${GREEN}Ready for labs!${NC}"
