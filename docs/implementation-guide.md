# Hetzner CAPH Multi-Cluster Implementation Guide

## Prerequisites Checklist

### Required Tools
- [ ] kubectl (v1.31+)
- [ ] clusterctl (v1.7.0+)
- [ ] helm (v3.14+)
- [ ] hcloud CLI
- [ ] AWS CLI v2
- [ ] git
- [ ] jq
- [ ] yq
- [ ] htpasswd (for ArgoCD passwords)

### Required Accounts & Access
- [ ] Hetzner Cloud account with API token
- [ ] Hetzner Robot account (for bare metal)
- [ ] AWS account for Secrets Manager and Route53
- [ ] GitHub account with personal access token
- [ ] Google Cloud account for OAuth (SSO)
- [ ] Domain name with Route53 hosted zones

## Step 1: Initial Setup

### 1.1 Create GitHub Repository

```bash
# Create a new repository on GitHub named 'kubernetes-infrastructure'
# Clone it locally
git clone https://github.com/yourorg/kubernetes-infrastructure.git
cd kubernetes-infrastructure
```

### 1.2 Set Environment Variables

Create `.envrc` file (add to .gitignore):

```bash
# Hetzner
export HCLOUD_TOKEN="your-hetzner-cloud-token"
export HETZNER_SSH_KEY="your-ssh-key-name"
export HETZNER_ROBOT_USER="your-robot-user"
export HETZNER_ROBOT_PASSWORD="your-robot-password"

# AWS
export AWS_REGION="eu-central-1"
export AWS_ACCOUNT_ID="your-aws-account-id"

# GitHub
export GITHUB_TOKEN="your-github-token"
export GITHUB_USER="your-github-username"
export GITHUB_ORG="your-github-org"

# Domain
export BASE_DOMAIN="your-domain.com"

# Cluster names
export CLUSTERS=("management" "monitoring" "dev" "devops" "staging")
```

## Step 2: Repository Structure Setup

### 2.1 Create Directory Structure

```bash
# Create the complete directory structure
mkdir -p {bootstrap/{management-cluster/{cluster-api,argocd},root-apps},clusters/{management,monitoring,dev,devops,staging},infrastructure/{base/{cert-manager,ingress-nginx,cilium,hcloud-ccm,hcloud-csi,external-secrets,external-dns,vector,velero,defguard},monitoring/{base/{prometheus,loki,grafana,thanos}},overlays/{management,monitoring,dev,devops,staging}},applications/{base,overlays/{management,monitoring,dev,devops,staging}},scripts,docs}
```

### 2.2 Initialize Git

```bash
# Create .gitignore
cat > .gitignore <<EOF
.envrc
.env
*.backup
*.key
*.pem
kubeconfig*
secrets/
tmp/
EOF

# Initial commit
git add .gitignore
git commit -m "Initial commit: project structure"
git push origin main
```

## Step 3: Create Bootstrap Scripts

### 3.1 Main Bootstrap Script

```bash
cat > scripts/bootstrap.sh <<'EOF'
#!/bin/bash
set -euo pipefail

# Source environment variables
source .envrc

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Starting Hetzner CAPH Multi-Cluster Bootstrap${NC}"

# Check prerequisites
./scripts/check-prerequisites.sh

# Create secrets in AWS Secrets Manager
./scripts/manage-secrets.sh

# Create Hetzner resources
./scripts/setup-hetzner-resources.sh

# Initialize management cluster
./scripts/init-management-cluster.sh

# Install ArgoCD
./scripts/install-argocd.sh

# Apply root applications
./scripts/apply-root-apps.sh

echo -e "${GREEN}Bootstrap complete!${NC}"
EOF

chmod +x scripts/bootstrap.sh
```

### 3.2 Prerequisites Check Script

```bash
cat > scripts/check-prerequisites.sh <<'EOF'
#!/bin/bash
set -euo pipefail

source .envrc

echo "Checking prerequisites..."

# Check required tools
REQUIRED_TOOLS=("kubectl" "clusterctl" "helm" "hcloud" "aws" "git" "jq" "yq" "htpasswd")

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        echo "❌ $tool is not installed"
        exit 1
    else
        echo "✅ $tool is installed"
    fi
done

# Check environment variables
REQUIRED_VARS=("HCLOUD_TOKEN" "AWS_REGION" "GITHUB_TOKEN" "BASE_DOMAIN")

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "❌ $var is not set"
        exit 1
    else
        echo "✅ $var is set"
    fi
done

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured"
    exit 1
else
    echo "✅ AWS credentials configured"
fi

# Check Hetzner CLI
if ! hcloud context active &> /dev/null; then
    echo "Setting up Hetzner CLI context..."
    hcloud context create kubernetes-infrastructure
fi

echo "✅ All prerequisites met!"
EOF

chmod +x scripts/check-prerequisites.sh
```

## Step 4: Create Core Configuration Files

