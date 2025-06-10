# Vector Observability Implementation for Multi-Cluster Setup

## Overview

This guide implements Vector as the unified observability data pipeline for collecting and shipping metrics and logs from all Kubernetes clusters to the centralized monitoring cluster. Vector replaces traditional agents like Promtail and Prometheus node-exporter with a single, high-performance agent.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Monitoring Cluster                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │ Prometheus  │  │    Loki     │  │   Grafana   │        │
│  │   Remote    │  │   Gateway   │  │ Dashboards  │        │
│  │   Write     │  │             │  │             │        │
│  └──────▲──────┘  └──────▲──────┘  └─────────────┘        │
│         │                 │                                 │
└─────────┼─────────────────┼─────────────────────────────────┘
          │                 │
     ┌────┴─────────────────┴────┐
     │    Vector Aggregators     │
     │  (Load Balanced - 3x)     │
     └────▲─────────────────▲────┘
          │                 │
┌─────────┼─────────────────┼─────────────────┐
│         │                 │                 │
│   ┌─────┴──────┐   ┌──────┴──────┐   ┌─────┴──────┐
│   │Management  │   │    Dev      │   │  Staging   │
│   │  Cluster   │   │  Cluster    │   │  Cluster   │
│   │            │   │             │   │            │
│   │ Vector     │   │  Vector     │   │  Vector    │
│   │ Agents     │   │  Agents     │   │  Agents    │
│   └────────────┘   └─────────────┘   └────────────┘
└─────────────────────────────────────────────────────┘
```

## Vector Configuration

### 1. Vector Agent DaemonSet (Source Clusters)

```yaml
# infrastructure/base/vector/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vector-system
---
# infrastructure/base/vector/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-agent-config
  namespace: vector-system
data:
  vector.toml: |
    # Global options
    data_dir = "/var/lib/vector"
    
    # Kubernetes logs source
    [sources.kubernetes_logs]
    type = "kubernetes_logs"
    auto_partial_merge = true
    exclude_paths = ["/var/log/pods/vector-system_*"]
    
    # Host metrics source
    [sources.host_metrics]
    type = "host_metrics"
    collectors = ["cpu", "disk", "filesystem", "load", "memory", "network"]
    
    # Kubernetes metrics (node and pod level)
    [sources.kubernetes_metrics]
    type = "prometheus_scrape"
    endpoints = ["http://127.0.0.1:10250/metrics/cadvisor"]
    scrape_interval_secs = 30
    
    # Transform: Add cluster metadata
    [transforms.add_cluster_metadata]
    type = "remap"
    inputs = ["kubernetes_logs", "host_metrics", "kubernetes_metrics"]
    source = '''
      .cluster = "${CLUSTER_NAME}"
      .environment = "${ENVIRONMENT}"
      .region = "${HCLOUD_REGION}"
      
      # Parse Kubernetes labels
      if exists(.kubernetes) {
        .namespace = .kubernetes.pod_namespace
        .pod = .kubernetes.pod_name
        .container = .kubernetes.container_name
        .labels = .kubernetes.pod_labels
        .node = .kubernetes.pod_node_name
      }
    '''
    
    # Transform: Parse container logs
    [transforms.parse_logs]
    type = "remap"
    inputs = ["add_cluster_metadata"]
    source = '''
      # Only process log events
      if exists(.message) {
        # Try to parse JSON logs
        parsed, err = parse_json(.message)
        if err == null {
          . = merge(., parsed)
        }
        
        # Extract severity/level
        if exists(.level) {
          .severity = .level
        } else if exists(.severity) {
          # Keep existing
        } else {
          .severity = "info"
        }
        
        # Standardize timestamp
        if exists(.timestamp) {
          .timestamp = parse_timestamp!(.timestamp, "%+")
        }
      }
    '''
    
    # Transform: Prometheus remote write format
    [transforms.prometheus_format]
    type = "metric_to_logs"
    inputs = ["add_cluster_metadata"]
    host_tag = "node"
    timezone = "UTC"
    
    # Buffer for reliability
    [sinks.buffer_logs]
    type = "disk"
    inputs = ["parse_logs"]
    max_size = 268435488  # 256MB
    
    [sinks.buffer_metrics]
    type = "disk"
    inputs = ["prometheus_format"]
    max_size = 268435488  # 256MB
    
    # Sink: Send logs to monitoring cluster
    [sinks.monitoring_logs]
    type = "vector"
    inputs = ["buffer_logs"]
    address = "${VECTOR_AGGREGATOR_ENDPOINT}"
    version = "2"
    healthcheck.enabled = true
    
    # TLS configuration
    [sinks.monitoring_logs.tls]
    enabled = true
    ca_file = "/etc/vector/certs/ca.crt"
    crt_file = "/etc/vector/certs/tls.crt"
    key_file = "/etc/vector/certs/tls.key"
    verify_certificate = true
    verify_hostname = true
    
    # Sink: Send metrics to monitoring cluster
    [sinks.monitoring_metrics]
    type = "prometheus_remote_write"
    inputs = ["buffer_metrics"]
    endpoint = "${PROMETHEUS_REMOTE_WRITE_ENDPOINT}"
    healthcheck.enabled = true
    
    # Authentication
    [sinks.monitoring_metrics.auth]
    strategy = "bearer"
    token = "${PROMETHEUS_BEARER_TOKEN}"
    
    # TLS configuration
    [sinks.monitoring_metrics.tls]
    enabled = true
    ca_file = "/etc/vector/certs/ca.crt"
