# GitOps Implementation Guide for Hetzner CAPH Multi-Cluster Setup

## Overview

This guide provides detailed implementation steps and example configurations for setting up a GitOps-driven multi-cluster Kubernetes environment using ArgoCD and CAPH.

## Repository Structure

### Complete Directory Layout

```
kubernetes-infrastructure/
├── README.md
├── .gitignore
├── Makefile
├── bootstrap/
│   ├── management-cluster/
│   │   ├── kustomization.yaml
│   │   ├── cluster-api/
│   │   │   ├── kustomization.yaml
│   │   │   └── namespace.yaml
│   │   └── argocd/
│   │       ├── kustomization.yaml
│   │       ├── namespace.yaml
│   │       ├── argocd-values.yaml
│   │       └── argocd-ingress.yaml
│   └── root-apps/
│       ├── management-root-app.yaml
│       ├── monitoring-root-app.yaml
│       ├── dev-root-app.yaml
│       ├── devops-root-app.yaml
│       └── staging-root-app.yaml
├── clusters/
│   ├── management/
│   │   ├── cluster.yaml
│   │   ├── control-plane.yaml
│   │   └── workers.yaml
│   ├── monitoring/
│   │   ├── cluster.yaml
│   │   ├── control-plane.yaml
│   │   ├── workers-cloud.yaml
│   │   └── workers-baremetal.yaml
│   ├── dev/
│   │   ├── cluster.yaml
│   │   ├── control-plane.yaml
│   │   └── workers.yaml
│   ├── devops/
│   │   ├── cluster.yaml
│   │   ├── control-plane.yaml
│   │   ├── workers-cloud.yaml
│   │   └── workers-baremetal.yaml
│   └── staging/
│       ├── cluster.yaml
│       ├── control-plane.yaml
│       ├── workers-cloud.yaml
│       └── workers-baremetal.yaml
├── infrastructure/
│   ├── base/
│   │   ├── cert-manager/
│   │   ├── ingress-nginx/
│   │   ├── cilium/
│   │   ├── hcloud-ccm/
│   │   ├── hcloud-csi/
│   │   ├── external-secrets/
│   │   └── external-dns/
│   ├── monitoring/
│   │   ├── base/
│   │   │   ├── prometheus/
│   │   │   ├── loki/
│   │   │   ├── grafana/
│   │   │   └── thanos/
│   │   └── kustomization.yaml
│   └── overlays/
│       ├── management/
│       ├── monitoring/
│       ├── dev/
│       ├── devops/
│       └── staging/
├── applications/
│   ├── base/
│   │   └── sample-app/
│   └── overlays/
│       ├── management/
│       ├── monitoring/
│       ├── dev/
│       ├── devops/
│       └── staging/
└── scripts/
    ├── bootstrap.sh
    ├── create-secrets.sh
    └── cleanup.sh
```

## ArgoCD Configuration

### 1. ArgoCD Installation Values

```yaml
# bootstrap/management-cluster/argocd/argocd-values.yaml
global:
  image:
    tag: v2.10.0

redis-ha:
  enabled: true

controller:
  replicas: 2

server:
  replicas: 2
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: argocd.your-domain.com
    tls: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod

repoServer:
  replicas: 2

applicationSet:
  replicas: 2

configs:
  params:
    server.insecure: false
    server.grpc.insecure: false
  
  repositories:
    infrastructure:
      url: https://github.com/yourorg/kubernetes-infrastructure
      name: infrastructure
      type: git

  rbac:
    policy.default: role:readonly
    policy.csv: |
      p, role:admin, applications, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, repositories, *, *, allow
      g, platform-team, role:admin
      g, dev-team, role:developer
      g, devops-team, role:devops

  dex.config: |
    connectors:
    - type: github
      id: github
      name: GitHub
      config:
        clientID: $dex.github.clientID
        clientSecret: $dex.github.clientSecret
        orgs:
        - name: yourorg
          teams:
          - platform-team
          - dev-team
          - devops-team
```

### 2. Root Application Pattern

```yaml
# bootstrap/root-apps/management-root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: management
  namespace: argocd
spec:
  description: Management cluster project
  sourceRepos:
  - 'https://github.com/yourorg/kubernetes-infrastructure'
  destinations:
  - namespace: '*'
    server: https://kubernetes.default.svc
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: management-root
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: management
  source:
    repoURL: https://github.com/yourorg/kubernetes-infrastructure
    targetRevision: main
    path: bootstrap/management-cluster
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

### 3. Monitoring Cluster Root App

```yaml
# bootstrap/root-apps/monitoring-root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: monitoring
  namespace: argocd
