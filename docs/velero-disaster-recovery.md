# Velero Disaster Recovery Implementation

## Overview

This guide implements Velero for disaster recovery across all Hetzner Kubernetes clusters, using S3-compatible storage for backups.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     S3-Compatible Storage                       │
│                  (Hetzner Object Storage)                       │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐              │
│  │ Management  │ │ Monitoring  │ │    Dev      │              │
│  │  Backups    │ │  Backups    │ │  Backups    │              │
│  └─────────────┘ └─────────────┘ └─────────────┘              │
│  ┌─────────────┐ ┌─────────────┐                              │
│  │   DevOps    │ │  Staging    │                              │
│  │  Backups    │ │  Backups    │                              │
│  └─────────────┘ └─────────────┘                              │
└────────────────────────┬────────────────────────────────────────┘
                         │
     ┌───────────────────┴───────────────────────┐
     │                                           │
┌────▼─────┐  ┌──────▼─────┐  ┌─────▼─────┐  ┌─▼───────┐  ┌─▼──────┐
│Management│  │ Monitoring │  │    Dev    │  │ DevOps  │  │Staging │
│ Cluster  │  │  Cluster   │  │  Cluster  │  │ Cluster │  │Cluster │
│          │  │            │  │           │  │         │  │        │
│ Velero   │  │  Velero    │  │  Velero   │  │ Velero  │  │ Velero │
└──────────┘  └────────────┘  └───────────┘  └─────────┘  └────────┘
```

## S3 Storage Configuration

### 1. Create S3 Buckets

```bash
#!/bin/bash
# scripts/setup-velero-s3.sh

# S3 Configuration
S3_ENDPOINT="https://fsn1.your-s3-provider.com"
S3_REGION="fsn1"
ENVIRONMENTS=("management" "monitoring" "dev" "devops" "staging")

# Create buckets for each environment
for env in "${ENVIRONMENTS[@]}"; do
    echo "Creating bucket for $env..."
    aws s3 mb s3://hetzner-velero-${env} \
        --endpoint-url $S3_ENDPOINT \
        --region $S3_REGION
    
    # Enable versioning
    aws s3api put-bucket-versioning \
        --bucket hetzner-velero-${env} \
        --versioning-configuration Status=Enabled \
        --endpoint-url $S3_ENDPOINT \
        --region $S3_REGION
    
    # Set lifecycle policy for cost optimization
    cat <<EOF > /tmp/lifecycle-${env}.json
{
    "Rules": [
        {
            "ID": "DeleteOldBackups",
            "Status": "Enabled",
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 30
            },
            "AbortIncompleteMultipartUpload": {
                "DaysAfterInitiation": 7
            }
        },
        {
            "ID": "TransitionToIA",
            "Status": "Enabled",
            "Transitions": [
                {
                    "Days": 7,
                    "StorageClass": "STANDARD_IA"
                }
            ]
        }
    ]
}
EOF
    
    aws s3api put-bucket-lifecycle-configuration \
        --bucket hetzner-velero-${env} \
        --lifecycle-configuration file:///tmp/lifecycle-${env}.json \
        --endpoint-url $S3_ENDPOINT \
        --region $S3_REGION
done
```

### 2. Create IAM User and Policies

```bash
# Create IAM user for Velero
aws iam create-user --user-name velero-backup-user

# Create and attach policy
cat <<EOF > /tmp/velero-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads",
                "s3:AbortMultipartUpload"
            ],
            "Resource": [
                "arn:aws:s3:::hetzner-velero-*/*",
                "arn:aws:s3:::hetzner-velero-*"
            ]
        }
    ]
}
EOF

aws iam create-policy \
    --policy-name VeleroBackupPolicy \
    --policy-document file:///tmp/velero-policy.json

aws iam attach-user-policy \
    --user-name velero-backup-user \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/VeleroBackupPolicy

# Create access keys
aws iam create-access-key --user-name velero-backup-user
```

## Velero Installation

### 1. Base Velero Configuration

```yaml
# infrastructure/base/velero/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: velero
---
# infrastructure/base/velero/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: velero

helmCharts:
- name: velero
  repo: https://vmware-tanzu.github.io/helm-charts
  version: 5.2.0
  releaseName: velero
  namespace: velero
  valuesFile: values.yaml

