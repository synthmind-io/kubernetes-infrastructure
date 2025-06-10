#!/bin/bash
# scripts/init-management-cluster.sh

set -euo pipefail

# Source environment variables
source .envrc || { echo "Please create .envrc file first"; exit 1; }

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Initializing Management Cluster${NC}"

# Check for required tools
command -v kind >/dev/null 2>&1 || { echo -e "${RED}kind is required but not installed. Please install it first.${NC}" >&2; exit 1; }
command -v clusterctl >/dev/null 2>&1 || { echo -e "${RED}clusterctl is required but not installed. Please install it first.${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed. Please install it first.${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}helm is required but not installed. Please install it first.${NC}" >&2; exit 1; }

# Function to wait for condition
wait_for_condition() {
    local namespace=$1
    local resource=$2
    local condition=$3
    local timeout=${4:-300}
    
    echo -e "${YELLOW}Waiting for $resource in $namespace to be $condition...${NC}"
    kubectl wait --for=condition=$condition $resource -n $namespace --timeout=${timeout}s
}

# Check if management cluster already exists
if kubectl config get-contexts | grep -q "management-admin@management"; then
    echo -e "${YELLOW}Management cluster context already exists. Checking cluster status...${NC}"
    kubectl --context=management-admin@management get nodes || {
        echo -e "${RED}Management cluster context exists but cluster is not accessible${NC}"
        exit 1
    }
    echo -e "${GREEN}Management cluster is already running${NC}"
    exit 0
fi

# Check if we're already in a CAPI-enabled cluster
if kubectl get namespace capi-system &>/dev/null && kubectl get deployment -n capi-system capi-controller-manager &>/dev/null; then
    echo -e "${YELLOW}CAPI is already initialized in current cluster. Using existing cluster as bootstrap...${NC}"
    BOOTSTRAP_CLUSTER_CONTEXT=$(kubectl config current-context)
else
    # Create a local kind cluster for bootstrapping
    echo -e "${BLUE}Creating local kind cluster for bootstrapping...${NC}"
    
    # Check if kind cluster already exists
    if kind get clusters 2>/dev/null | grep -q "capi-bootstrap"; then
        echo -e "${YELLOW}Bootstrap cluster already exists, using it...${NC}"
    else
        echo -e "${BLUE}Creating new bootstrap cluster...${NC}"
        cat <<EOF | kind create cluster --name capi-bootstrap --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:v1.31.4
EOF
    fi
    
    # Switch to the bootstrap cluster context
    kubectl config use-context kind-capi-bootstrap
    BOOTSTRAP_CLUSTER_CONTEXT="kind-capi-bootstrap"
    
    # Initialize Cluster API on bootstrap cluster
    echo -e "${BLUE}Initializing Cluster API providers on bootstrap cluster...${NC}"
    clusterctl init \
        --core cluster-api:v1.7.0 \
        --bootstrap kubeadm:v1.7.0 \
        --control-plane kubeadm:v1.7.0 \
        --infrastructure hetzner:v1.0.1 \
        --config clusterctl-config.yaml
fi

# Wait for CAPI controllers to be ready
echo -e "${BLUE}Waiting for CAPI controllers...${NC}"
wait_for_condition capi-system deployment/capi-controller-manager ready
wait_for_condition capi-kubeadm-bootstrap-system deployment/capi-kubeadm-bootstrap-controller-manager ready
wait_for_condition capi-kubeadm-control-plane-system deployment/capi-kubeadm-control-plane-controller-manager ready
wait_for_condition caph-system deployment/caph-controller-manager ready

# Create Hetzner secret
echo -e "${BLUE}Creating Hetzner credentials secret...${NC}"
kubectl create secret generic hetzner \
    --from-literal=hcloud=${HCLOUD_TOKEN} \
    --namespace default \
    --dry-run=client -o yaml | kubectl apply -f -

# Add robot credentials if available
if [[ -n "${HETZNER_ROBOT_USER:-}" ]] && [[ -n "${HETZNER_ROBOT_PASSWORD:-}" ]]; then
    kubectl patch secret hetzner -n default --type merge -p \
        "{\"data\":{\"robot-user\":\"$(echo -n ${HETZNER_ROBOT_USER} | base64 -w0)\",\"robot-password\":\"$(echo -n ${HETZNER_ROBOT_PASSWORD} | base64 -w0)\"}}"