---
# infrastructure/base/vector/daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vector-agent
  namespace: vector-system
spec:
  selector:
    matchLabels:
      name: vector-agent
  template:
    metadata:
      labels:
        name: vector-agent
    spec:
      serviceAccountName: vector-agent
      hostNetwork: true
      hostPID: true
      priorityClassName: system-node-critical
      containers:
      - name: vector
        image: timberio/vector:0.34.0-alpine
        env:
        - name: VECTOR_CONFIG
          value: /etc/vector/vector.toml
        - name: VECTOR_REQUIRE_HEALTHY
          value: "true"
        - name: CLUSTER_NAME
          valueFrom:
            configMapKeyRef:
              name: cluster-config
              key: cluster-name
        - name: ENVIRONMENT
          valueFrom:
            configMapKeyRef:
              name: cluster-config
              key: environment
        - name: HCLOUD_REGION
          value: "${HCLOUD_REGION}"
        - name: VECTOR_AGGREGATOR_ENDPOINT
          value: "vector-aggregator.monitoring.svc.cluster.local:9000"
        - name: PROMETHEUS_REMOTE_WRITE_ENDPOINT
          value: "https://prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
        - name: PROMETHEUS_BEARER_TOKEN
          valueFrom:
            secretKeyRef:
              name: vector-prometheus-auth
              key: token
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        ports:
        - containerPort: 8686
          name: metrics
        - containerPort: 9000
          name: vector
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        volumeMounts:
        - name: config
          mountPath: /etc/vector
          readOnly: true
        - name: data
          mountPath: /var/lib/vector
        - name: var-log
          mountPath: /var/log
          readOnly: true
        - name: var-lib
          mountPath: /var/lib
          readOnly: true
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
        - name: certs
          mountPath: /etc/vector/certs
          readOnly: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8686
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8686
          initialDelaySeconds: 10
          periodSeconds: 5
      volumes:
      - name: config
        configMap:
          name: vector-agent-config
      - name: data
        hostPath:
          path: /var/lib/vector
          type: DirectoryOrCreate
      - name: var-log
        hostPath:
          path: /var/log
      - name: var-lib
        hostPath:
          path: /var/lib
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      - name: certs
        secret:
          secretName: vector-tls
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
---
# infrastructure/base/vector/rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vector-agent
  namespace: vector-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vector-agent
rules:
- apiGroups: [""]
  resources:
  - pods
  - nodes
  - nodes/proxy
  - nodes/metrics
  - services
  - endpoints
  - persistentvolumeclaims
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources:
  - deployments
  - daemonsets
  - replicasets
  - statefulsets
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources:
  - cronjobs
  - jobs
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vector-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: vector-agent
subjects:
- kind: ServiceAccount
  name: vector-agent
  namespace: vector-system
```

### 2. Vector Aggregator (Monitoring Cluster)

```yaml
# infrastructure/monitoring/vector-aggregator/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vector-aggregator
  namespace: monitoring
