# Monitoring Cluster Implementation Guide

## Overview

This guide provides detailed implementation for the dedicated monitoring cluster that serves all environments in the Hetzner multi-cluster setup.

## Monitoring Cluster Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Monitoring Cluster                     │
├─────────────────────────────────────────────────────────┤
│ Control Plane: 3x cpx31 (HA)                            │
│ Workers: 3x cpx51 + 1x AX41 (Bare Metal)               │
├─────────────────────────────────────────────────────────┤
│ • Prometheus + Thanos (Multi-cluster metrics)           │
│ • Loki (Centralized logging)                            │
│ • Grafana (Visualization)                               │
│ • AlertManager (Alert routing)                          │
│ • Jaeger (Distributed tracing)                          │
└─────────────────────────────────────────────────────────┘
                            │
    ┌───────────────────────┼───────────────────────┐
    │                       │                       │
┌───▼──────┐         ┌──────▼──────┐        ┌──────▼──────┐
│Management│         │  Workload   │        │  Workload   │
│ Cluster  │         │  Clusters   │        │  Clusters   │
│          │         │(Dev,DevOps) │        │ (Staging)   │
└──────────┘         └─────────────┘        └─────────────┘
```

## Cluster Definition

### 1. Monitoring Cluster Manifest

```yaml
# clusters/monitoring/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: monitoring
  namespace: default
  labels:
    cluster-role: monitoring
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.246.0.0/16  # Unique subnet for monitoring
    services:
      cidrBlocks:
      - 10.247.0.0/16
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: monitoring-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: HetznerCluster
    name: monitoring
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HetznerCluster
metadata:
  name: monitoring
  namespace: default
spec:
  controlPlaneRegion: fsn1
  controlPlaneEndpoint:
    host: ""
    port: 6443
  controlPlaneLoadBalancer:
    region: fsn1
    type: lb11
    algorithm: round_robin
    extraServices:
    - protocol: tcp
      listenPort: 443
      destinationPort: 443
  hetznerSecret:
    name: hetzner
    key:
      hcloudToken: hcloud
  sshKeys:
    hcloud:
    - name: cluster-admin-key
  network:
    enabled: true
    cidrBlock: 10.100.0.0/16
```

### 2. Control Plane Configuration

```yaml
# clusters/monitoring/control-plane.yaml
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: KubeadmControlPlane
metadata:
  name: monitoring-control-plane
  namespace: default
spec:
  replicas: 3
  version: v1.31.6
  machineTemplate:
    infrastructureRef:
      apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
      kind: HCloudMachineTemplate
      name: monitoring-control-plane
  kubeadmConfigSpec:
    initConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          cloud-provider: external
          max-pods: "200"
    clusterConfiguration:
      apiServer:
        extraArgs:
          cloud-provider: external
          enable-admission-plugins: "NamespaceLifecycle,LimitRanger,ServiceAccount,DefaultStorageClass,DefaultTolerationSeconds,ResourceQuota,PodSecurityPolicy"
      controllerManager:
        extraArgs:
          cloud-provider: external
          bind-address: 0.0.0.0
      scheduler:
        extraArgs:
          bind-address: 0.0.0.0
      etcd:
        local:
          extraArgs:
            quota-backend-bytes: "8589934592"  # 8GB for larger etcd
    joinConfiguration:
      nodeRegistration:
        kubeletExtraArgs:
          cloud-provider: external
          max-pods: "200"
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: monitoring-control-plane
  namespace: default
spec:
  template:
    spec:
      type: cpx31
      imageName: ubuntu-22.04
      sshKeys:
      - name: cluster-admin-key
      placementGroupName: monitoring-cp-pg
```

### 3. Worker Nodes - Cloud Instances

```yaml
# clusters/monitoring/workers-cloud.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: monitoring-workers-cloud
  namespace: default
spec:
  clusterName: monitoring
  replicas: 3
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: monitoring
      node-type: cloud
  template:
    metadata:
      labels:
        node-type: cloud
        workload: monitoring
    spec:
      clusterName: monitoring
      version: v1.31.6
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfigTemplate
          name: monitoring-workers-cloud
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: HCloudMachineTemplate
        name: monitoring-workers-cloud
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HCloudMachineTemplate
metadata:
  name: monitoring-workers-cloud
  namespace: default
