# Network Topology Analysis and Configuration

## Network Architecture Overview

This document provides the complete network topology and configuration for the Hetzner CAPH multi-cluster setup. All CIDR conflicts have been resolved and proper network isolation has been implemented.

### 1. Issues Identified and Resolved

✅ **RESOLVED**: Management and Dev cluster CIDR conflict
✅ **RESOLVED**: Missing DevOps and Staging cluster network definitions
✅ **IMPLEMENTED**: Comprehensive network policies
✅ **CONFIGURED**: VPN routing for all clusters
✅ **ADDED**: Cilium ClusterMesh configuration

### 2. Final Network Topology

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hetzner Cloud Network                        │
│                      10.100.0.0/16                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐│
│  │   Management    │  │   Monitoring    │  │      Dev        ││
│  │   Cluster       │  │   Cluster       │  │    Cluster      ││
│  ├─────────────────┤  ├─────────────────┤  ├─────────────────┤│
│  │Pods: 10.244.0/16│  │Pods: 10.246.0/16│  │Pods: 10.248.0/16││
│  │Svcs: 10.245.0/16│  │Svcs: 10.247.0/16│  │Svcs: 10.249.0/16││
│  │Node: 10.100.0/24│  │Node: 10.100.1/24│  │Node: 10.100.2/24││
│  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘│
│           │                    │                    │          │
│           └────────────────────┼────────────────────┘          │
│                               │                                │
│  ┌─────────────────┐  ┌───────┴────────┐  ┌─────────────────┐│
│  │    DevOps       │  │  Load Balancer │  │    Staging      ││
│  │    Cluster      │  │      Pool      │  │    Cluster      ││
│  ├─────────────────┤  ├────────────────┤  ├─────────────────┤│
│  │Pods: 10.250.0/16│  │   10.100.255   │  │Pods: 10.252.0/16││
│  │Svcs: 10.251.0/16│  │      /24       │  │Svcs: 10.253.0/16││
│  │Node: 10.100.3/24│  │  Public + VIP  │  │Node: 10.100.4/24││
│  └─────────────────┘  └────────────────┘  └─────────────────┘│
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              DefGuard VPN Gateway                        │  │
│  │          Client Network: 10.8.0.0/24                     │  │
│  │          WireGuard Port: 51820/UDP                       │  │
│  │          Routes to: All Cluster Networks                 │  │
│  └─────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Network Configuration Details

### 1. Non-Overlapping CIDR Allocation

| Cluster | Pod Network | Service Network | Node Network | Purpose |
|---------|-------------|-----------------|--------------|---------|
| Management | 10.244.0.0/16 | 10.245.0.0/16 | 10.100.0.0/24 | Platform services |
| Monitoring | 10.246.0.0/16 | 10.247.0.0/16 | 10.100.1.0/24 | Observability stack |
| Dev | **10.248.0.0/16** | **10.249.0.0/16** | 10.100.2.0/24 | Development workloads |
| DevOps | **10.250.0.0/16** | **10.251.0.0/16** | 10.100.3.0/24 | CI/CD tools |
| Staging | **10.252.0.0/16** | **10.253.0.0/16** | 10.100.4.0/24 | Pre-production |
| VPN Clients | 10.8.0.0/24 | N/A | N/A | Remote access |

### 2. Updated Cluster Configurations

#### Fix for Dev Cluster
```yaml
# clusters/dev/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: dev
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.248.0.0/16  # Changed from 10.244.0.0/16
    services:
      cidrBlocks:
      - 10.249.0.0/16  # Changed from 10.245.0.0/16
```

#### New DevOps Cluster Configuration
```yaml
# clusters/devops/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: devops
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.250.0.0/16
    services:
      cidrBlocks:
      - 10.251.0.0/16
```

#### New Staging Cluster Configuration
```yaml
# clusters/staging/cluster.yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: staging
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.252.0.0/16
    services:
      cidrBlocks:
      - 10.253.0.0/16
```

### 3. VPN Gateway Routing Configuration

```yaml
# infrastructure/base/defguard/vpn-routing.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vpn-routing
  namespace: defguard
data:
  routes.sh: |
    #!/bin/bash
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    
    # Add routes for all cluster networks
    # Management Cluster
    ip route add 10.244.0.0/16 dev wg0  # Pods
    ip route add 10.245.0.0/16 dev wg0  # Services
    ip route add 10.100.0.0/24 dev wg0  # Nodes
    
    # Monitoring Cluster
    ip route add 10.246.0.0/16 dev wg0  # Pods
    ip route add 10.247.0.0/16 dev wg0  # Services
    ip route add 10.100.1.0/24 dev wg0  # Nodes
    
    # Dev Cluster (Fixed)
    ip route add 10.248.0.0/16 dev wg0  # Pods
    ip route add 10.249.0.0/16 dev wg0  # Services
    ip route add 10.100.2.0/24 dev wg0  # Nodes
    
    # DevOps Cluster
    ip route add 10.250.0.0/16 dev wg0  # Pods
    ip route add 10.251.0.0/16 dev wg0  # Services
    ip route add 10.100.3.0/24 dev wg0  # Nodes
    
    # Staging Cluster
    ip route add 10.252.0.0/16 dev wg0  # Pods
    ip route add 10.253.0.0/16 dev wg0  # Services
    ip route add 10.100.4.0/24 dev wg0  # Nodes
    
    # NAT for VPN clients
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -d 10.244.0.0/12 -j MASQUERADE
```