spec:
  replicas: 3
  selector:
    matchLabels:
      app: vector-aggregator
  template:
    metadata:
      labels:
        app: vector-aggregator
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: vector-aggregator
            topologyKey: kubernetes.io/hostname
      containers:
      - name: vector
        image: timberio/vector:0.34.0-alpine
        env:
        - name: VECTOR_CONFIG
          value: /etc/vector/vector.toml
        - name: LOKI_ENDPOINT
          value: "http://loki-gateway.monitoring.svc.cluster.local:3100"
        ports:
        - containerPort: 9000
          name: vector
          protocol: TCP
        - containerPort: 8686
          name: metrics
          protocol: TCP
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        volumeMounts:
        - name: config
          mountPath: /etc/vector
        - name: data
          mountPath: /var/lib/vector
        livenessProbe:
          httpGet:
            path: /health
            port: 8686
          initialDelaySeconds: 30
          periodSeconds: 10
      volumes:
      - name: config
        configMap:
          name: vector-aggregator-config
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-aggregator-config
  namespace: monitoring
data:
  vector.toml: |
    data_dir = "/var/lib/vector"
    
    # Source: Receive from Vector agents
    [sources.vector_agents]
    type = "vector"
    address = "0.0.0.0:9000"
    version = "2"
    
    # TLS configuration
    [sources.vector_agents.tls]
    enabled = true
    ca_file = "/etc/vector/certs/ca.crt"
    crt_file = "/etc/vector/certs/tls.crt"
    key_file = "/etc/vector/certs/tls.key"
    
    # Transform: Route logs by type
    [transforms.route_logs]
    type = "route"
    inputs = ["vector_agents"]
    route.kubernetes = '.source_type == "kubernetes_logs"'
    route.system = '.source_type == "host_metrics"'
    route.metrics = 'exists(.gauge) || exists(.counter) || exists(.histogram)'
    
    # Transform: Deduplicate logs
    [transforms.dedupe_logs]
    type = "dedupe"
    inputs = ["route_logs.kubernetes"]
    cache_size = 10000
    fields = ["cluster", "namespace", "pod", "container", "message"]
    
    # Transform: Sample high-volume logs
    [transforms.sample_logs]
    type = "sample"
    inputs = ["dedupe_logs"]
    rate = 100  # Keep all logs by default
    key_field = "namespace"
    
    # Conditional sampling for high-volume namespaces
    [transforms.sample_logs.sample_rates]
    "kube-system" = 10  # Sample 1 in 10
    "ingress-nginx" = 5  # Sample 1 in 5
    
    # Buffer for reliability
    [sinks.loki_buffer]
    type = "disk"
    inputs = ["sample_logs"]
    max_size = 1073741824  # 1GB
    
    # Sink: Send logs to Loki
    [sinks.loki]
    type = "loki"
    inputs = ["loki_buffer"]
    endpoint = "${LOKI_ENDPOINT}"
    compression = "gzip"
    
    # Labels for Loki
    labels.cluster = "{{ cluster }}"
    labels.environment = "{{ environment }}"
    labels.namespace = "{{ namespace }}"
    labels.pod = "{{ pod }}"
    labels.container = "{{ container }}"
    labels.node = "{{ node }}"
    labels.severity = "{{ severity }}"
    
    # Encoding
    encoding.codec = "json"
    encoding.timestamp_format = "rfc3339"
    
    # Batch settings
    batch.max_bytes = 1048576  # 1MB
    batch.timeout_secs = 10
    
    # Health check
    healthcheck.enabled = true
    
    # Sink: Internal metrics
    [sinks.internal_metrics]
    type = "prometheus_exporter"
    inputs = ["route_logs.metrics"]
    address = "0.0.0.0:9090"
    
    # Sink: Vector's own metrics
    [sinks.vector_metrics]
    type = "prometheus_exporter"
    inputs = ["internal_metrics_source"]
    address = "0.0.0.0:8686"
    
    [sources.internal_metrics_source]
    type = "internal_metrics"
---
apiVersion: v1
kind: Service
metadata:
  name: vector-aggregator
  namespace: monitoring
spec:
  selector:
    app: vector-aggregator
  ports:
  - name: vector
    port: 9000
    targetPort: 9000
    protocol: TCP
  - name: metrics
    port: 8686
    targetPort: 8686
    protocol: TCP
  type: ClusterIP
---
apiVersion: v1
kind: Service
metadata:
  name: vector-aggregator-lb
  namespace: monitoring
  annotations:
    load-balancer.hetzner.cloud/location: fsn1
    load-balancer.hetzner.cloud/use-private-ip: "true"
    load-balancer.hetzner.cloud/disable-public-network: "true"
spec:
  selector:
    app: vector-aggregator
  ports:
  - name: vector
    port: 9000
    targetPort: 9000
    protocol: TCP
  type: LoadBalancer
