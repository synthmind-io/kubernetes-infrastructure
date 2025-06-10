# Production-Ready Multi-Cluster Kubernetes Design for Hetzner with CAPH

## Executive Summary

This document outlines a production-ready architecture for deploying and managing multiple Kubernetes clusters on Hetzner infrastructure using Cluster API Provider Hetzner (CAPH). The design supports three environments (Dev, DevOps, and Staging) with a GitOps-driven approach using ArgoCD, leveraging cloud instances for control planes and a hybrid approach for worker nodes.

## Architecture Overview

### Cluster Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                     Management Cluster                          │
│  - CAPI Controllers (HA)                                        │
│  - ArgoCD (Multi-tenant)                                        │
│  - GitOps Controller                                            │
│  - Backup Services                                              │
└─────────────────────────┬───────────────────────────────────────┘
                          │
    ┌─────────────────────┼─────────────────────┐
    │                     │                     │
┌───▼────────────┐  ┌─────┼─────┐  ┌───────────▼──────┐
│Monitoring      │  │     │     │  │                  │
│Cluster         │  │     │     │  │                  │
│                │  │     │     │  │                  │
│- Prometheus    │  │     ▼     │  │                  │
│- Loki          │  │┌─────────┐│  │┌───────┐┌───────┐│
│- Grafana       │  ││   Dev   ││  ││DevOps ││Staging││
│- AlertManager  │  ││ Cluster ││  ││Cluster││Cluster││
│                │  │└─────────┘│  │└───────┘└───────┘│
└────────────────┘  └───────────┘  └──────────────────┘
```

### Environment Specifications

| Environment | Control Planes | Worker Nodes | Purpose |
|-------------|----------------|--------------|---------|
| Management | 3x cpx31 (Cloud) | 3x cpx41 (Cloud) | CAPI, ArgoCD, GitOps |
| Monitoring | 3x cpx31 (Cloud) | 3x cpx51 (Cloud) + 1x AX41 (BM) | Prometheus, Loki, Grafana |
| Dev | 3x cpx31 (Cloud) | 3x cpx31 (Cloud) | Development workloads |
| DevOps | 3x cpx31 (Cloud) | 2x cpx41 (Cloud) + 2x AX41 (BM) | CI/CD, Build systems |
| Staging | 3x cpx41 (Cloud) | 2x cpx41 (Cloud) + 3x AX41 (BM) | Pre-production testing |

## Infrastructure Design

### 1. Management Cluster

The management cluster serves as the control center for all operations:

**Components:**
- **Cluster API Controllers**: CAPI, CAPBK, KCP, CAPH (all in HA mode with 2 replicas)
- **ArgoCD**: Multi-tenant setup with separate projects per environment
- **Backup**: Velero with S3-compatible backend (Hetzner Object Storage)
- **Secret Management**: External Secrets Operator with AWS Secrets Manager
- **DNS Management**: External DNS with Route53 backend
- **Policy Engine**: OPA Gatekeeper for governance
- **VPN Access**: DefGuard WireGuard VPN with Google SSO

**Specifications:**
- **Control Plane**: 3x cpx31 instances across different Hetzner zones
- **Worker Nodes**: 3x cpx41 instances for management workloads
- **Network**: Private network with cloud firewall rules
- **Storage**: Hetzner Cloud Volumes for persistent data

### 2. Monitoring Cluster

A dedicated monitoring cluster provides centralized observability:

**Components:**
- **Metrics**: Prometheus (multi-tenant with Thanos for long-term storage)
- **Logs**: Loki with S3-compatible backend
- **Visualization**: Grafana with dashboards for all clusters
- **Alerting**: AlertManager with PagerDuty/Slack integration
- **Tracing**: Jaeger for distributed tracing (optional)
- **Collection Agent**: Vector for unified observability (replaces Promtail + node-exporter)

**Specifications:**
- **Control Plane**: 3x cpx31 instances for HA
- **Worker Nodes**: 3x cpx51 (Cloud) + 1x AX41 (BM) for storage-intensive workloads
- **Storage**: 
  - 500GB+ Hetzner Cloud Volumes for Prometheus
  - Hetzner Storage Box for Loki long-term storage
  - Local NVMe on bare metal for hot data
- **Network**: High-bandwidth private network connections to all clusters

**Architecture Benefits:**
- Isolated failure domain for monitoring
- Dedicated resources prevent noisy neighbor issues
- Centralized dashboards and alerting
- Multi-cluster data aggregation
- Long-term metrics retention

### 3. Workload Clusters

Each workload cluster is designed for specific use cases:

#### Dev Cluster
- **Purpose**: Developer experimentation and testing
- **Resources**: Minimal, cost-optimized
- **Scaling**: Horizontal pod autoscaling enabled
- **Access**: Developer VPN access only

#### DevOps Cluster
- **Purpose**: CI/CD pipelines, container builds, artifact storage
- **Resources**: Mixed cloud/bare metal for compute-intensive tasks
- **Features**: 
  - GPU support on bare metal nodes for ML builds
  - High IOPS storage for build caches
  - Direct registry access

#### Staging Cluster
- **Purpose**: Production-like testing environment
- **Resources**: Mirrors production capacity at 70% scale
- **Features**:
  - Production-grade monitoring
  - Chaos engineering tools
  - Performance testing infrastructure

## GitOps Architecture

### Repository Structure

```
kubernetes-infrastructure/
├── bootstrap/
│   ├── management-cluster/
│   │   ├── cluster-api/
│   │   ├── argocd/
│   │   └── monitoring/
│   └── clusters/
│       ├── dev/
│       ├── devops/
│       └── staging/
├── infrastructure/
│   ├── base/
│   │   ├── cert-manager/
│   │   ├── ingress-nginx/
│   │   ├── cilium/
│   │   └── hcloud-ccm/
│   └── overlays/
│       ├── dev/
│       ├── devops/
│       └── staging/
├── applications/
│   ├── base/
│   └── overlays/
└── clusters/
    ├── management/
    ├── dev/
    ├── devops/
    └── staging/