spec:
  description: Monitoring cluster project
  sourceRepos:
  - 'https://github.com/yourorg/kubernetes-infrastructure'
  destinations:
  - namespace: '*'
    server: 'https://monitoring-cluster-api-endpoint'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-infrastructure
  namespace: argocd
spec:
  project: monitoring
  source:
    repoURL: https://github.com/yourorg/kubernetes-infrastructure
    targetRevision: main
    path: infrastructure/overlays/monitoring
  destination:
    server: https://monitoring-cluster-api-endpoint
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring-stack
  namespace: argocd
spec:
  project: monitoring
  source:
    repoURL: https://github.com/yourorg/kubernetes-infrastructure
    targetRevision: main
    path: infrastructure/monitoring
  destination:
    server: https://monitoring-cluster-api-endpoint
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

### 4. Workload Cluster Root Apps

```yaml
# bootstrap/root-apps/dev-root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dev
  namespace: argocd
spec:
  description: Dev cluster project
  sourceRepos:
  - 'https://github.com/yourorg/kubernetes-infrastructure'
  destinations:
  - namespace: '*'
    server: 'https://dev-cluster-api-endpoint'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
  roles:
  - name: dev-admin
    policies:
    - p, proj:dev:dev-admin, applications, *, dev/*, allow
    groups:
    - dev-team
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dev-infrastructure
  namespace: argocd
spec:
  project: dev
  source:
    repoURL: https://github.com/yourorg/kubernetes-infrastructure
    targetRevision: main
    path: infrastructure/overlays/dev
  destination:
    server: https://dev-cluster-api-endpoint
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## Cluster Definitions

### 1. Management Cluster

```yaml
# clusters/management/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: management
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.244.0.0/16
    services:
      cidrBlocks:
      - 10.245.0.0/16
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: management-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: HetznerCluster
    name: management
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HetznerCluster
metadata:
  name: management
  namespace: default
spec:
  controlPlaneRegion: fsn1
  controlPlaneEndpoint:
    host: ""
    port: 6443
  controlPlaneLoadBalancer:
    region: fsn1
    type: lb11
  hetznerSecret:
    name: hetzner
    key:
      hcloudToken: hcloud
  sshKeys:
    hcloud:
    - name: cluster-admin-key
```

### 2. Control Plane Configuration

```yaml
# clusters/management/control-plane.yaml
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: management-control-plane
  namespace: default
spec:
  replicas: 3
  version: v1.31.6
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: HCloudMachineTemplate
      name: management-control-plane
  kubeadmConfigSpec:
    initConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          cloud-provider: external
    clusterConfiguration:
      apiServer:
        extraArgs:
          cloud-provider: external
      controllerManager:
        extraArgs:
          cloud-provider: external
    joinConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          cloud-provider: external
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: management-control-plane
  namespace: default
spec:
  template:
    spec:
      type: cpx31
      imageName: ubuntu-22.04
      sshKeys:
      - name: cluster-admin-key
      placementGroupName: management-cp-pg
```

### 3. Worker Node Configuration

```yaml
# clusters/management/workers.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: management-workers
  namespace: default
spec:
  clusterName: management
  replicas: 3
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: management
  template:
    spec:
      clusterName: management
      version: v1.31.6
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfigTemplate
          name: management-workers
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: HCloudMachineTemplate
        name: management-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: management-workers
  namespace: default
spec:
  template:
    spec:
      type: cpx41
      imageName: ubuntu-22.04
      sshKeys:
      - name: cluster-admin-key
      placementGroupName: management-workers-pg
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfigTemplate
metadata:
  name: management-workers
  namespace: default
spec:
  template:
    spec:
      joinConfiguration:
        nodeRegistration:
          kubeletExtraArgs:
            cloud-provider: external
```

## Infrastructure Components

### 1. Cilium CNI

```yaml
# infrastructure/base/cilium/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
- name: cilium
  repo: https://helm.cilium.io/
  version: 1.15.0
  releaseName: cilium
  namespace: kube-system
  valuesFile: values.yaml

resources:
- namespace.yaml
```

```yaml
# infrastructure/base/cilium/values.yaml
kubeProxyReplacement: strict
k8sServiceHost: localhost
k8sServicePort: 6443

ipam:
  mode: kubernetes

hubble:
  relay:
    enabled: true
  ui:
    enabled: true
    ingress:
      enabled: true
      className: nginx
      hosts:
      - hubble.your-domain.com

operator:
  replicas: 2

ipv4NativeRoutingCIDR: 10.244.0.0/16
tunnel: disabled
autoDirectNodeRoutes: true

loadBalancer:
  mode: dsr
  acceleration: native

bandwidthManager:
  enabled: true