resources:
- namespace.yaml
- backup-schedules.yaml
- backup-storage-location.yaml
```

### 2. Velero Values Configuration

```yaml
# infrastructure/base/velero/values.yaml
configuration:
  # Cloud provider configuration
  provider: aws
  
  # Backup storage location
  backupStorageLocation:
    provider: aws
    bucket: hetzner-velero-${CLUSTER_NAME}
    config:
      region: fsn1
      s3ForcePathStyle: "true"
      s3Url: https://fsn1.your-s3-provider.com
      publicUrl: https://fsn1.your-s3-provider.com
  
  # Volume snapshot location (using Restic for Hetzner)
  volumeSnapshotLocation:
    provider: aws
    config:
      region: fsn1
  
  # Default backup TTL
  defaultBackupTTL: "720h0m0s" # 30 days
  
  # Enable restic for volume backups
  defaultVolumesToRestic: true
  
  # Resource requests/limits
  resources:
    requests:
      cpu: 500m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1024Mi

# Restic DaemonSet configuration
deployRestic: true
restic:
  privileged: true
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  
  # Node selector for restic pods
  nodeSelector: {}
  
  # Tolerations for restic to run on all nodes
  tolerations:
  - operator: Exists

# Velero server configuration
resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 1024Mi

# Init containers to setup AWS credentials
initContainers:
- name: velero-plugin-for-aws
  image: velero/velero-plugin-for-aws:v1.8.0
  volumeMounts:
  - mountPath: /target
    name: plugins

# Service monitor for Prometheus
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    additionalLabels:
      prometheus: kube-prometheus

# Pod annotations
podAnnotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8085"
  prometheus.io/path: "/metrics"

# Security context
securityContext:
  fsGroup: 65534
  runAsUser: 65534
  runAsNonRoot: true

# Configure server to handle large backups
configuration:
  features: EnableCSI
  logLevel: info
  logFormat: json
```

### 3. Backup Storage Location

```yaml
# infrastructure/base/velero/backup-storage-location.yaml
apiVersion: velero.io/v1
kind: BackupStorageLocation
metadata:
  name: default
  namespace: velero
spec:
  provider: aws
  objectStorage:
    bucket: hetzner-velero-${CLUSTER_NAME}
    prefix: backups
  config:
    region: fsn1
    s3ForcePathStyle: "true"
    s3Url: https://fsn1.your-s3-provider.com
    checksumAlgorithm: ""
  credential:
    name: velero-credentials
    key: cloud
  default: true
---
# Create credentials secret via External Secrets
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: velero-credentials
  namespace: velero
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: velero-credentials
    template:
      data:
        cloud: |
          [default]
          aws_access_key_id={{ .accessKeyId }}
          aws_secret_access_key={{ .secretAccessKey }}
  data:
  - secretKey: accessKeyId
    remoteRef:
      key: /hetzner/velero/access-key-id
  - secretKey: secretAccessKey
    remoteRef:
      key: /hetzner/velero/secret-access-key
```

### 4. Backup Schedules

```yaml
# infrastructure/base/velero/backup-schedules.yaml
# Daily backup of all namespaces
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily-backup-all
  namespace: velero
spec:
  schedule: "0 2 * * *" # 2 AM daily
  template:
    includedNamespaces:
    - "*"
    excludedNamespaces:
    - kube-system
    - kube-public
    - kube-node-lease
    - velero
    ttl: "720h0m0s" # 30 days
    includeClusterResources: true
    defaultVolumesToRestic: true
    hooks: {}
    metadata:
      labels:
        backup-type: scheduled
        frequency: daily
---
# Hourly backup of critical namespaces
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: hourly-backup-critical
  namespace: velero
spec:
  schedule: "0 * * * *" # Every hour
  template:
    includedNamespaces:
    - argocd
    - monitoring
    - external-secrets-system
    - cert-manager
    ttl: "168h0m0s" # 7 days
    includeClusterResources: false
    defaultVolumesToRestic: true
    metadata:
      labels:
        backup-type: scheduled
        frequency: hourly
        priority: critical
---
# Weekly backup with extended retention
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly-backup-archive
  namespace: velero
spec:
  schedule: "0 3 * * 0" # 3 AM every Sunday
  template:
    includedNamespaces:
    - "*"
    ttl: "2160h0m0s" # 90 days
    includeClusterResources: true
    defaultVolumesToRestic: true
    snapshotVolumes: true
    metadata:
      labels:
        backup-type: scheduled
        frequency: weekly
        retention: extended
```

### 5. Per-Environment Overlays

```yaml
# infrastructure/overlays/management/velero-patch.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: velero-config
  namespace: velero
data:
  cluster-name: management
  backup-prefix: management
  retention-days: "30"
---
# Additional management-specific schedules
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: etcd-backup
  namespace: velero