```

### ArgoCD Configuration

**App of Apps Pattern:**
```yaml
# management-cluster/argocd/root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/yourorg/kubernetes-infrastructure
    path: bootstrap/management-cluster
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

**Multi-tenancy Setup:**
- Separate ArgoCD projects per environment
- RBAC policies for team access control
- Resource quotas and limits per project
- Automated secret management with sealed-secrets

## Network Architecture

### Network Topology

```
Internet
    │
    ├── Load Balancer (Hetzner LB)
    │       │
    │       ├── Management Ingress
    │       ├── Dev Ingress
    │       ├── DevOps Ingress
    │       └── Staging Ingress
    │
    └── VPN Gateway
            │
            └── Private Networks
                    ├── Management: 10.0.0.0/16
                    ├── Dev: 10.1.0.0/16
                    ├── DevOps: 10.2.0.0/16
                    └── Staging: 10.3.0.0/16
```

### Security Zones

1. **Public Zone**: Load balancers, public ingress
2. **DMZ**: VPN endpoints, bastion hosts
3. **Private Zone**: All Kubernetes nodes
4. **Restricted Zone**: etcd, management APIs

### Network Policies

- Default deny-all ingress/egress
- Explicit allow rules for service communication
- East-west traffic encryption with Cilium
- Network segmentation between environments

## Security Design

### Authentication & Authorization

1. **Cluster Access**:
   - OIDC integration with corporate IdP
   - RBAC policies synchronized via GitOps
   - Service account token rotation

2. **Secret Management**:
   - Sealed Secrets for GitOps
   - Hetzner secret for cloud API access
   - Robot credentials for bare metal
   - Automated certificate rotation

3. **Network Security**:
   - Cloud firewalls for perimeter defense
   - Network policies for microsegmentation
   - Private networks for node communication
   - VPN access for administration

### Compliance & Auditing

- Kubernetes audit logging enabled
- Falco for runtime security
- OPA Gatekeeper for policy enforcement
- Regular security scanning with Trivy

## Operational Procedures

### Cluster Provisioning

```bash
# 1. Create Hetzner project and credentials
export HCLOUD_TOKEN="<token>"
export HETZNER_ROBOT_USER="<user>"
export HETZNER_ROBOT_PASSWORD="<password>"

# 2. Bootstrap management cluster
clusterctl init --infrastructure hetzner:v1.0.1

# 3. Create cluster via GitOps
kubectl apply -f bootstrap/clusters/dev/cluster.yaml

# 4. ArgoCD will handle the rest
```

### Day-2 Operations