spec:
  template:
    spec:
      type: cpx51  # Higher CPU/RAM for monitoring workloads
      imageName: ubuntu-22.04
      sshKeys:
      - name: cluster-admin-key
      placementGroupName: monitoring-workers-pg
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfigTemplate
metadata:
  name: monitoring-workers-cloud
  namespace: default
spec:
  template:
    spec:
      joinConfiguration:
        nodeRegistration:
          kubeletExtraArgs:
            cloud-provider: external
            max-pods: "200"
          taints:
          - key: workload
            value: monitoring
            effect: NoSchedule
```

### 4. Worker Node - Bare Metal

```yaml
# clusters/monitoring/workers-baremetal.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: monitoring-workers-baremetal
  namespace: default
spec:
  clusterName: monitoring
  replicas: 1
  selector:
    matchLabels:
      cluster.x-k8s.io/cluster-name: monitoring
      node-type: baremetal
  template:
    metadata:
      labels:
        node-type: baremetal
        workload: storage
    spec:
      clusterName: monitoring
      version: v1.31.6
      bootstrap:
        configRef:
          apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
          kind: KubeadmConfigTemplate
          name: monitoring-workers-baremetal
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
        kind: HetznerBareMetalMachineTemplate
        name: monitoring-workers-baremetal
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: HetznerBareMetalMachineTemplate
metadata:
  name: monitoring-workers-baremetal
  namespace: default
spec:
  template:
    spec:
      serverLabels:
        type: "AX41"
      sshSpec:
        secretRef:
          name: robot-ssh
          key:
            privateKey: ssh-privatekey
            publicKey: ssh-publickey
        portAfterCloudInit: 22
      hostSelector:
        matchLabels:
          cluster: monitoring
          type: storage
---
apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
kind: KubeadmConfigTemplate
metadata:
  name: monitoring-workers-baremetal
  namespace: default
spec:
  template:
    spec:
      joinConfiguration:
        nodeRegistration:
          kubeletExtraArgs:
            cloud-provider: external
            max-pods: "250"
          taints:
          - key: node-type
            value: baremetal
            effect: NoSchedule
          - key: workload
            value: storage
            effect: NoSchedule
      preKubeadmCommands:
      - |
        # Setup local NVMe storage for Prometheus/Loki
        mkfs.ext4 /dev/nvme0n1
        mkdir -p /mnt/monitoring-data
        mount /dev/nvme0n1 /mnt/monitoring-data
        echo "/dev/nvme0n1 /mnt/monitoring-data ext4 defaults 0 0" >> /etc/fstab
```

## Monitoring Stack Configuration

### 1. Kube-Prometheus Stack with Thanos

```yaml
# infrastructure/monitoring/prometheus/values.yaml
prometheus:
  prometheusSpec:
    replicas: 2
    retention: 12h  # Short retention, Thanos handles long-term
    retentionSize: 50GB
    
    # Thanos sidecar configuration
    thanos:
      image: quay.io/thanos/thanos:v0.34.0
      version: v0.34.0
      objectStorageConfig:
        name: thanos-objstore-secret
        key: objstore.yml
    
    # Remote write to accept metrics from other clusters
    remoteWrite: []
    
    # Storage configuration
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: hcloud-volumes
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 100Gi
    
    # Node affinity for cloud workers
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: node-type
              operator: In
              values:
              - cloud
    
    tolerations:
    - key: workload
      operator: Equal
      value: monitoring
      effect: NoSchedule
    
    resources:
      requests:
        memory: 8Gi
        cpu: 2
      limits:
        memory: 16Gi
        cpu: 4

# Thanos components
thanosRuler:
  enabled: true
  
thanosQuery:
  enabled: true
  stores:
  - dnssrv+_grpc._tcp.prometheus-operated.monitoring.svc.cluster.local
  
grafana:
  enabled: true
  replicas: 2
  persistence:
    enabled: true
    storageClassName: hcloud-volumes
    size: 50Gi
  
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
    - monitoring.your-domain.com
  
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL
```

### 2. Thanos Configuration

```yaml
# infrastructure/monitoring/thanos/thanos-store.yaml
apiVersion: v1
kind: Secret
metadata:
  name: thanos-objstore-secret
  namespace: monitoring