spec:
  schedule: "*/30 * * * *" # Every 30 minutes
  template:
    includeClusterResources: true
    includeNamespaces:
    - kube-system
    labelSelector:
      matchLabels:
        component: etcd
    ttl: "24h0m0s"
    metadata:
      labels:
        backup-type: etcd
        cluster: management
```

## Disaster Recovery Procedures

### 1. RTO/RPO Objectives

| Component | RPO | RTO | Backup Frequency |
|-----------|-----|-----|------------------|
| etcd | 30 minutes | 1 hour | Every 30 minutes |
| Critical Apps | 1 hour | 2 hours | Hourly |
| Standard Apps | 24 hours | 4 hours | Daily |
| Persistent Volumes | 1 hour | 4 hours | Hourly with Restic |

### 2. Backup Validation Script

```bash
#!/bin/bash
# scripts/validate-velero-backups.sh

set -euo pipefail

CLUSTERS=("management" "monitoring" "dev" "devops" "staging")

validate_backup() {
    local cluster=$1
    local backup_name=$2
    
    echo "Validating backup $backup_name for cluster $cluster..."
    
    # Check backup status
    kubectl --context=$cluster -n velero get backup $backup_name -o json | \
        jq -r '.status.phase'
    
    # Check backup size and items
    kubectl --context=$cluster -n velero describe backup $backup_name | \
        grep -E "(Total items|Size)"
    
    # Verify S3 objects exist
    aws s3 ls s3://hetzner-velero-${cluster}/backups/${backup_name}/ \
        --endpoint-url $S3_ENDPOINT \
        --recursive --summarize
}

# Run validation for all clusters
for cluster in "${CLUSTERS[@]}"; do
    echo "Checking backups for $cluster cluster..."
    
    # Get latest backup
    latest_backup=$(kubectl --context=$cluster -n velero get backup \
        --sort-by=.metadata.creationTimestamp -o json | \
        jq -r '.items[-1].metadata.name')
    
    if [ -n "$latest_backup" ]; then
        validate_backup $cluster $latest_backup
    else
        echo "WARNING: No backups found for $cluster"
    fi
done
```

### 3. Disaster Recovery Runbook

```yaml
# runbooks/disaster-recovery-procedure.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: disaster-recovery-runbook
  namespace: velero
data:
  procedure.md: |
    # Disaster Recovery Procedure
    
    ## 1. Assess the Situation
    - [ ] Identify affected cluster(s)
    - [ ] Determine scope of failure
    - [ ] Check backup availability
    
    ## 2. Prepare Recovery Environment
    ```bash
    # Create new cluster if needed
    kubectl apply -f clusters/${CLUSTER_NAME}/
    
    # Wait for cluster ready
    kubectl wait --for=condition=ready cluster/${CLUSTER_NAME} --timeout=30m
    
    # Install Velero in new cluster
    helm install velero vmware-tanzu/helm-charts \
      --namespace velero \
      --create-namespace \
      --values infrastructure/base/velero/values.yaml
    ```
    
    ## 3. List Available Backups
    ```bash
    velero backup get
    
    # Or from S3 directly
    aws s3 ls s3://hetzner-velero-${CLUSTER_NAME}/backups/ \
      --endpoint-url https://fsn1.your-s3-provider.com
    ```
    
    ## 4. Restore from Backup
    ```bash
    # Full cluster restore
    velero restore create --from-backup daily-backup-all-20240115020000
    
    # Namespace-specific restore
    velero restore create --from-backup hourly-backup-critical-20240115140000 \
      --include-namespaces argocd,monitoring
    
    # Restore with modifications
    velero restore create --from-backup daily-backup-all-20240115020000 \
      --exclude-namespaces kube-system \
      --exclude-resources nodes,events
    ```
    
    ## 5. Verify Restoration
    ```bash
    # Check restore status
    velero restore describe <restore-name>
    
    # Verify applications
    kubectl get pods --all-namespaces
    kubectl get pvc --all-namespaces
    
    # Test application endpoints
    ./scripts/test-application-health.sh
    ```
    
    ## 6. Post-Recovery Tasks
    - [ ] Update DNS records if needed
    - [ ] Verify monitoring and alerting
    - [ ] Check backup schedules are active
    - [ ] Document incident and recovery time
    - [ ] Update disaster recovery procedures
```

### 4. Automated Recovery Testing

```yaml
# infrastructure/base/velero/recovery-test-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: velero-recovery-test
  namespace: velero