```

### 2. Hetzner Cloud Controller Manager

```yaml
# infrastructure/base/hcloud-ccm/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
- name: hcloud-cloud-controller-manager
  repo: https://charts.hetzner.cloud
  version: v1.19.0
  releaseName: hccm
  namespace: kube-system
  valuesFile: values.yaml
```

```yaml
# infrastructure/base/hcloud-ccm/values.yaml
env:
  HCLOUD_TOKEN:
    valueFrom:
      secretKeyRef:
        name: hetzner
        key: hcloud
  HCLOUD_LOAD_BALANCERS_ENABLED: "true"
  HCLOUD_LOAD_BALANCERS_LOCATION: fsn1
  HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP: "true"

networking:
  enabled: true
  clusterCIDR: 10.244.0.0/16

nodeSelector:
  node-role.kubernetes.io/control-plane: ""

tolerations:
- key: node-role.kubernetes.io/control-plane
  effect: NoSchedule
```

### 3. External Secrets Operator

```yaml
# infrastructure/base/external-secrets/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
- name: external-secrets
  repo: https://charts.external-secrets.io
  version: 0.9.11
  releaseName: external-secrets
  namespace: external-secrets-system
  valuesFile: values.yaml

resources:
- namespace.yaml
- cluster-secret-store.yaml
```

## Environment Overlays

### 1. Dev Environment Overlay

```yaml
# infrastructure/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base/cilium
- ../../base/hcloud-ccm
- ../../base/ingress-nginx
- ../../base/cert-manager
- ../../base/external-secrets

patchesStrategicMerge:
- patches/cilium-values.yaml
- patches/ingress-values.yaml

configMapGenerator:
- name: cluster-config
  literals:
  - environment=dev
  - cluster-name=dev
  - domain=dev.your-domain.com
```

### 2. Monitoring Environment Overlay

```yaml
# infrastructure/overlays/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base/cilium
- ../../base/hcloud-ccm
- ../../base/hcloud-csi
- ../../base/ingress-nginx
- ../../base/cert-manager
- ../../base/external-secrets

patchesStrategicMerge:
- patches/cilium-values.yaml
- patches/ingress-values.yaml
- patches/storage-config.yaml

configMapGenerator:
- name: cluster-config
  literals:
  - environment=monitoring
  - cluster-name=monitoring
  - domain=monitoring.your-domain.com
```

### 3. Production-like Overlay (Staging)

```yaml
# infrastructure/overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base/cilium
- ../../base/hcloud-ccm
- ../../base/hcloud-csi
- ../../base/ingress-nginx
- ../../base/cert-manager
- ../../base/external-secrets
- ../../base/external-dns

patchesStrategicMerge:
- patches/cilium-values.yaml
- patches/ingress-values.yaml
- patches/resource-limits.yaml

resources:
- backup/

configMapGenerator:
- name: cluster-config
  literals:
  - environment=staging
  - cluster-name=staging
  - domain=staging.your-domain.com
```

## Bootstrap Script

```bash
#!/bin/bash
# scripts/bootstrap.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Starting Hetzner CAPH Multi-Cluster Bootstrap${NC}"

# Check prerequisites
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}kubectl is required but not installed.${NC}" >&2; exit 1; }
command -v clusterctl >/dev/null 2>&1 || { echo -e "${RED}clusterctl is required but not installed.${NC}" >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo -e "${RED}helm is required but not installed.${NC}" >&2; exit 1; }

# Environment variables check
: "${HCLOUD_TOKEN:?Need to set HCLOUD_TOKEN}"
: "${GITHUB_TOKEN:?Need to set GITHUB_TOKEN for GitOps repo access}"
: "${SSH_KEY_NAME:?Need to set SSH_KEY_NAME}"

echo -e "${YELLOW}Initializing management cluster...${NC}"

# Initialize CAPI on existing cluster
clusterctl init \
  --core cluster-api:v1.7.0 \
  --bootstrap kubeadm:v1.7.0 \
  --control-plane kubeadm:v1.7.0 \
  --infrastructure hetzner:v1.0.1

# Wait for CAPI controllers
echo -e "${YELLOW}Waiting for CAPI controllers to be ready...${NC}"
kubectl wait --for=condition=ready pod -n capi-system -l control-plane=controller-manager --timeout=300s
kubectl wait --for=condition=ready pod -n caph-system -l control-plane=controller-manager --timeout=300s

# Create Hetzner secret
echo -e "${YELLOW}Creating Hetzner credentials secret...${NC}"
kubectl create secret generic hetzner \
  --from-literal=hcloud=$HCLOUD_TOKEN \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl patch secret hetzner -p '{"metadata":{"labels":{"clusterctl.cluster.x-k8s.io/move":""}}}'