stringData:
  objstore.yml: |
    type: S3
    config:
      bucket: monitoring-metrics
      endpoint: fsn1.your-s3-provider.com
      access_key: ${S3_ACCESS_KEY}
      secret_key: ${S3_SECRET_KEY}
      insecure: false
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: thanos-store
  namespace: monitoring
spec:
  replicas: 2
  serviceName: thanos-store
  selector:
    matchLabels:
      app: thanos-store
  template:
    metadata:
      labels:
        app: thanos-store
    spec:
      containers:
      - name: thanos
        image: quay.io/thanos/thanos:v0.34.0
        args:
        - store
        - --data-dir=/data
        - --objstore.config-file=/etc/thanos/objstore.yml
        - --http-address=0.0.0.0:10902
        - --grpc-address=0.0.0.0:10901
        volumeMounts:
        - name: data
          mountPath: /data
        - name: objstore-secret
          mountPath: /etc/thanos
      nodeSelector:
        node-type: baremetal
      tolerations:
      - key: node-type
        operator: Equal
        value: baremetal
        effect: NoSchedule
      - key: workload
        operator: Equal
        value: storage
        effect: NoSchedule
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: local-nvme
      resources:
        requests:
          storage: 500Gi
```

### 3. Loki Configuration

```yaml
# infrastructure/monitoring/loki/values.yaml
loki:
  auth_enabled: false
  
  storage:
    type: s3
    s3:
      endpoint: fsn1.your-s3-provider.com
      bucketnames: monitoring-logs
      access_key_id: ${S3_ACCESS_KEY}
      secret_access_key: ${S3_SECRET_KEY}
      s3forcepathstyle: true
  
  schema_config:
    configs:
    - from: 2024-01-01
      store: boltdb-shipper
      object_store: s3
      schema: v11
      index:
        prefix: loki_index_
        period: 24h
  
  ingester:
    chunk_idle_period: 30m
    chunk_retain_period: 1m
    max_chunk_age: 1h
    
  querier:
    max_concurrent: 20
    
  query_scheduler:
    max_outstanding_requests_per_tenant: 2048
    
  distributor:
    ring:
      kvstore:
        store: consul
        
write:
  replicas: 3
  persistence:
    enabled: true
    storageClass: hcloud-volumes
    size: 50Gi
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/component: write
        topologyKey: kubernetes.io/hostname
        
read:
  replicas: 3
  persistence:
    enabled: true
    storageClass: local-nvme
    size: 100Gi
  nodeSelector:
    node-type: baremetal
  tolerations:
  - key: node-type
    operator: Equal
    value: baremetal
    effect: NoSchedule

gateway:
  enabled: true
  ingress:
    enabled: true
    ingressClassName: nginx
    hosts:
    - host: loki.your-domain.com
      paths:
      - path: /
        pathType: Prefix
```

### 4. Grafana Dashboards Configuration

```yaml
# infrastructure/monitoring/grafana/dashboards/cluster-overview.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-overview-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  cluster-overview.json: |
    {
      "dashboard": {
        "title": "Multi-Cluster Overview",
        "panels": [
          {
            "title": "Cluster Health Status",
            "targets": [
              {
                "expr": "up{job=\"kube-state-metrics\"}",
                "legendFormat": "{{cluster}}"
              }
            ]
          },
          {
            "title": "Total CPU Usage by Cluster",
            "targets": [
              {
                "expr": "sum by (cluster) (rate(container_cpu_usage_seconds_total[5m]))",
                "legendFormat": "{{cluster}}"
              }
            ]
          },
          {
            "title": "Total Memory Usage by Cluster",
            "targets": [
              {
                "expr": "sum by (cluster) (container_memory_working_set_bytes)",
                "legendFormat": "{{cluster}}"
              }
            ]
          }
        ]
      }
    }