fi

# Label the secret for CAPI move
kubectl label secret hetzner -n default clusterctl.cluster.x-k8s.io/move="" --overwrite

# Scale CAPI controllers for HA
echo -e "${BLUE}Scaling CAPI controllers for HA...${NC}"
kubectl -n capi-system scale deployment capi-controller-manager --replicas=2
kubectl -n capi-kubeadm-bootstrap-system scale deployment capi-kubeadm-bootstrap-controller-manager --replicas=2
kubectl -n capi-kubeadm-control-plane-system scale deployment capi-kubeadm-control-plane-controller-manager --replicas=2
kubectl -n caph-system scale deployment caph-controller-manager --replicas=2

# Apply management cluster configuration
echo -e "${BLUE}Creating management cluster...${NC}"

# Check if cluster manifests exist
REQUIRED_MANIFESTS=(
    "clusters/management/cluster.yaml"
    "clusters/management/control-plane.yaml"
    "clusters/management/workers.yaml"
)

missing_manifests=()
for manifest in "${REQUIRED_MANIFESTS[@]}"; do
    if [[ ! -f "$manifest" ]]; then
        missing_manifests+=("$manifest")
    fi
done

if [[ ${#missing_manifests[@]} -gt 0 ]]; then
    echo -e "${RED}Error: Required cluster manifests not found:${NC}"
    for manifest in "${missing_manifests[@]}"; do
        echo -e "${RED}  - $manifest${NC}"
    done
    echo -e "${YELLOW}Please ensure you have:${NC}"
    echo -e "${YELLOW}1. Run 'make github' to create and populate the repository${NC}"
    echo -e "${YELLOW}2. The cluster manifests are in the clusters/management/ directory${NC}"
    echo -e "${YELLOW}3. Or create them using: clusterctl generate cluster management --flavor hetzner${NC}"
    exit 1
fi

# First, process the cluster YAML to replace environment variables
envsubst < clusters/management/cluster.yaml | kubectl apply -f -
envsubst < clusters/management/control-plane.yaml | kubectl apply -f -
envsubst < clusters/management/workers.yaml | kubectl apply -f -

# Wait for cluster to be ready
echo -e "${BLUE}Waiting for management cluster to be provisioned...${NC}"
echo -e "${YELLOW}This can take 10-15 minutes...${NC}"

# Wait for HetznerCluster to be ready
kubectl wait --for=condition=ready hetznercluster/management -n default --timeout=900s

# Wait for control plane to be initialized
kubectl wait --for=condition=ControlPlaneInitialized cluster/management -n default --timeout=900s

# Wait for control plane to be ready
kubectl wait --for=condition=ready kubeadmcontrolplane/management-control-plane -n default --timeout=900s

# Get kubeconfig for management cluster
echo -e "${BLUE}Getting kubeconfig for management cluster...${NC}"
clusterctl get kubeconfig management -n default > kubeconfig-management

# Wait for at least one node to be ready before proceeding
echo -e "${BLUE}Waiting for first control plane node to be ready...${NC}"
KUBECONFIG=kubeconfig-management kubectl wait --for=condition=ready node --selector=node-role.kubernetes.io/control-plane --timeout=600s || {
    echo -e "${RED}Control plane node failed to become ready${NC}"
    exit 1
}

# Install Cilium CNI
echo -e "${BLUE}Installing Cilium CNI...${NC}"
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
    --version 1.15.0 \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=6443 \
    --set ipam.mode=kubernetes \
    --set tunnel=disabled \
    --set autoDirectNodeRoutes=true \
    --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set operator.replicas=2 \
    --wait

# Install Hetzner Cloud Controller Manager
echo -e "${BLUE}Installing Hetzner Cloud Controller Manager...${NC}"
helm repo add hcloud https://charts.hetzner.cloud
helm repo update

helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager \
    --namespace kube-system \
    --set env.HCLOUD_TOKEN.value=${HCLOUD_TOKEN} \
    --set env.HCLOUD_LOAD_BALANCERS_ENABLED.value=true \
    --set env.HCLOUD_LOAD_BALANCERS_LOCATION.value=fsn1 \
    --set env.HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP.value=true \
    --set networking.enabled=true \
    --set networking.clusterCIDR=10.244.0.0/16 \
    --wait

# Install CSI driver for persistent volumes
echo -e "${BLUE}Installing Hetzner CSI driver...${NC}"
helm upgrade --install hcloud-csi hcloud/hcloud-csi \
    --namespace kube-system \
    --set controller.hcloudToken.value=${HCLOUD_TOKEN} \
    --set node.env.HCLOUD_TOKEN.value=${HCLOUD_TOKEN} \
    --wait

# Create storage class
kubectl apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hcloud-volumes
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: csi.hetzner.cloud
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF

# Wait for all deployments to be ready
echo -e "${BLUE}Waiting for all system deployments to be ready...${NC}"
kubectl -n kube-system wait --for=condition=available deployment --all --timeout=300s

# Verify cluster health
echo -e "${BLUE}Verifying cluster health...${NC}"
kubectl get nodes
kubectl get pods -A

# If we used a bootstrap cluster, move CAPI resources to the management cluster
if [[ "${BOOTSTRAP_CLUSTER_CONTEXT}" == "kind-capi-bootstrap" ]]; then
    echo -e "${BLUE}Moving Cluster API resources to management cluster...${NC}"
    
    # First, ensure the management cluster has the required namespaces
    KUBECONFIG=kubeconfig-management kubectl create namespace capi-system --dry-run=client -o yaml | KUBECONFIG=kubeconfig-management kubectl apply -f -
    KUBECONFIG=kubeconfig-management kubectl create namespace capi-kubeadm-bootstrap-system --dry-run=client -o yaml | KUBECONFIG=kubeconfig-management kubectl apply -f -
    KUBECONFIG=kubeconfig-management kubectl create namespace capi-kubeadm-control-plane-system --dry-run=client -o yaml | KUBECONFIG=kubeconfig-management kubectl apply -f -
    KUBECONFIG=kubeconfig-management kubectl create namespace caph-system --dry-run=client -o yaml | KUBECONFIG=kubeconfig-management kubectl apply -f -
    
    # Initialize CAPI on the management cluster (required before move)
    echo -e "${BLUE}Initializing CAPI providers on management cluster...${NC}"
    KUBECONFIG=kubeconfig-management clusterctl init \
        --core cluster-api:v1.7.0 \
        --bootstrap kubeadm:v1.7.0 \
        --control-plane kubeadm:v1.7.0 \
        --infrastructure hetzner:v1.0.1 \
        --config clusterctl-config.yaml
    
    # Wait for providers to be ready on management cluster
    echo -e "${BLUE}Waiting for CAPI providers on management cluster...${NC}"
    KUBECONFIG=kubeconfig-management kubectl wait --for=condition=ready --timeout=300s -n capi-system deployment/capi-controller-manager
    KUBECONFIG=kubeconfig-management kubectl wait --for=condition=ready --timeout=300s -n caph-system deployment/caph-controller-manager
    
    # Now perform the move from bootstrap to management cluster
    echo -e "${BLUE}Performing cluster move operation...${NC}"
    kubectl config use-context ${BOOTSTRAP_CLUSTER_CONTEXT}
    clusterctl move --to-kubeconfig=kubeconfig-management -n default
    
    # Delete the bootstrap cluster
    echo -e "${BLUE}Deleting bootstrap cluster...${NC}"
    kind delete cluster --name capi-bootstrap
    
    echo -e "${GREEN}✅ Successfully moved CAPI resources to management cluster${NC}"
fi

# Save kubeconfig to expected location
mkdir -p ~/.kube
cp kubeconfig-management ~/.kube/config-management

# Set context to management cluster
export KUBECONFIG=kubeconfig-management
kubectl config rename-context management-admin@management management 2>/dev/null || true

echo -e "${GREEN}✅ Management cluster initialized successfully!${NC}"
echo -e "${GREEN}Kubeconfig saved to: kubeconfig-management${NC}"
echo -e "${GREEN}To use this cluster: export KUBECONFIG=kubeconfig-management${NC}"

echo -e "${BLUE}Next steps:${NC}"
echo "1. Install ArgoCD: ./scripts/install-argocd.sh"
echo "2. Apply GitOps configurations: ./scripts/apply-root-apps.sh"