```

### 3. Vector Performance Tuning

```yaml
# infrastructure/base/vector/performance-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-performance-tuning
  namespace: vector-system
data:
  vector-performance.toml: |
    # Performance optimizations
    
    # Buffer settings for high throughput
    [sinks.monitoring_logs.buffer]
    type = "memory"
    max_events = 10000
    when_full = "block"
    
    [sinks.monitoring_metrics.buffer]
    type = "memory"
    max_events = 50000
    when_full = "drop_newest"
    
    # Request settings
    [sinks.monitoring_logs.request]
    concurrency = 10
    rate_limit_num = 1000
    rate_limit_duration_secs = 1
    timeout_secs = 30
    retry_attempts = 3
    retry_initial_backoff_secs = 1
    retry_max_backoff_secs = 10
    
    # Batch settings for efficiency
    [sinks.monitoring_logs.batch]
    max_bytes = 5242880  # 5MB
    max_events = 1000
    timeout_secs = 5
    
    [sinks.monitoring_metrics.batch]
    max_bytes = 1048576  # 1MB
    max_events = 10000
    timeout_secs = 10
```

### 4. Monitoring Vector Itself

```yaml
# infrastructure/monitoring/base/prometheus/vector-monitoring.yaml
apiVersion: v1
kind: ServiceMonitor
metadata:
  name: vector-agents
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
    - vector-system
  selector:
    matchLabels:
      app: vector-agent
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
---
apiVersion: v1
kind: ServiceMonitor
metadata:
  name: vector-aggregators
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: vector-aggregator
  endpoints:
  - port: metrics
    interval: 15s
    path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: vector-alerts
  namespace: monitoring
spec:
  groups:
  - name: vector
    interval: 30s
    rules:
    - alert: VectorAgentDown
      expr: up{job="vector-agent"} == 0
      for: 5m
      annotations:
        summary: "Vector agent is down on {{ $labels.node }}"
        description: "Vector agent has been down for more than 5 minutes on node {{ $labels.node }}"
    
    - alert: VectorHighMemoryUsage
      expr: container_memory_usage_bytes{container="vector"} / container_spec_memory_limit_bytes{container="vector"} > 0.8
      for: 10m
      annotations:
        summary: "Vector high memory usage"
        description: "Vector is using more than 80% of its memory limit"
    
    - alert: VectorHighErrorRate
      expr: rate(vector_errors_total[5m]) > 10
      for: 5m
      annotations:
        summary: "Vector high error rate"
        description: "Vector is experiencing more than 10 errors per second"
    
    - alert: VectorBackpressure
      expr: vector_buffer_events{stage="current"} / vector_buffer_events{stage="max"} > 0.8
      for: 10m
      annotations:
        summary: "Vector buffer backpressure"
        description: "Vector buffer is more than 80% full, indicating backpressure"
```

### 5. Security Configuration

```yaml
# infrastructure/base/vector/tls-setup.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vector-tls
  namespace: vector-system
spec:
  secretName: vector-tls
  issuerRef:
    name: cluster-issuer
    kind: ClusterIssuer
  commonName: vector.vector-system.svc.cluster.local
  dnsNames:
  - vector.vector-system.svc.cluster.local
  - vector-aggregator.monitoring.svc.cluster.local
  - "*.vector-system.svc.cluster.local"
  duration: 8760h # 1 year
  renewBefore: 720h # 30 days
---
# Network policy for Vector
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vector-agent-network-policy
  namespace: vector-system
spec:
  podSelector:
    matchLabels:
      name: vector-agent
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 8686
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: monitoring
    ports:
    - protocol: TCP
      port: 9000
  - to:
    - podSelector: {}
    ports:
    - protocol: TCP
      port: 10250  # Kubelet metrics
  - to:
    - namespaceSelector: {}
    ports:
    - protocol: TCP
      port: 53  # DNS
    - protocol: UDP
      port: 53
