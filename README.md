# Hetzner Multi-Cluster Kubernetes Infrastructure

## 🚀 Quick Start

```bash
# 1. Configure environment interactively
make configure
source .envrc

# 2. Run setup
./setup.sh

# 3. Select option 12 for full automated deployment
```

## 📁 Project Structure

```
.
├── README.md                    # This file
├── QUICKSTART.md               # 5-minute quick start guide
├── setup.sh                     # Main setup script (START HERE!)
├── Makefile                    # Common operations shortcuts
├── clusterctl-config.yaml       # Cluster API configuration
├── .envrc.example              # Environment template
├── clusters/                    # Cluster definitions
│   ├── management/             # Management cluster specs
│   ├── monitoring/             # Monitoring cluster specs
│   ├── dev/                    # Development cluster specs
│   ├── devops/                 # DevOps cluster specs
│   └── staging/                # Staging cluster specs
├── scripts/                     # Automation scripts
│   ├── configure-environment.sh # Interactive .envrc setup
│   ├── check-prerequisites.sh   # Verify requirements
│   ├── setup-github-resources.sh # Create GitHub repos & tokens
│   ├── setup-hetzner-resources.sh  # Create Hetzner resources
│   ├── init-management-cluster.sh  # Deploy management cluster
│   ├── install-argocd.sh       # Install ArgoCD
│   ├── apply-root-apps.sh      # Apply GitOps configs
│   └── manage-secrets.sh       # AWS Secrets Manager setup
├── infrastructure/             # Kubernetes manifests
│   ├── base/                   # Base configurations
│   └── overlays/               # Per-environment overlays
└── docs/                       # All documentation
    ├── DEPLOYMENT_GUIDE.md     # Comprehensive deployment guide
    ├── implementation-guide.md # Detailed implementation steps
    └── *.md                    # Other documentation files
```

## 🏗️ Architecture

- **5 Kubernetes Clusters**: Management, Monitoring, Dev, DevOps, Staging
- **GitOps**: ArgoCD for continuous deployment
- **Monitoring**: Prometheus, Loki, Grafana with Thanos
- **Security**: External Secrets, SSO, VPN, Network Policies
- **Infrastructure**: Mix of cloud and bare metal nodes

## 💰 Cost Breakdown

| Cluster | Nodes | Monthly Cost |
|---------|-------|--------------|
| Management | 6x cloud | €129 |
| Monitoring | 3x cloud + 1x bare metal | €227 |
| Dev | 6x cloud | €65 |
| DevOps | 4x cloud + 2x bare metal | €195 |
| Staging | 5x cloud + 3x bare metal | €168 |
| **Total** | 32 nodes | **~€1000** |

## 🛠️ Prerequisites

### Required Tools
- kubectl v1.31+
- helm v3.14+
- clusterctl v1.7.0+
- kind (for bootstrap cluster)
- hcloud CLI
- gh CLI (GitHub CLI)
- AWS CLI v2
- jq, yq, htpasswd

### Required Accounts
- Hetzner Cloud account with API token
- AWS account (Secrets Manager + Route53)
- GitHub account with personal access token
- Domain name for DNS

## 📖 Documentation

1. **[DEPLOYMENT_GUIDE.md](docs/DEPLOYMENT_GUIDE.md)** - Step-by-step deployment instructions
2. **[implementation-guide.md](docs/implementation-guide.md)** - Detailed implementation reference
3. **[implementation-status.md](docs/implementation-status.md)** - Current project status
4. **Original Docs**:
   - [hetzner-caph-production-design.md](docs/hetzner-caph-production-design.md)
   - [gitops-implementation-guide.md](docs/gitops-implementation-guide.md)
   - [monitoring-cluster-implementation.md](docs/monitoring-cluster-implementation.md)
   - [external-secrets-implementation.md](docs/external-secrets-implementation.md)

## 🚦 Getting Started

### 1. Environment Setup

```bash
# Option A: Interactive configuration (recommended)
make configure
source .envrc

# Option B: Manual configuration
cp .envrc.example .envrc
vim .envrc  # Edit with your values
source .envrc

# Option C: Quick setup with profiles
export HCLOUD_TOKEN="your-token"
export AWS_PROFILE="personal"       # Use AWS profile
export GITHUB_PROFILE="casperakos"  # Use GitHub profile
# ... set other required variables
```

### 2. Run Interactive Setup

```bash
./setup.sh
```

This provides an interactive menu with options:
- Check prerequisites
- Configure environment (.envrc)
- Setup GitHub repositories
- Create Hetzner resources
- Deploy clusters step-by-step
- Full automated deployment (option 12)

### 3. Verify Deployment

```bash
# Check cluster status
kubectl get clusters -A

# Access ArgoCD
open https://argocd.mgmt.your-domain.com

# Check applications
kubectl -n argocd get applications
```

## 🔧 Common Operations

### Access Cluster

```bash
# Management cluster
export KUBECONFIG=kubeconfig-management

# Other clusters (after deployment)
export KUBECONFIG=kubeconfig-monitoring
```

### Deploy New Application

```bash
# Create application manifest in applications/
# Commit and push to Git
# ArgoCD will auto-sync
```

### Scale Cluster

```bash
# Edit MachineDeployment replica count
kubectl edit machinedeployment <cluster>-workers
```

### Backup Cluster

```bash
# Velero is configured automatically
velero backup create manual-backup-$(date +%Y%m%d)
```

## 🆘 Troubleshooting

### Check Logs

```bash
# CAPI controllers
kubectl -n capi-system logs -l control-plane=controller-manager

# ArgoCD
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-server

# Cluster issues
clusterctl describe cluster <cluster-name>
```

### Common Issues

1. **Cluster creation stuck**: Check Hetzner quotas and API token permissions
2. **ArgoCD sync fails**: Verify GitHub token and repository access
3. **DNS not working**: Ensure Route53 zones are created and External DNS has permissions

## 📊 Monitoring

- **Grafana**: https://grafana.monitoring.your-domain.com
- **Prometheus**: https://prometheus.monitoring.your-domain.com
- **ArgoCD**: https://argocd.mgmt.your-domain.com

## 🔐 Security

- All secrets stored in AWS Secrets Manager
- Network policies enforce zero-trust
- SSO integration for user access
- VPN for administrative access
- Automated certificate management

## 🤝 Contributing

1. Fork the repository
2. Create feature branch
3. Commit changes
4. Push to branch
5. Create Pull Request

## 📝 License

This project is licensed under the MIT License.

## 🙏 Acknowledgments

- [Cluster API](https://cluster-api.sigs.k8s.io/)
- [Syself CAPH Provider](https://github.com/syself/cluster-api-provider-hetzner)
- [ArgoCD](https://argoproj.github.io/cd/)
- [Hetzner Cloud](https://www.hetzner.com/cloud)