1. **Monitoring & Alerting**:
   - Prometheus for metrics
   - Grafana dashboards per cluster
   - PagerDuty integration for critical alerts

2. **Backup & Recovery**:
   - Velero scheduled backups (daily)
   - etcd snapshots (every 6 hours)
   - Disaster recovery runbooks

3. **Maintenance Windows**:
   - Rolling updates via CAPI
   - Automated Kubernetes upgrades
   - Zero-downtime deployments

### Capacity Planning

| Metric | Dev | DevOps | Staging |
|--------|-----|--------|---------|
| CPU Requests | 50% | 70% | 80% |
| Memory Requests | 60% | 75% | 85% |
| Storage Usage | 40% | 60% | 70% |
| Network Bandwidth | 30% | 50% | 60% |

Auto-scaling policies:
- HPA for pod scaling
- Cluster autoscaler for node scaling
- Vertical pod autoscaler for right-sizing

## Cost Optimization

### Instance Selection Strategy

1. **Control Planes**: Always use cloud instances for flexibility
2. **Worker Nodes**: 
   - Dev: 100% cloud for cost flexibility
   - DevOps: 50/50 cloud/bare metal
   - Staging: 40/60 cloud/bare metal

### Cost Controls

- Scheduled scaling for dev environment
- Spot instances for non-critical workloads
- Resource quotas per namespace
- Automated cleanup of unused resources

### Monthly Cost Estimate

| Component | Type | Count | Unit Cost | Total |
|-----------|------|-------|-----------|-------|
| Management CP | cpx31 | 3 | €13.10 | €39.30 |
| Management Workers | cpx41 | 3 | €23.95 | €71.85 |
| Monitoring CP | cpx31 | 3 | €13.10 | €39.30 |
| Monitoring Workers | cpx51 | 3 | €38.22 | €114.66 |
| Monitoring BM | AX41 | 1 | €39.00 | €39.00 |
| Dev Cluster | cpx31 | 6 | €13.10 | €78.60 |
| DevOps Cloud | cpx31/cpx41 | 5 | ~€18 | €90.00 |
| DevOps BM | AX41 | 2 | €39.00 | €78.00 |
| Staging Cloud | cpx41 | 5 | €23.95 | €119.75 |
| Staging BM | AX41 | 3 | €39.00 | €117.00 |
| Storage (Volumes) | - | - | - | ~€50.00 |
| **Total** | | | | **€837.46** |

## Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- [ ] Set up Hetzner projects and credentials
- [ ] Deploy management cluster
- [ ] Install CAPI components
- [ ] Configure ArgoCD

### Phase 2: Monitoring Infrastructure (Week 3-4)
- [ ] Deploy monitoring cluster
- [ ] Install Prometheus with Thanos
- [ ] Configure Loki and Grafana
- [ ] Set up AlertManager rules

### Phase 3: Workload Clusters (Week 5-6)
- [ ] Deploy Dev cluster
- [ ] Deploy DevOps cluster
- [ ] Deploy Staging cluster
- [ ] Configure inter-cluster networking

### Phase 4: Observability Integration (Week 7-8)
- [ ] Connect all clusters to monitoring
- [ ] Configure remote-write for Prometheus
- [ ] Set up log forwarding to Loki
- [ ] Create cluster-specific dashboards

### Phase 5: GitOps & Automation (Week 9-10)
- [ ] Complete repository structure
- [ ] Configure ArgoCD applications
- [ ] Implement secret management
- [ ] Set up automated backups

### Phase 6: Hardening & Documentation (Week 11-12)
- [ ] Security audit
- [ ] Performance tuning
- [ ] Documentation
- [ ] Runbook creation

## Conclusion

This design provides a robust, scalable, and secure multi-cluster Kubernetes platform on Hetzner infrastructure. The combination of cloud and bare metal resources offers flexibility and cost optimization, while the GitOps approach ensures consistency and auditability across all environments.

Key benefits:
- **High Availability**: 3-node control planes across zones
- **Cost Efficiency**: Mixed cloud/bare metal approach
- **Security**: Defense in depth with multiple layers
- **Scalability**: Auto-scaling at pod and node level
- **Operational Excellence**: GitOps-driven automation

Next steps:
1. Review and approve the design
2. Provision Hetzner resources
3. Begin Phase 1 implementation
4. Schedule weekly progress reviews