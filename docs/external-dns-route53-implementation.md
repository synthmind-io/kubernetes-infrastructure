# External DNS with Route53 Implementation Guide

## Overview

This guide provides comprehensive implementation details for External DNS with AWS Route53 backend across all Hetzner CAPH clusters. External DNS automatically manages DNS records for Kubernetes services and ingresses.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS Route53                              │
│                    Hosted Zones:                                │
│  - your-domain.com (Production)                                 │
│  - dev.your-domain.com (Development)                            │
│  - staging.your-domain.com (Staging)                            │
└─────────────────────────┬───────────────────────────────────────┘
                          │
    ┌─────────────────────┼─────────────────────┐
    │                     │                     │
┌───▼──────────┐  ┌───────▼────────┐  ┌────────▼───────┐
│  Management  │  │   Monitoring   │  │     Dev        │
│  Cluster     │  │   Cluster      │  │   Cluster      │
│              │  │                │  │                │
│ External DNS │  │ External DNS   │  │ External DNS   │
│ *.mgmt.*     │  │ *.monitoring.* │  │ *.dev.*        │
└──────────────┘  └────────────────┘  └────────────────┘
    │                     │                     │
┌───▼──────────┐  ┌───────▼────────────────────▼───────┐
│   DevOps     │  │            Staging                 │
│  Cluster     │  │            Cluster                 │
│              │  │                                     │
│ External DNS │  │         External DNS               │
│ *.devops.*   │  │        *.staging.*                │
└──────────────┘  └─────────────────────────────────────┘
```

## AWS IAM Configuration

### 1. Route53 Hosted Zones Setup

```bash
#!/bin/bash
# scripts/setup-route53-zones.sh

# Create hosted zones for each environment
aws route53 create-hosted-zone \
  --name your-domain.com \
  --caller-reference "production-$(date +%s)" \
  --hosted-zone-config Comment="Production zone managed by External DNS"

aws route53 create-hosted-zone \
  --name dev.your-domain.com \
  --caller-reference "dev-$(date +%s)" \
  --hosted-zone-config Comment="Development zone managed by External DNS"

aws route53 create-hosted-zone \
  --name staging.your-domain.com \
  --caller-reference "staging-$(date +%s)" \
  --hosted-zone-config Comment="Staging zone managed by External DNS"

# Get zone IDs
PROD_ZONE_ID=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='your-domain.com.'].Id" --output text | cut -d'/' -f3)
DEV_ZONE_ID=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='dev.your-domain.com.'].Id" --output text | cut -d'/' -f3)
STAGING_ZONE_ID=$(aws route53 list-hosted-zones-by-name --query "HostedZones[?Name=='staging.your-domain.com.'].Id" --output text | cut -d'/' -f3)

echo "Production Zone ID: $PROD_ZONE_ID"
echo "Dev Zone ID: $DEV_ZONE_ID"
echo "Staging Zone ID: $STAGING_ZONE_ID"
```

### 2. IAM Policy for External DNS

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": [
        "arn:aws:route53:::hostedzone/${PROD_ZONE_ID}",
        "arn:aws:route53:::hostedzone/${DEV_ZONE_ID}",
        "arn:aws:route53:::hostedzone/${STAGING_ZONE_ID}"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "route53:ListHostedZones",
        "route53:ListResourceRecordSets",
        "route53:ListTagsForResource"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
```

### 3. IRSA (IAM Roles for Service Accounts)

```bash
#!/bin/bash
# scripts/setup-external-dns-irsa.sh

CLUSTERS=("management" "monitoring" "dev" "devops" "staging")
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER="oidc.eks.eu-central-1.amazonaws.com/id/YOUR_OIDC_ID"

for CLUSTER in "${CLUSTERS[@]}"; do
  # Create IAM role for each cluster
  cat > /tmp/trust-policy-${CLUSTER}.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:external-dns:external-dns",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

  # Create the role
  aws iam create-role \
    --role-name "${CLUSTER}-external-dns" \
    --assume-role-policy-document file:///tmp/trust-policy-${CLUSTER}.json

  # Attach the policy
  aws iam put-role-policy \
    --role-name "${CLUSTER}-external-dns" \
    --policy-name "ExternalDNSPolicy" \
    --policy-document file:///tmp/external-dns-policy.json
done
```

## External DNS Configuration

### 1. Base External DNS Values

```yaml
# infrastructure/base/external-dns/values.yaml
image:
  repository: registry.k8s.io/external-dns/external-dns
  tag: v0.14.0

sources:
  - service
  - ingress

provider: aws

aws:
  region: eu-central-1
  evaluateTargetHealth: true

txtOwnerId: "external-dns"
txtPrefix: "k8s-"

policy: sync  # or "upsert-only" to prevent deletions

interval: "1m"
triggerLoopOnEvent: true

extraArgs:
  - --aws-zone-type=public
  - --log-level=info

serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: "" # Will be overridden per cluster

resources:
  requests:
    memory: 50Mi
    cpu: 10m
  limits:
    memory: 100Mi
    cpu: 50m

securityContext:
  fsGroup: 65534
  runAsUser: 65534
  runAsNonRoot: true

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
```