spec:
  schedule: "0 4 * * 1" # Weekly on Monday at 4 AM
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: velero-recovery-test
          containers:
          - name: recovery-test
            image: bitnami/kubectl:latest
            command:
            - /bin/bash
            - -c
            - |
              # Create test namespace
              kubectl create namespace dr-test-$(date +%s)
              
              # Deploy test application
              kubectl apply -f /scripts/test-app.yaml -n dr-test-$(date +%s)
              
              # Create backup
              velero backup create test-backup-$(date +%s) \
                --include-namespaces dr-test-$(date +%s) \
                --wait
              
              # Delete namespace
              kubectl delete namespace dr-test-$(date +%s)
              
              # Restore from backup
              velero restore create test-restore-$(date +%s) \
                --from-backup test-backup-$(date +%s) \
                --wait
              
              # Verify restoration
              kubectl get all -n dr-test-$(date +%s)
              
              # Cleanup
              kubectl delete namespace dr-test-$(date +%s)
              velero backup delete test-backup-$(date +%s) --confirm
            volumeMounts:
            - name: test-app
              mountPath: /scripts
          volumes:
          - name: test-app
            configMap:
              name: dr-test-app
          restartPolicy: OnFailure
```

## Monitoring and Alerting

### 1. Velero Metrics

```yaml
# infrastructure/monitoring/prometheus/velero-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: velero-alerts
  namespace: monitoring
spec:
  groups:
  - name: velero
    interval: 30s
    rules:
    - alert: VeleroBackupFailed
      expr: velero_backup_failure_total > 0
      for: 15m
      labels:
        severity: critical
      annotations:
        summary: "Velero backup failed"
        description: "Velero backup has failed in namespace {{ $labels.namespace }}"
    
    - alert: VeleroBackupNotRunning
      expr: time() - velero_backup_last_successful_timestamp > 86400
      for: 1h
      labels:
        severity: warning
      annotations:
        summary: "Velero backup not running"
        description: "No successful backup in the last 24 hours"
    
    - alert: VeleroRestoreFailed
      expr: velero_restore_failure_total > 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "Velero restore failed"
        description: "Velero restore operation failed"
    
    - alert: VeleroBackupPartialFailure
      expr: velero_backup_partial_failure_total > 0
      for: 30m
      labels:
        severity: warning
      annotations:
        summary: "Velero backup partial failure"
        description: "Some items failed during backup"
```

### 2. Grafana Dashboard

```yaml
# infrastructure/monitoring/grafana/dashboards/velero-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: velero-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  velero-dashboard.json: |
    {
      "dashboard": {
        "title": "Velero Backup Status",
        "panels": [
          {
            "title": "Backup Success Rate",
            "targets": [{
              "expr": "sum(velero_backup_success_total) / sum(velero_backup_attempt_total) * 100"
            }]
          },
          {
            "title": "Backup Duration",
            "targets": [{
              "expr": "histogram_quantile(0.99, velero_backup_duration_seconds_bucket)"
            }]
          },
          {
            "title": "Storage Usage by Cluster",
            "targets": [{
              "expr": "sum by (cluster) (velero_backup_items_total)"
            }]
          },
          {
            "title": "Last Successful Backup",
            "targets": [{
              "expr": "time() - velero_backup_last_successful_timestamp"
            }]
          }
        ]
      }
    }
```

## Cost Optimization

### 1. Storage Lifecycle Policies

```json
{
  "Rules": [
    {
      "ID": "TransitionToGlacier",
      "Status": "Enabled",
      "Transitions": [{
        "Days": 30,
        "StorageClass": "GLACIER"
      }],
      "NoncurrentVersionTransitions": [{
        "NoncurrentDays": 7,
        "StorageClass": "GLACIER"
      }]
    },
    {
      "ID": "DeleteOldVersions",
      "Status": "Enabled",
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 90
      }
    }
  ]
}
```

### 2. Backup Optimization

```yaml
# Exclude unnecessary resources from backup
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: optimized-daily-backup
spec:
  template:
    excludedResources:
    - events
    - events.events.k8s.io
    - backups.velero.io
    - restores.velero.io
    - resticrepositories.velero.io
    excludedNamespaces:
    - velero
    - kube-system
    - kube-public
```

## Integration with GitOps

```yaml
# bootstrap/root-apps/velero-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: velero
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/yourorg/kubernetes-infrastructure
    targetRevision: main
    path: infrastructure/overlays/${CLUSTER_NAME}/velero
  destination:
    server: https://kubernetes.default.svc
    namespace: velero
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
```

This comprehensive Velero implementation provides:
- Automated backups with multiple schedules
- S3-compatible storage with lifecycle policies
- Disaster recovery procedures with defined RTO/RPO
- Monitoring and alerting integration
- Cost optimization strategies
- Automated recovery testing