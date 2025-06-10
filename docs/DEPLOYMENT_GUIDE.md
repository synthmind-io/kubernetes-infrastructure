# Hetzner Multi-Cluster Kubernetes Deployment Guide

## 🚀 Quick Start

This guide will walk you through deploying a production-ready multi-cluster Kubernetes environment on Hetzner.

## Prerequisites

### 1. Install Required Tools

```bash
# macOS
brew install kubectl helm clusterctl hcloud awscli jq yq htpasswd

# Linux
# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install clusterctl
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/v1.7.0/clusterctl-linux-amd64 -o clusterctl
sudo install -o root -g root -m 0755 clusterctl /usr/local/bin/clusterctl

# Install hcloud CLI
wget -O hcloud.tar.gz https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz
tar xf hcloud.tar.gz && sudo mv hcloud /usr/local/bin/
```

### 2. Create Accounts

1. **Hetzner Cloud**: https://console.hetzner.cloud/
   - Create a new project
   - Generate an API token (Read & Write)

2. **AWS Account** (for Secrets Manager & Route53):
   - Create IAM user with programmatic access
   - Attach policies for Secrets Manager and Route53

3. **GitHub**:
   - Create a new repository named `kubernetes-infrastructure`
   - Generate a Personal Access Token with repo access

4. **Google Cloud** (optional, for SSO):
   - Create OAuth 2.0 credentials

### 3. Prepare Domain

- Have a domain ready (e.g., `your-domain.com`)
- Be prepared to create DNS records

## Step-by-Step Deployment

### Step 1: Clone and Configure Repository

```bash
# Clone your repository
git clone https://github.com/yourorg/kubernetes-infrastructure.git
cd kubernetes-infrastructure

# Create environment file
cat > .envrc <<'EOF'
# Hetzner
export HCLOUD_TOKEN="your-hetzner-cloud-token"
export HETZNER_SSH_KEY="hetzner-k8s"
export HETZNER_ROBOT_USER=""  # Only if using bare metal
export HETZNER_ROBOT_PASSWORD=""  # Only if using bare metal

# AWS
export AWS_REGION="eu-central-1"
export AWS_ACCOUNT_ID="123456789012"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"

# GitHub
export GITHUB_TOKEN="ghp_your_token"
export GITHUB_USER="your-username"
export GITHUB_ORG="your-org"

# Domain
export BASE_DOMAIN="your-domain.com"

# Cluster names
export CLUSTERS=("management" "monitoring" "dev" "devops" "staging")
EOF

# Source the environment
source .envrc
```

### Step 2: Create Repository Structure

```bash
# Run the setup script from the implementation guide
chmod +x scripts/*.sh

# Create directory structure
mkdir -p {bootstrap/{management-cluster/{cluster-api,argocd},root-apps},clusters/{management,monitoring,dev,devops,staging},infrastructure/{base/{cert-manager,ingress-nginx,cilium,hcloud-ccm,hcloud-csi,external-secrets,external-dns,vector,velero,defguard},monitoring/{base/{prometheus,loki,grafana,thanos}},overlays/{management,monitoring,dev,devops,staging}},applications/{base,overlays/{management,monitoring,dev,devops,staging}},scripts,docs}

# Copy all the scripts and configurations from this guide
# (Use the files provided in the implementation guide)

# Commit and push
git add .
git commit -m "Initial infrastructure setup"
git push origin main
```

### Step 3: Create SSH Key and Hetzner Resources

```bash
# Generate SSH key
ssh-keygen -t ed25519 -f ~/.ssh/hetzner-k8s -N ""

# Create SSH key in Hetzner
hcloud ssh-key create --name hetzner-k8s --public-key-from-file ~/.ssh/hetzner-k8s.pub

# Set up Hetzner resources
./scripts/setup-hetzner-resources.sh
```

### Step 4: Configure AWS Secrets

```bash
# Run the secrets management script
./scripts/manage-secrets.sh

# Select option 1 to create all secrets for management environment
# Follow the prompts to enter:
# - Hetzner Cloud token
# - GitHub credentials
# - AWS credentials (if different from environment)
# - ArgoCD admin password
# - SSO configuration (optional)
```

### Step 5: Deploy Management Cluster

```bash
# Initialize the management cluster
./scripts/init-management-cluster.sh

# This will:
# - Initialize Cluster API
# - Create the management cluster
# - Install CNI (Cilium)
# - Install cloud controller manager
# - Install CSI driver
# - Take about 10-15 minutes
```

