# 🚀 Hetzner Kubernetes Quick Start

## Prerequisites (10 minutes)

```bash
# macOS
brew install kubectl helm clusterctl kind hcloud gh awscli jq yq htpasswd

# Authenticate GitHub CLI
gh auth login

# Create accounts at:
# - https://console.hetzner.cloud/ (get API token)
# - https://aws.amazon.com/ (for Secrets Manager)
# - https://github.com/ (no need for manual token with gh CLI)
```

## Step 1: Setup Project (2 minutes)

```bash
# Option A: Use our GitHub setup script
cd /path/to/Hetzner
./scripts/setup-github-resources.sh
# This creates the repo and pushes code automatically

# Option B: Manual setup
# Create GitHub repo named 'kubernetes-infrastructure'
git clone https://github.com/YOUR_ORG/kubernetes-infrastructure.git
cd kubernetes-infrastructure
cp -r /path/to/Hetzner/* .
git add . && git commit -m "Initial commit" && git push
```

## Step 2: Configure Environment (3 minutes)

```bash
# Interactive configuration (recommended)
make configure
# Follow prompts to set up all credentials

# For specific AWS/GitHub profiles
export AWS_PROFILE=personal
export GITHUB_PROFILE=casperakos
make configure

# Or specify GitHub profile directly
./scripts/setup-github-resources.sh casperakos

# Source the environment
source .envrc
```

## Step 3: Run Setup (30-45 minutes)

```bash
# Option A: Interactive setup (recommended)
./setup.sh
# Select option 12 for full automated deployment

# Option B: Direct deployment
make bootstrap

# Option C: Step by step
make check          # Verify prerequisites
make github         # Setup GitHub repos
make deploy-management  # Deploy management cluster
make deploy-argocd  # Install ArgoCD
```

## Step 4: Configure DNS (5 minutes)

```bash
# Get Load Balancer IP
kubectl get svc -n ingress-nginx ingress-nginx-controller

# Create DNS A records:
# argocd.mgmt.your-domain.com -> <LB_IP>
# *.mgmt.your-domain.com -> <LB_IP>
```

## Step 5: Access ArgoCD

```bash
# Get credentials
cat argocd-credentials.txt

# Open browser
open https://argocd.mgmt.your-domain.com
```

## What You Get

✅ **5 Production-Ready Clusters**
- Management (CAPI + ArgoCD)
- Monitoring (Prometheus + Grafana)
- Dev, DevOps, Staging (Workload clusters)

✅ **Enterprise Features**
- GitOps with ArgoCD
- Prometheus + Thanos monitoring
- External Secrets (AWS)
- Automated DNS (Route53)
- Disaster Recovery (Velero)
- Network Policies
- HA Control Planes

✅ **Automation Features**
- Interactive environment configuration
- Automated GitHub repository setup
- Multiple GitHub profile support
- Bootstrap cluster with kind
- Automatic .envrc updates

✅ **Cost**: ~€950/month total

## Common Commands

```bash
# Check status
make status

# View costs
make costs

# Access different clusters
export KUBECONFIG=kubeconfig-management
export KUBECONFIG=kubeconfig-monitoring

# Deploy apps via GitOps
git add applications/my-app/
git commit -m "Deploy my-app"
git push
# ArgoCD auto-syncs!
```

## Troubleshooting

```bash
# Environment issues
make check          # Verify all prerequisites
cat .envrc          # Check environment variables
source .envrc       # Reload environment

# GitHub issues
gh auth status      # Check GitHub authentication
gh auth switch -u username  # Switch profiles

# AWS issues
aws configure list  # Show current configuration
aws configure list-profiles  # List available profiles
aws sts get-caller-identity  # Verify credentials work

# Cluster issues
kubectl -n capi-system logs -l control-plane=controller-manager
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-server

# Sync ArgoCD app
argocd app sync <app-name>

# Debug cluster
clusterctl describe cluster management
```

## Next Steps

1. ✅ Deploy sample application
2. ✅ Configure monitoring alerts
3. ✅ Set up SSO (optional)
4. ✅ Configure VPN access (optional)
5. ✅ Run DR test with Velero

---

Need help? Check [DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md) for detailed instructions.