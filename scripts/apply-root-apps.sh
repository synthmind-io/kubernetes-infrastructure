#!/bin/bash
# scripts/apply-root-apps.sh

set -euo pipefail

# Source environment variables
source .envrc || { echo "Please create .envrc file first"; exit 1; }

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Applying GitOps Root Applications${NC}"

# Use management cluster kubeconfig
export KUBECONFIG=kubeconfig-management

# Check if ArgoCD is installed
if ! kubectl get namespace argocd >/dev/null 2>&1; then
    echo -e "${RED}ArgoCD namespace not found. Please run ./scripts/install-argocd.sh first${NC}"
    exit 1
fi

# Wait for ArgoCD to be ready
echo -e "${BLUE}Waiting for ArgoCD to be ready...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

# Create root application for infrastructure
echo -e "${BLUE}Creating infrastructure root application...${NC}"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: infrastructure
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_ORG}/kubernetes-infrastructure
    targetRevision: main
    path: infrastructure
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

# Create application for clusters
echo -e "${BLUE}Creating clusters application...${NC}"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: clusters
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_ORG}/kubernetes-infrastructure
    targetRevision: main
    path: clusters
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: false  # Don't auto-prune clusters!
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

# Create application for management cluster apps
echo -e "${BLUE}Creating management apps application...${NC}"
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: management-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_ORG}/kubernetes-infrastructure
    targetRevision: main
    path: applications/management
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF

# Create AppProject for each cluster
echo -e "${BLUE}Creating ArgoCD AppProjects...${NC}"

for cluster in monitoring dev devops staging; do
    kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: ${cluster}
  namespace: argocd
spec:
  description: Project for ${cluster} cluster
  sourceRepos:
  - 'https://github.com/${GITHUB_ORG}/*'
  - 'https://charts.bitnami.com/bitnami'
  - 'https://prometheus-community.github.io/helm-charts'
  - 'https://grafana.github.io/helm-charts'
  - 'https://helm.cilium.io'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
EOF
done

# Create external secrets for ArgoCD to access other clusters
echo -e "${BLUE}Note: Cluster secrets will be created automatically when clusters are deployed${NC}"

# Wait for applications to sync
echo -e "${BLUE}Waiting for initial sync...${NC}"
sleep 10

# Show application status
echo -e "${BLUE}Application Status:${NC}"
kubectl get applications -n argocd

echo -e "${GREEN}✅ GitOps root applications created!${NC}"
echo -e "${BLUE}ArgoCD will now start syncing applications from the Git repository.${NC}"
echo -e "${YELLOW}Note: Make sure your Git repository contains the expected structure:${NC}"
echo "  - infrastructure/ (base components)"
echo "  - clusters/ (cluster definitions)"
echo "  - applications/ (application deployments)"

echo -e "${BLUE}To check sync status:${NC}"
echo "  kubectl -n argocd get applications"
echo "  argocd app list"
echo "  Open ArgoCD UI: https://argocd.mgmt.${BASE_DOMAIN}"