```

## Grafana Dashboards for Vector

```yaml
# infrastructure/monitoring/base/grafana/dashboards/vector-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vector-overview-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  vector-overview.json: |
    {
      "dashboard": {
        "title": "Vector Observability Pipeline",
        "panels": [
          {
            "title": "Events Processed per Second",
            "targets": [
              {
                "expr": "sum(rate(vector_processed_events_total[5m])) by (cluster)",
                "legendFormat": "{{ cluster }}"
              }
            ]
          },
          {
            "title": "Bytes Processed per Second",
            "targets": [
              {
                "expr": "sum(rate(vector_processed_bytes_total[5m])) by (cluster)",
                "legendFormat": "{{ cluster }}"
              }
            ]
          },
          {
            "title": "Error Rate",
            "targets": [
              {
                "expr": "sum(rate(vector_errors_total[5m])) by (cluster, error_type)",
                "legendFormat": "{{ cluster }} - {{ error_type }}"
              }
            ]
          },
          {
            "title": "Buffer Usage",
            "targets": [
              {
                "expr": "vector_buffer_events{stage=\"current\"} / vector_buffer_events{stage=\"max\"} * 100",
                "legendFormat": "{{ cluster }} - {{ component_name }}"
              }
            ]
          },
          {
            "title": "Component Health",
            "targets": [
              {
                "expr": "vector_component_errors_total",
                "legendFormat": "{{ cluster }} - {{ component_id }}"
              }
            ]
          },
          {
            "title": "Network I/O",
            "targets": [
              {
                "expr": "sum(rate(vector_component_sent_bytes_total[5m])) by (cluster)",
                "legendFormat": "{{ cluster }} - Sent"
              },
              {
                "expr": "sum(rate(vector_component_received_bytes_total[5m])) by (cluster)",
                "legendFormat": "{{ cluster }} - Received"
              }
            ]
          }
        ]
      }
    }
```

## Migration from Existing Agents

### 1. Migration Script

```bash
#!/bin/bash
# scripts/migrate-to-vector.sh

set -euo pipefail

CLUSTER_NAME=$1
ENVIRONMENT=$2

echo "Migrating $CLUSTER_NAME to Vector..."

# Deploy Vector agents
kubectl apply -f infrastructure/base/vector/

# Wait for Vector to be ready
kubectl wait --for=condition=ready pod -l name=vector-agent -n vector-system --timeout=300s

# Verify Vector is collecting metrics
echo "Verifying Vector metrics collection..."
kubectl exec -n vector-system daemonset/vector-agent -- vector top

# Scale down old agents gradually
echo "Scaling down Promtail..."
kubectl scale daemonset promtail -n monitoring --replicas=0

echo "Scaling down node-exporter..."
kubectl scale daemonset node-exporter -n monitoring --replicas=0

# Remove old agents after verification period
echo "Migration complete. Monitor for 24 hours before removing old agents."
```

## Cost and Performance Benefits

### Performance Comparison

| Metric | Traditional Stack | Vector |
|--------|------------------|--------|
| Memory per Node | ~500MB (Promtail + Node Exporter) | ~150MB |
| CPU per Node | ~200m | ~100m |
| Network Overhead | 2 connections per node | 1 connection |
| Data Processing | Limited | Full transformation pipeline |
| Protocol Support | Prometheus + Loki | 40+ sources, 50+ sinks |

### Features Comparison

| Feature | Traditional Stack | Vector |
|---------|------------------|--------|
| Logs Collection | ✅ (Promtail) | ✅ |
| Metrics Collection | ✅ (Node Exporter) | ✅ |
| Traces | ❌ | ✅ |
| Data Transformation | ❌ | ✅ |
| Buffering | Limited | ✅ (Disk/Memory) |
| Multi-destination | ❌ | ✅ |
| Protocol Translation | ❌ | ✅ |

## Deployment Checklist

### Phase 1: Preparation
- [ ] Review current Promtail and Prometheus node-exporter configurations
- [ ] Create Vector configuration based on existing setup
- [ ] Set up TLS certificates for Vector communication
- [ ] Configure monitoring cluster to accept Vector data

### Phase 2: Deployment
- [ ] Deploy Vector aggregators in monitoring cluster
- [ ] Deploy Vector agents to one test cluster
- [ ] Verify data flow and quality
- [ ] Deploy to remaining clusters

### Phase 3: Migration
- [ ] Run Vector alongside existing agents for 48 hours
- [ ] Compare metrics and logs quality
- [ ] Gradually scale down old agents
- [ ] Remove old agent configurations

### Phase 4: Optimization
- [ ] Tune Vector performance settings
- [ ] Implement sampling for high-volume logs
- [ ] Set up Vector-specific dashboards
- [ ] Configure alerts for Vector health

This implementation provides a unified, high-performance observability pipeline that significantly reduces resource usage while providing more features than traditional monitoring agents.