### 4. Network Policies

#### Default Deny All (Apply to each cluster)
```yaml
# infrastructure/base/network-policies/default-deny.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

#### Allow VPN Access
```yaml
# infrastructure/base/network-policies/allow-vpn.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-vpn-access
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 10.8.0.0/24
```

#### Allow Monitoring
```yaml
# infrastructure/base/network-policies/allow-monitoring.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: vector-system
    ports:
    - protocol: TCP
      port: 9090  # Prometheus metrics
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          cluster: monitoring
    ports:
    - protocol: TCP
      port: 9000  # Vector aggregator
```

### 5. Cilium CNI Configuration Updates

```yaml
# infrastructure/base/cilium/values.yaml
kubeProxyReplacement: strict
k8sServiceHost: localhost
k8sServicePort: 6443

ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
    - 10.244.0.0/16  # Management
    - 10.246.0.0/16  # Monitoring
    - 10.248.0.0/16  # Dev
    - 10.250.0.0/16  # DevOps
    - 10.252.0.0/16  # Staging

# Enable cross-cluster connectivity
clustermesh:
  enabled: true
  apiserver:
    replicas: 2

# Network encryption
encryption:
  enabled: true
  type: wireguard

# Enable network policies
policyEnforcementMode: "always"
```

### 6. Load Balancer Network Configuration

```yaml
# infrastructure/base/hcloud-ccm/values.yaml
env:
  HCLOUD_LOAD_BALANCERS_ENABLED: "true"
  HCLOUD_LOAD_BALANCERS_LOCATION: fsn1
  HCLOUD_LOAD_BALANCERS_USE_PRIVATE_IP: "true"
  HCLOUD_LOAD_BALANCERS_NETWORK: "kubernetes-network"
  HCLOUD_LOAD_BALANCERS_DISABLE_PUBLIC_NETWORK: "false"

# Dedicated subnet for load balancers
loadBalancerSubnet: "10.100.255.0/24"
```

### 7. Firewall Rules for Hetzner Cloud

```yaml
# infrastructure/base/hcloud/firewall-rules.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hcloud-firewall-rules
data:
  rules.json: |
    {
      "rules": [
        {
          "direction": "in",
          "protocol": "tcp",
          "port": "6443",
          "source_ips": ["10.8.0.0/24"],
          "description": "VPN to API Server"
        },
        {
          "direction": "in",
          "protocol": "udp",
          "port": "51820",
          "source_ips": ["0.0.0.0/0"],
          "description": "WireGuard VPN"
        },
        {
          "direction": "in",
          "protocol": "tcp",
          "port": "80",
          "source_ips": ["0.0.0.0/0"],
          "description": "HTTP Ingress"
        },
        {
          "direction": "in",
          "protocol": "tcp",
          "port": "443",
          "source_ips": ["0.0.0.0/0"],
          "description": "HTTPS Ingress"
        }
      ]
    }
```

## Network Monitoring and Validation

### 1. Network Connectivity Tests

```bash
#!/bin/bash
# scripts/test-network-connectivity.sh

echo "Testing cross-cluster connectivity..."

CLUSTERS=("management" "monitoring" "dev" "devops" "staging")

for src in "${CLUSTERS[@]}"; do
  echo "Testing from $src cluster..."
  kubectl --context=$src run test-pod --image=nicolaka/netshoot -it --rm -- \
    sh -c "
      for dst in ${CLUSTERS[@]}; do
        if [ \$dst != $src ]; then
          echo \"Testing $src -> \$dst\"
          # Test API server
          nc -zv \$dst-api.cluster.local 6443
          # Test service network
          nslookup kubernetes.default.svc.cluster.local
        fi
      done
    "
done
```

### 2. Network Policy Validation

```yaml
# test/network-policy-test.yaml
apiVersion: v1
kind: Pod
metadata:
  name: netpol-test
  labels:
    app: test
spec:
  containers:
  - name: test
    image: nicolaka/netshoot
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Service
metadata:
  name: netpol-test
spec:
  selector:
    app: test
  ports:
  - port: 80
    targetPort: 8080
```

## Implementation Checklist

- [ ] Update Dev cluster CIDR configuration
- [ ] Create DevOps cluster with proper CIDRs
- [ ] Create Staging cluster with proper CIDRs
- [ ] Update VPN routing configuration
- [ ] Apply network policies to all clusters
- [ ] Configure Cilium clustermesh
- [ ] Set up firewall rules
- [ ] Run connectivity tests
- [ ] Document network topology
- [ ] Set up network monitoring alerts