### 2. Per-Cluster Configurations

#### Management Cluster
```yaml
# infrastructure/overlays/management/external-dns-values.yaml
domainFilters:
  - "mgmt.your-domain.com"
  - "management.your-domain.com"

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/management-external-dns"

txtOwnerId: "external-dns-management"

extraArgs:
  - --zone-id-filter=${PROD_ZONE_ID}
  - --txt-owner-id=management-cluster
```

#### Dev Cluster
```yaml
# infrastructure/overlays/dev/external-dns-values.yaml
domainFilters:
  - "dev.your-domain.com"

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/dev-external-dns"

txtOwnerId: "external-dns-dev"

extraArgs:
  - --zone-id-filter=${DEV_ZONE_ID}
  - --txt-owner-id=dev-cluster
```

#### Staging Cluster
```yaml
# infrastructure/overlays/staging/external-dns-values.yaml
domainFilters:
  - "staging.your-domain.com"

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/staging-external-dns"

txtOwnerId: "external-dns-staging"

extraArgs:
  - --zone-id-filter=${STAGING_ZONE_ID}
  - --txt-owner-id=staging-cluster
```

### 3. Kustomization Configuration

```yaml
# infrastructure/base/external-dns/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: external-dns

resources:
- namespace.yaml

helmCharts:
- name: external-dns
  repo: https://charts.bitnami.com/bitnami
  version: 6.31.0
  releaseName: external-dns
  namespace: external-dns
  valuesFile: values.yaml
```

```yaml
# infrastructure/base/external-dns/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: external-dns
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

## Integration with Services

### 1. Ingress Annotation Examples

```yaml
# Example: ArgoCD Ingress
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    external-dns.alpha.kubernetes.io/hostname: argocd.mgmt.your-domain.com
    external-dns.alpha.kubernetes.io/ttl: "300"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - argocd.mgmt.your-domain.com
    secretName: argocd-tls
  rules:
  - host: argocd.mgmt.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
```

### 2. Service Annotation Examples

```yaml
# Example: Load Balancer Service
apiVersion: v1
kind: Service
metadata:
  name: api-gateway
  annotations:
    external-dns.alpha.kubernetes.io/hostname: api.staging.your-domain.com
    external-dns.alpha.kubernetes.io/ttl: "60"
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
spec:
  type: LoadBalancer
  ports:
  - port: 443
    targetPort: 8443
  selector:
    app: api-gateway
```

### 3. Multiple Domains per Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: multi-domain-app
  annotations:
    external-dns.alpha.kubernetes.io/hostname: "app.your-domain.com,www.your-domain.com"
spec:
  type: LoadBalancer
  ports:
  - port: 80
  selector:
    app: multi-domain
```

## Advanced Configuration

### 1. Split Horizon DNS

```yaml
# For internal-only DNS records
apiVersion: v1
kind: Service
metadata:
  name: internal-api
  annotations:
    external-dns.alpha.kubernetes.io/hostname: internal-api.private.your-domain.com
    external-dns.alpha.kubernetes.io/access: private
spec:
  type: ClusterIP
  ports:
  - port: 8080
  selector:
    app: internal-api
```

### 2. Weighted Routing (Blue/Green)

```yaml
# Blue deployment
apiVersion: v1
kind: Service
metadata:
  name: app-blue
  annotations:
    external-dns.alpha.kubernetes.io/hostname: app.your-domain.com
    external-dns.alpha.kubernetes.io/set-identifier: blue
    external-dns.alpha.kubernetes.io/aws-weight: "100"
spec:
  selector:
    app: myapp
    version: blue

---
# Green deployment (inactive)
apiVersion: v1
kind: Service
metadata:
  name: app-green
  annotations:
    external-dns.alpha.kubernetes.io/hostname: app.your-domain.com
    external-dns.alpha.kubernetes.io/set-identifier: green
    external-dns.alpha.kubernetes.io/aws-weight: "0"
spec:
  selector:
    app: myapp
    version: green
```

### 3. Geo-routing Configuration

```yaml
apiVersion: v1
kind: Service
metadata:
  name: app-eu
  annotations:
    external-dns.alpha.kubernetes.io/hostname: app.your-domain.com
    external-dns.alpha.kubernetes.io/set-identifier: eu
    external-dns.alpha.kubernetes.io/aws-geolocation-continent-code: EU
spec:
  selector:
    app: myapp
    region: eu
```

## Monitoring and Alerting

### 1. Prometheus Metrics