# Scale CAPI components for HA
echo -e "${YELLOW}Scaling CAPI components for HA...${NC}"
kubectl -n capi-system scale deployment capi-controller-manager --replicas=2
kubectl -n capi-kubeadm-bootstrap-system scale deployment capi-kubeadm-bootstrap-controller-manager --replicas=2
kubectl -n capi-kubeadm-control-plane-system scale deployment capi-kubeadm-control-plane-controller-manager --replicas=2
kubectl -n caph-system scale deployment caph-controller-manager --replicas=2

# Install ArgoCD
echo -e "${YELLOW}Installing ArgoCD...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values bootstrap/management-cluster/argocd/argocd-values.yaml \
  --wait

# Create GitHub secret for ArgoCD
kubectl create secret generic github-repo \
  --from-literal=username=git \
  --from-literal=password=$GITHUB_TOKEN \
  --namespace argocd

# Apply root application
echo -e "${YELLOW}Applying ArgoCD root application...${NC}"
kubectl apply -f bootstrap/root-apps/management-root-app.yaml

echo -e "${GREEN}Bootstrap complete!${NC}"
echo -e "${GREEN}Access ArgoCD UI:${NC}"
echo -e "  URL: https://argocd.your-domain.com"
echo -e "  Username: admin"
echo -e "  Password: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)"
```

## Secret Management with External Secrets

```bash
#!/bin/bash
# scripts/setup-external-secrets.sh

# Install External Secrets Operator
echo -e "${YELLOW}Installing External Secrets Operator...${NC}"
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets-system \
  --create-namespace \
  --values infrastructure/base/external-secrets/values.yaml \
  --wait

# Create AWS credentials secret for External Secrets
AWS_CREDENTIALS=$(aws sts assume-role \
  --role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-external-secrets" \
  --role-session-name "external-secrets-setup")

kubectl create secret generic aws-credentials \
  --from-literal=access-key-id=$(echo $AWS_CREDENTIALS | jq -r .Credentials.AccessKeyId) \
  --from-literal=secret-access-key=$(echo $AWS_CREDENTIALS | jq -r .Credentials.SecretAccessKey) \
  --from-literal=session-token=$(echo $AWS_CREDENTIALS | jq -r .Credentials.SessionToken) \
  --namespace external-secrets-system

# Apply ClusterSecretStore
kubectl apply -f infrastructure/base/external-secrets/cluster-secret-store.yaml

echo -e "${GREEN}External Secrets setup complete!${NC}"
```

## Monitoring Stack Configuration

```yaml
# infrastructure/monitoring/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: monitoring

resources:
- namespace.yaml

bases:
- base/prometheus
- base/loki
- base/grafana
- base/thanos
```

```yaml
# infrastructure/monitoring/base/prometheus/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
- name: kube-prometheus-stack
  repo: https://prometheus-community.github.io/helm-charts
  version: 55.0.0
  releaseName: prometheus
  namespace: monitoring
  valuesFile: values.yaml
```

```yaml
# infrastructure/monitoring/base/loki/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
- name: loki
  repo: https://grafana.github.io/helm-charts
  version: 5.41.0
  releaseName: loki
  namespace: monitoring
  valuesFile: values.yaml
```

## CI/CD Integration

```yaml
# .github/workflows/gitops.yaml
name: GitOps Validation

on:
  pull_request:
    branches: [ main ]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup tools
      run: |
        curl -s "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
        sudo mv kustomize /usr/local/bin/
        
    - name: Validate Kustomize
      run: |
        find . -name kustomization.yaml -exec dirname {} \; | while read dir; do
          echo "Validating $dir"
          kustomize build "$dir" > /dev/null
        done
        
    - name: Validate YAML
      uses: instrumenta/kubeval-action@master
      with:
        files: |
          clusters/
          infrastructure/
          applications/
```

## Disaster Recovery

```yaml
# infrastructure/base/backup/velero-values.yaml
configuration:
  provider: aws
  backupStorageLocation:
    bucket: hetzner-k8s-backups
    config:
      region: fsn1
      s3ForcePathStyle: true
      s3Url: https://fsn1.your-s3-compatible-storage.com

initContainers:
- name: velero-plugin-for-aws
  image: velero/velero-plugin-for-aws:v1.8.0

schedules:
  daily-backup:
    schedule: "0 2 * * *"
    template:
      ttl: "720h0m0s"
      includedNamespaces:
      - "*"
      excludedNamespaces:
      - kube-system
      - kube-public
      - kube-node-lease
```

This comprehensive GitOps implementation guide provides all the necessary configurations and scripts to deploy and manage your multi-cluster Kubernetes environment on Hetzner infrastructure.