```

### 5. AlertManager Configuration

```yaml
# infrastructure/monitoring/alertmanager/values.yaml
alertmanager:
  config:
    global:
      resolve_timeout: 5m
      slack_api_url: '${SLACK_WEBHOOK_URL}'
      pagerduty_url: 'https://events.pagerduty.com/v2/enqueue'
    
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'default'
      routes:
      - match:
          severity: critical
        receiver: pagerduty
      - match:
          severity: warning
        receiver: slack
    
    receivers:
    - name: 'default'
      slack_configs:
      - channel: '#alerts'
        title: 'Kubernetes Alert'
        text: '{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}'
        
    - name: 'pagerduty'
      pagerduty_configs:
      - service_key: '${PAGERDUTY_SERVICE_KEY}'
        description: '{{ .GroupLabels.alertname }} - {{ .GroupLabels.cluster }}'
        
    - name: 'slack'
      slack_configs:
      - channel: '#k8s-warnings'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ .CommonAnnotations.summary }}'

  alertmanagerSpec:
    replicas: 3
    retention: 120h
    storage:
      volumeClaimTemplate:
        spec:
          storageClassName: hcloud-volumes
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
```

## Cross-Cluster Monitoring Setup

### 1. Remote Write Configuration for Workload Clusters

```yaml
# To be applied in each workload cluster
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-remote-write
  namespace: kube-system
data:
  remote-write.yaml: |
    remoteWrite:
    - url: https://monitoring.your-domain.com/api/v1/write
      basicAuth:
        username:
          name: prometheus-remote-write-auth
          key: username
        password:
          name: prometheus-remote-write-auth
          key: password
      writeRelabelConfigs:
      - sourceLabels: [__name__]
        regex: 'kube_.*|node_.*|container_.*'
        action: keep
      - targetLabel: cluster
        replacement: ${CLUSTER_NAME}
```

### 2. Vector Agent Configuration for Unified Observability

```yaml
# To be deployed in each workload cluster
# See vector-observability-implementation.md for complete Vector setup
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-config
  namespace: vector-system
data:
  vector.toml: |
    # Vector replaces both Promtail and Prometheus node-exporter
    # Provides unified logs and metrics collection with better performance
    
    [sources.kubernetes_logs]
    type = "kubernetes_logs"
    
    [sources.host_metrics]
    type = "host_metrics"
    
    [sinks.monitoring_cluster]
    type = "vector"
    inputs = ["kubernetes_logs", "host_metrics"]
    address = "vector-aggregator.monitoring.svc.cluster.local:9000"
    
    # See full configuration in vector-observability-implementation.md
```

## Storage Configuration

### 1. Local Storage Class for Bare Metal

```yaml
# infrastructure/monitoring/storage/local-storage.yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: monitoring-nvme-pv
spec:
  capacity:
    storage: 900Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: local-nvme
  local:
    path: /mnt/monitoring-data
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: node-type
          operator: In
          values:
          - baremetal
```

## Monitoring Cluster Bootstrap Script

```bash
#!/bin/bash
# scripts/bootstrap-monitoring-cluster.sh

set -euo pipefail

CLUSTER_NAME="monitoring"
KUBECONFIG_PATH="/tmp/monitoring-kubeconfig"

echo "Creating monitoring cluster..."
kubectl apply -f clusters/monitoring/

echo "Waiting for cluster to be ready..."
kubectl wait --for=condition=ready cluster/${CLUSTER_NAME} --timeout=30m

echo "Getting kubeconfig..."
clusterctl get kubeconfig ${CLUSTER_NAME} > ${KUBECONFIG_PATH}

echo "Installing CNI..."
KUBECONFIG=${KUBECONFIG_PATH} helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --values infrastructure/monitoring/cilium-values.yaml \
  --wait

echo "Installing Cloud Controller Manager..."
KUBECONFIG=${KUBECONFIG_PATH} helm upgrade --install hccm hcloud/hcloud-cloud-controller-manager \
  --namespace kube-system \
  --set env.HCLOUD_TOKEN.valueFrom.secretKeyRef.name=hetzner \
  --set env.HCLOUD_TOKEN.valueFrom.secretKeyRef.key=hcloud \
  --wait

echo "Installing monitoring stack..."
KUBECONFIG=${KUBECONFIG_PATH} kubectl create namespace monitoring

# Install Prometheus with Thanos
KUBECONFIG=${KUBECONFIG_PATH} helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values infrastructure/monitoring/prometheus/values.yaml \
  --wait

# Install Loki
KUBECONFIG=${KUBECONFIG_PATH} helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --values infrastructure/monitoring/loki/values.yaml \
  --wait

echo "Monitoring cluster setup complete!"
echo "Access Grafana at: https://monitoring.your-domain.com"
```

## Integration with ArgoCD

```yaml
# bootstrap/root-apps/monitoring-root-app.yaml
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

This comprehensive monitoring cluster implementation provides centralized observability for all your Kubernetes clusters with proper resource allocation, storage optimization, and high availability.