# Documentation Overview

This directory contains all documentation for the Hetzner Multi-Cluster Kubernetes infrastructure project.

## 📚 Documentation Index

### Getting Started
- **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)** - Comprehensive step-by-step deployment guide
- **[implementation-guide.md](implementation-guide.md)** - Detailed implementation reference
- **[implementation-status.md](implementation-status.md)** - Current project status and progress tracking

### Architecture & Design
- **[hetzner-caph-production-design.md](hetzner-caph-production-design.md)** - Complete architecture design and specifications
- **[network-topology-analysis.md](network-topology-analysis.md)** - Network architecture and CIDR allocations
- **[architecture-updates-summary.md](architecture-updates-summary.md)** - Summary of architecture updates

### Implementation Guides
- **[gitops-implementation-guide.md](gitops-implementation-guide.md)** - GitOps setup with ArgoCD
- **[monitoring-cluster-implementation.md](monitoring-cluster-implementation.md)** - Monitoring stack implementation
- **[external-secrets-implementation.md](external-secrets-implementation.md)** - External Secrets with AWS integration
- **[external-dns-route53-implementation.md](external-dns-route53-implementation.md)** - DNS automation with Route53
- **[sso-and-vpn-implementation.md](sso-and-vpn-implementation.md)** - SSO and VPN setup guide
- **[vector-observability-implementation.md](vector-observability-implementation.md)** - Vector agent for metrics and logs
- **[velero-disaster-recovery.md](velero-disaster-recovery.md)** - Backup and disaster recovery setup

## 📖 Reading Order

For new users, we recommend reading the documentation in this order:

1. Start with **[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md)** for hands-on deployment
2. Review **[hetzner-caph-production-design.md](hetzner-caph-production-design.md)** for architecture understanding
3. Check **[implementation-status.md](implementation-status.md)** to see what's already implemented
4. Deep dive into specific topics as needed

## 🔍 Quick Reference

### Cluster Specifications
- **Management**: 3x cpx31 (CP) + 3x cpx41 (Workers)
- **Monitoring**: 3x cpx31 (CP) + 3x cpx51 + 1x AX41 (Workers)
- **Dev**: 3x cpx21 (CP) + 3x cpx31 (Workers)
- **DevOps**: 3x cpx31 (CP) + 2x cpx51 + 1x AX41 (Workers)
- **Staging**: 3x cpx31 (CP) + 3x cpx41 + 1x AX41 (Workers)

### Network CIDRs
- **Management**: 10.0.0.0/16 (Pods: 10.244.0.0/16, Services: 10.245.0.0/16)
- **Monitoring**: 10.246.0.0/16 (Pods: 10.246.0.0/17, Services: 10.246.128.0/17)
- **Dev**: 10.248.0.0/16 (Pods: 10.248.0.0/17, Services: 10.248.128.0/17)
- **DevOps**: 10.250.0.0/16 (Pods: 10.250.0.0/17, Services: 10.250.128.0/17)
- **Staging**: 10.252.0.0/16 (Pods: 10.252.0.0/17, Services: 10.252.128.0/17)

### Cost Breakdown
- **Total Monthly Cost**: ~€950-1000
- **Management**: €129/month
- **Monitoring**: €227/month
- **Dev**: €65/month
- **DevOps**: €195/month
- **Staging**: €168/month
- **Additional Services**: ~€166/month

## 🛠️ Maintenance

To update documentation:
1. Edit the relevant .md file
2. Update this README if adding new docs
3. Commit changes with descriptive message
4. Documentation is automatically included in GitOps sync