### Step 6: Install ArgoCD

```bash
# Install ArgoCD and prerequisites
./scripts/install-argocd.sh

# This will:
# - Install cert-manager
# - Install ingress-nginx
# - Install ArgoCD with HA configuration
# - Output the admin credentials
```

### Step 7: Configure DNS

After ArgoCD installation, you'll get a Load Balancer IP. Create DNS records:

```bash
# Get the Load Balancer IP
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Create A records:
# argocd.mgmt.your-domain.com -> <LB_IP>
# *.mgmt.your-domain.com -> <LB_IP>
```

### Step 8: Apply GitOps Configuration

```bash
# Apply root applications
./scripts/apply-root-apps.sh

# This will:
# - Create ArgoCD projects
# - Create root applications
# - Set up ApplicationSets
# - Configure External Secrets
```

### Step 9: Access ArgoCD

1. Open https://argocd.mgmt.your-domain.com
2. Login with:
   - Username: `admin`
   - Password: (check `argocd-credentials.txt`)

### Step 10: Deploy Monitoring Cluster

```bash
# Create monitoring cluster configuration
./scripts/deploy-monitoring-cluster.sh

# Apply via ArgoCD or kubectl
kubectl apply -f clusters/monitoring/
```

### Step 11: Deploy Workload Clusters

```bash
# Deploy all workload clusters
./scripts/deploy-workload-clusters.sh

# Or deploy individually:
kubectl apply -f clusters/dev/
kubectl apply -f clusters/devops/
kubectl apply -f clusters/staging/
```

## Verification Steps

### 1. Check Cluster Status

```bash
# List all clusters
kubectl get clusters -A

# Check node status for each cluster
for cluster in management monitoring dev devops staging; do
  echo "Checking $cluster cluster..."
  kubectl --kubeconfig kubeconfig-$cluster get nodes
done
```

### 2. Verify ArgoCD Applications

```bash
# Check application status
kubectl -n argocd get applications

# Get detailed status
argocd app list
argocd app get management-root
```

### 3. Test Ingress and DNS

```bash
# Test each cluster's ingress
curl -k https://argocd.mgmt.your-domain.com
curl -k https://grafana.monitoring.your-domain.com
```

## Common Issues and Solutions

### Issue: Cluster Creation Fails

```bash
# Check CAPI controller logs
kubectl -n capi-system logs -l control-plane=controller-manager
kubectl -n caph-system logs -l control-plane=controller-manager

# Check machine status
kubectl get machines -A
kubectl describe machine <machine-name>
```

### Issue: ArgoCD Sync Fails

```bash
# Check application details
argocd app get <app-name>
argocd app sync <app-name>

# Force refresh
argocd app refresh <app-name> --hard
```

### Issue: DNS Not Resolving

```bash
# Check External DNS logs
kubectl -n external-dns logs -l app.kubernetes.io/name=external-dns

# Verify Route53 records
aws route53 list-resource-record-sets --hosted-zone-id <zone-id>
```

## Next Steps

1. **Configure SSO**: Set up Google OAuth for ArgoCD and Grafana
2. **Set up VPN**: Deploy DefGuard for secure access
3. **Configure Backups**: Set up Velero for disaster recovery
4. **Deploy Applications**: Start deploying your workloads
5. **Set up Monitoring**: Configure alerts and dashboards

## Maintenance

### Daily Tasks
- Check ArgoCD sync status
- Review monitoring dashboards
- Check for security alerts

### Weekly Tasks
- Review cluster resource usage
- Check backup status
- Update applications

### Monthly Tasks
- Perform disaster recovery test
- Review and rotate secrets
- Update cluster components

## Support

- Check logs: `kubectl logs -n <namespace> <pod>`
- CAPI documentation: https://cluster-api.sigs.k8s.io/
- Hetzner CAPH: https://github.com/syself/cluster-api-provider-hetzner
- ArgoCD docs: https://argo-cd.readthedocs.io/

## Estimated Costs

| Component | Monthly Cost |
|-----------|-------------|
| Management Cluster | ~€130 |
| Monitoring Cluster | ~€230 |
| Dev Cluster | ~€65 |
| DevOps Cluster | ~€196 |
| Staging Cluster | ~€169 |
| Load Balancers | ~€50 |
| Storage/Backups | ~€100 |
| **Total** | **~€940** |