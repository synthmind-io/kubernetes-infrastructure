# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a production-ready Kubernetes multi-cluster infrastructure on Hetzner using Cluster API Provider Hetzner (CAPH). It deploys 5 clusters (Management, Monitoring, Dev, DevOps, Staging) with GitOps via ArgoCD, full monitoring stack, and enterprise security features.

## Common Commands

### Initial Setup
```bash
# Environment setup (REQUIRED FIRST)
cp .envrc.example .envrc
source .envrc  # Must set: HCLOUD_TOKEN, AWS credentials, GITHUB_TOKEN, BASE_DOMAIN

# Full automated deployment (~30-45 minutes)
make bootstrap

# Or use interactive menu
./setup.sh
```

### Deployment Commands
```bash
# Deploy individual components
make deploy-management    # Deploy management cluster only
make deploy-argocd       # Install ArgoCD
make deploy-all          # Deploy all clusters

# Check status
make status              # Show cluster and ArgoCD status
kubectl get clusters -A  # List all clusters
kubectl -n argocd get applications  # Check ArgoCD apps

# Access clusters
export KUBECONFIG=kubeconfig-management
export KUBECONFIG=kubeconfig-monitoring
```

### Operations
```bash
# Manage secrets
make secrets             # Interactive AWS Secrets Manager setup

# Troubleshooting
kubectl -n capi-system logs -l control-plane=controller-manager
kubectl -n caph-system logs -l control-plane=controller-manager
clusterctl describe cluster <cluster-name>

# Cleanup (DESTRUCTIVE!)
make clean              # Deletes all clusters and Hetzner resources
```

### Testing
```bash
# Validate configurations
make validate           # Dry-run all cluster configs

# Check prerequisites
make check             # Verify all tools installed
```

## Architecture

### Cluster Layout
- **Management Cluster**: Hosts CAPI controllers, ArgoCD, External Secrets, Velero backups
- **Monitoring Cluster**: Prometheus + Thanos, Loki, Grafana, Vector agents
- **Workload Clusters**: Dev, DevOps (CI/CD), Staging environments

### Key Design Decisions
1. **GitOps-Driven**: All deployments via ArgoCD, configurations in Git
2. **HA Control Planes**: 3 nodes per control plane across zones
3. **Hybrid Infrastructure**: Mix of cloud (cpx31/41/51) and bare metal (AX41) for cost optimization
4. **Network Isolation**: Non-overlapping CIDRs, Cilium CNI with encryption
5. **Unified Observability**: Vector agent replaces multiple monitoring agents

### Network Architecture
```
Management: 10.0.0.0/16   (Pods: 10.244.0.0/16, Services: 10.245.0.0/16)
Monitoring: 10.246.0.0/16 (Pods: 10.246.0.0/17, Services: 10.246.128.0/17)
Dev:        10.248.0.0/16 (Pods: 10.248.0.0/17, Services: 10.248.128.0/17)
DevOps:     10.250.0.0/16 (Pods: 10.250.0.0/17, Services: 10.250.128.0/17)
Staging:    10.252.0.0/16 (Pods: 10.252.0.0/17, Services: 10.252.128.0/17)
```

### Security Stack
- **Secrets**: AWS Secrets Manager via External Secrets Operator
- **Access**: Google SSO for ArgoCD/Grafana, DefGuard VPN for admin access
- **Network**: Default-deny policies, Cilium encryption, cloud firewalls
- **DNS**: Automated via External DNS with Route53

## Critical Scripts

### `scripts/init-management-cluster.sh`
- Creates local kind bootstrap cluster if needed
- Initializes CAPI providers (v1.7.0) on bootstrap cluster
- Creates Hetzner secret from HCLOUD_TOKEN
- Deploys management cluster on Hetzner infrastructure
- Installs Cilium CNI, Hetzner CCM and CSI drivers
- Moves CAPI resources from bootstrap to management cluster (pivot)
- Deletes bootstrap cluster after successful move
- Scales controllers for HA

### `scripts/manage-secrets.sh`
- Interactive menu for AWS Secrets Manager
- Creates secrets for: Hetzner tokens, GitHub, monitoring, Route53, SSO
- Supports backup/restore and rotation
- Required before cluster deployment

### `scripts/setup-github-resources.sh`
- Supports multiple GitHub CLI profiles (gh auth switch)
- Creates GitHub repository for infrastructure code
- Sets up GitHub personal access token for ArgoCD
- Configures branch protection rules
- Creates deploy keys for repository access
- Initializes repository with GitOps directory structure
- Adds GitHub Actions for validation
- Automatically updates .envrc with GitHub configuration

### `scripts/install-argocd.sh`
- Installs cert-manager and ingress-nginx first
- Deploys ArgoCD with HA configuration
- Configures GitHub repository access
- Outputs admin credentials to `argocd-credentials.txt`

## Important Environment Variables

Required in `.envrc`:
- `HCLOUD_TOKEN`: Hetzner Cloud API token
- `HETZNER_SSH_KEY`: SSH key name in Hetzner
- `AWS_REGION`, `AWS_ACCOUNT_ID`: For Secrets Manager
- `AWS_PROFILE` or (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`): AWS authentication
- `GITHUB_TOKEN`, `GITHUB_ORG`: For GitOps repository
- `GITHUB_PROFILE`: Optional, for multiple gh CLI profiles
- `BASE_DOMAIN`: Root domain for DNS records

## Cost Considerations

Total: ~€950-1000/month
- Prefer cpx31 for control planes (€13.10/month)
- Use cpx41 for general workers (€23.95/month)
- AX41 bare metal for storage/compute workloads (€39/month)
- Each Load Balancer adds ~€5/month

## Common Issues

1. **CAPI controllers not ready**: Check Hetzner API token permissions
2. **ArgoCD sync failures**: Verify GitHub token has repo access
3. **DNS not working**: Ensure Route53 zones exist and IAM roles configured
4. **Cluster stuck provisioning**: Check placement group limits in Hetzner

## Development Workflow

1. Make infrastructure changes in respective directories
2. Commit and push to Git
3. ArgoCD auto-syncs changes (or manual sync via UI)
4. For new clusters: create in `clusters/` directory
5. For new apps: create in `applications/` directory