### 4.1 Makefile

```bash
cat > Makefile <<'EOF'
.PHONY: help bootstrap deploy-management deploy-monitoring deploy-workloads clean

help:
	@echo "Available targets:"
	@echo "  bootstrap         - Complete bootstrap of all infrastructure"
	@echo "  deploy-management - Deploy management cluster only"
	@echo "  deploy-monitoring - Deploy monitoring cluster"
	@echo "  deploy-workloads  - Deploy all workload clusters"
	@echo "  secrets          - Manage secrets interactively"
	@echo "  clean            - Clean up all resources"

bootstrap:
	./scripts/bootstrap.sh

deploy-management:
	./scripts/init-management-cluster.sh

deploy-monitoring:
	./scripts/deploy-monitoring-cluster.sh

deploy-workloads:
	./scripts/deploy-workload-clusters.sh

secrets:
	./scripts/manage-secrets.sh

clean:
	./scripts/cleanup.sh
EOF
```

### 4.2 README.md

```bash
cat > README.md <<'EOF'
# Kubernetes Infrastructure on Hetzner

Production-ready multi-cluster Kubernetes environment on Hetzner using Cluster API Provider Hetzner (CAPH).

## Architecture Overview

- **5 Clusters**: Management, Monitoring, Dev, DevOps, Staging
- **GitOps**: ArgoCD-driven deployments
- **Monitoring**: Prometheus + Thanos + Loki + Grafana
- **Security**: SSO, VPN, External Secrets, Network Policies
- **Cost**: ~€1000/month total

## Quick Start

1. Set up prerequisites (see docs/prerequisites.md)
2. Configure environment variables in `.envrc`
3. Run bootstrap: `make bootstrap`

## Documentation

- [Architecture Design](docs/architecture.md)
- [Implementation Guide](docs/implementation-guide.md)
- [Operations Manual](docs/operations.md)
- [Disaster Recovery](docs/disaster-recovery.md)

## Repository Structure

```
kubernetes-infrastructure/
├── bootstrap/          # Bootstrap configurations
├── clusters/          # Cluster definitions
├── infrastructure/    # Core infrastructure components
├── applications/      # Application deployments
├── scripts/          # Automation scripts
└── docs/            # Documentation
```
EOF
```

## Step 5: Hetzner Resources Setup

### 5.1 Create Hetzner Resources Script

```bash
cat > scripts/setup-hetzner-resources.sh <<'EOF'
#!/bin/bash
set -euo pipefail

source .envrc

echo "Setting up Hetzner resources..."

# Create SSH key if not exists
if ! hcloud ssh-key describe ${HETZNER_SSH_KEY} &> /dev/null; then
    echo "Creating SSH key..."
    ssh-keygen -t ed25519 -f ~/.ssh/hetzner-k8s -N ""
    hcloud ssh-key create --name ${HETZNER_SSH_KEY} --public-key-from-file ~/.ssh/hetzner-k8s.pub
fi

# Create placement groups for each cluster
for cluster in "${CLUSTERS[@]}"; do
    echo "Creating placement groups for $cluster..."
    
    # Control plane placement group
    hcloud placement-group create \
        --name "${cluster}-cp-pg" \
        --type spread \
        --labels "cluster=${cluster},role=control-plane" || true
    
    # Worker placement group
    hcloud placement-group create \
        --name "${cluster}-workers-pg" \
        --type spread \
        --labels "cluster=${cluster},role=worker" || true
done

# Create private networks
for cluster in "${CLUSTERS[@]}"; do
    echo "Creating private network for $cluster..."
    
    case $cluster in
        management)
            CIDR="10.0.0.0/16"
            ;;
        monitoring)
            CIDR="10.246.0.0/16"
            ;;
        dev)
            CIDR="10.248.0.0/16"
            ;;
        devops)
            CIDR="10.250.0.0/16"
            ;;
        staging)
            CIDR="10.252.0.0/16"
            ;;
    esac
    
    hcloud network create \
        --name "${cluster}-network" \
        --ip-range "${CIDR}" \
        --labels "cluster=${cluster}" || true
    
    # Create subnet
    hcloud network add-subnet \
        "${cluster}-network" \
        --type cloud \
        --network-zone eu-central \
        --ip-range "${CIDR}" || true
done

echo "✅ Hetzner resources created!"
EOF

chmod +x scripts/setup-hetzner-resources.sh
```

## Step 6: Create Cluster Configurations

### 6.1 Management Cluster Configuration

```bash
cat > clusters/management/cluster.yaml <<'EOF'
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
    - name: ${HETZNER_SSH_KEY}
EOF
```

## Next Steps

Continue with:
1. Create AWS Secrets Manager secrets
2. Initialize the management cluster
3. Install ArgoCD
4. Deploy monitoring cluster
5. Deploy workload clusters

Would you like me to continue with the detailed implementation of each component?