```yaml
# monitoring/external-dns-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: external-dns-alerts
  namespace: external-dns
spec:
  groups:
  - name: external-dns
    interval: 30s
    rules:
    - alert: ExternalDNSDown
      expr: up{job="external-dns"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "External DNS is down"
        description: "External DNS in {{ $labels.namespace }} has been down for more than 5 minutes"
    
    - alert: ExternalDNSErrors
      expr: rate(external_dns_registry_errors_total[5m]) > 0.01
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "External DNS registry errors"
        description: "External DNS is experiencing errors: {{ $value }} errors/sec"
    
    - alert: ExternalDNSSyncLatency
      expr: histogram_quantile(0.99, external_dns_controller_last_sync_timestamp_seconds) > 300
      for: 15m
      labels:
        severity: warning
      annotations:
        summary: "External DNS sync latency high"
        description: "External DNS sync latency is above 5 minutes"
```

### 2. Grafana Dashboard

```json
{
  "dashboard": {
    "title": "External DNS Overview",
    "panels": [
      {
        "title": "DNS Records Managed",
        "targets": [{
          "expr": "external_dns_registry_endpoints_total"
        }]
      },
      {
        "title": "Sync Errors Rate",
        "targets": [{
          "expr": "rate(external_dns_registry_errors_total[5m])"
        }]
      },
      {
        "title": "Last Successful Sync",
        "targets": [{
          "expr": "time() - external_dns_controller_last_sync_timestamp_seconds"
        }]
      },
      {
        "title": "API Request Duration",
        "targets": [{
          "expr": "histogram_quantile(0.95, external_dns_source_endpoints_total)"
        }]
      }
    ]
  }
}
```

## Security Best Practices

### 1. DNS Record Ownership

```yaml
# Prevent record hijacking with TXT record ownership
extraArgs:
  - --txt-owner-id=cluster-${CLUSTER_NAME}
  - --txt-prefix=externaldns-
```

### 2. Rate Limiting

```yaml
# Prevent API throttling
interval: "2m"  # Increase interval for large deployments
extraArgs:
  - --aws-batch-change-size=100
  - --aws-batch-change-interval=10s
```

### 3. Access Control

```yaml
# Limit which namespaces can create DNS records
extraArgs:
  - --namespace=default
  - --namespace=production
  - --namespace=staging
```

## Troubleshooting

### 1. Debugging DNS Issues

```bash
# Check External DNS logs
kubectl logs -n external-dns deployment/external-dns -f

# Verify IAM permissions
kubectl describe sa -n external-dns external-dns

# Check DNS records in Route53
aws route53 list-resource-record-sets --hosted-zone-id ${ZONE_ID}

# Test DNS resolution
dig +short app.your-domain.com @8.8.8.8
```

### 2. Common Issues

```bash
# Issue: Records not being created
# Solution: Check domain filters and zone ID
kubectl get deployment -n external-dns external-dns -o yaml | grep -A5 domainFilters

# Issue: Permission denied errors
# Solution: Verify IAM role trust policy
aws iam get-role --role-name ${CLUSTER}-external-dns

# Issue: Duplicate TXT records
# Solution: Ensure unique txt-owner-id per cluster
kubectl get configmap -n external-dns external-dns -o yaml | grep txt-owner-id
```

## Migration from Manual DNS

### 1. Import Existing Records

```bash
#!/bin/bash
# scripts/import-dns-records.sh

# Export existing records
aws route53 list-resource-record-sets \
  --hosted-zone-id ${ZONE_ID} \
  --output json > existing-records.json

# Create Kubernetes resources for existing records
jq -r '.ResourceRecordSets[] | select(.Type == "A" or .Type == "CNAME")' existing-records.json | while read -r record; do
  HOSTNAME=$(echo $record | jq -r .Name)
  kubectl annotate service my-service \
    external-dns.alpha.kubernetes.io/hostname=${HOSTNAME} \
    --overwrite
done
```

### 2. Gradual Migration

```yaml
# Start with upsert-only policy
policy: upsert-only  # Won't delete existing records

# After verification, switch to sync
policy: sync  # Will manage full lifecycle
```

## Cost Optimization

### 1. Batch Changes

```yaml
extraArgs:
  - --aws-batch-change-size=1000  # Max batch size
  - --aws-batch-change-interval=1s
```

### 2. Reduce API Calls

```yaml
interval: "5m"  # Increase for stable environments
extraArgs:
  - --cache-duration=5m
```

## Integration with CI/CD

### 1. GitHub Actions Example

```yaml
# .github/workflows/deploy.yaml
- name: Deploy and Update DNS
  run: |
    kubectl apply -f manifests/
    
    # Wait for External DNS to create records
    timeout 300 bash -c 'until dig +short app.${ENVIRONMENT}.your-domain.com | grep -q "^[0-9]"; do sleep 10; done'
    
    echo "DNS record created: app.${ENVIRONMENT}.your-domain.com"
```

### 2. ArgoCD Post-Sync Hook

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: verify-dns
  annotations:
    argocd.argoproj.io/hook: PostSync
spec:
  template:
    spec:
      containers:
      - name: verify
        image: alpine/bind-tools
        command:
        - sh
        - -c
        - |
          until dig +short app.your-domain.com; do
            echo "Waiting for DNS..."
            sleep 10
          done
      restartPolicy: Never
```

This implementation provides automated DNS management across all clusters with proper security, monitoring, and cost optimization.