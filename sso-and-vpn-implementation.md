# SSO and VPN Implementation Guide

## Overview

This guide implements Google SSO for all web applications (ArgoCD, Grafana, etc.) and DefGuard WireGuard VPN for secure cluster access in the Hetzner multi-cluster environment.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Google Workspace                        │
│                    (SSO Identity Provider)                  │
└────────────────────────┬───────────────────────────────────┘
                         │ OAuth 2.0 / OIDC
    ┌────────────────────┼────────────────────┐
    │                    │                    │
┌───▼────────┐   ┌───────▼──────┐   ┌────────▼─────┐
│   ArgoCD   │   │   Grafana    │   │  DefGuard    │
│   (Dex)    │   │  (OAuth2)    │   │   (OIDC)     │
└────────────┘   └──────────────┘   └──────────────┘
                                            │
                                     ┌──────▼──────┐
                                     │  WireGuard  │
                                     │   Gateway   │
                                     └──────┬──────┘
                                            │
                        ┌───────────────────┼───────────────────┐
                        │                   │                   │
                  ┌─────▼─────┐      ┌─────▼─────┐      ┌─────▼─────┐
                  │Management │      │Monitoring │      │ Workload  │
                  │  Cluster  │      │  Cluster  │      │ Clusters  │
                  └───────────┘      └───────────┘      └───────────┘
```

## Google SSO Configuration

### 1. Google Cloud Setup

```bash
#!/bin/bash
# scripts/setup-google-sso.sh

# Prerequisites: Google Cloud project with OAuth 2.0 credentials

# Create OAuth 2.0 Client ID in Google Cloud Console:
# 1. Go to APIs & Services > Credentials
# 2. Create OAuth 2.0 Client ID
# 3. Application type: Web application
# 4. Authorized redirect URIs:
#    - https://argocd.your-domain.com/api/dex/callback
#    - https://grafana.your-domain.com/login/generic_oauth
#    - https://defguard.your-domain.com/api/v1/oauth/callback

# Store credentials in AWS Secrets Manager
aws secretsmanager create-secret \
    --name "/hetzner/sso/google-client-id" \
    --secret-string "$GOOGLE_CLIENT_ID" \
    --region $AWS_REGION

aws secretsmanager create-secret \
    --name "/hetzner/sso/google-client-secret" \
    --secret-string "$GOOGLE_CLIENT_SECRET" \
    --region $AWS_REGION

# Allowed domains for SSO
aws secretsmanager create-secret \
    --name "/hetzner/sso/allowed-domains" \
    --secret-string "your-domain.com,your-company.com" \
    --region $AWS_REGION
```

### 2. ArgoCD SSO Configuration

```yaml
# infrastructure/base/argocd/values-sso.yaml
server:
  config:
    url: https://argocd.your-domain.com
    
    # Dex configuration for Google SSO
    dex.config: |
      connectors:
      - type: oidc
        id: google
        name: Google
        config:
          issuer: https://accounts.google.com
          clientId: $sso.google.clientId
          clientSecret: $sso.google.clientSecret
          redirectURI: https://argocd.your-domain.com/api/dex/callback
          hostedDomains:
          - $sso.allowedDomains
          scopes:
          - openid
          - profile
          - email
          getUserInfo: true
          insecureEnableGroups: true
    
    # RBAC configuration
    policy.csv: |
      # Map Google groups to ArgoCD roles
      g, platform-team@your-domain.com, role:admin
      g, dev-team@your-domain.com, role:developer
      g, devops-team@your-domain.com, role:devops
      
      # Role definitions
      p, role:developer, applications, get, */*, allow
      p, role:developer, applications, sync, dev/*, allow
      p, role:developer, logs, get, dev/*, allow
      p, role:developer, exec, create, dev/*, allow
      
      p, role:devops, applications, *, devops/*, allow
      p, role:devops, repositories, *, *, allow
      p, role:devops, clusters, get, *, allow
    
    policy.default: role:readonly

# External secret for SSO credentials
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argocd-sso-secret
  namespace: argocd
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: argocd-secret
    template:
      data:
        sso.google.clientId: "{{ .googleClientId }}"
        sso.google.clientSecret: "{{ .googleClientSecret }}"
        sso.allowedDomains: "{{ .allowedDomains }}"
  data:
  - secretKey: googleClientId
    remoteRef:
      key: /hetzner/sso/google-client-id
  - secretKey: googleClientSecret
    remoteRef:
      key: /hetzner/sso/google-client-secret
  - secretKey: allowedDomains
    remoteRef:
      key: /hetzner/sso/allowed-domains
```

### 3. Grafana SSO Configuration

```yaml
# infrastructure/monitoring/base/grafana/values-sso.yaml
grafana:
  envFromSecret: grafana-sso-secret
  
  grafana.ini:
    server:
      domain: grafana.your-domain.com
      root_url: https://grafana.your-domain.com
      
    auth:
      disable_login_form: false
      oauth_auto_login: true
      
    auth.generic_oauth:
      enabled: true
      name: Google
      allow_sign_up: true
      client_id: $__env{GF_AUTH_GOOGLE_CLIENT_ID}
      client_secret: $__env{GF_AUTH_GOOGLE_CLIENT_SECRET}
      scopes: openid email profile
      email_attribute_name: email
      email_attribute_path: email
      auth_url: https://accounts.google.com/o/oauth2/v2/auth
      token_url: https://oauth2.googleapis.com/token
      api_url: https://www.googleapis.com/oauth2/v2/userinfo
      allowed_domains: your-domain.com
      hosted_domain: your-domain.com
      role_attribute_path: |
        contains(groups[*], 'platform-team@your-domain.com') && 'Admin' || 
        contains(groups[*], 'devops-team@your-domain.com') && 'Editor' ||
        'Viewer'
      role_attribute_strict: true
      allow_assign_grafana_admin: true

---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: grafana-sso-secret
  namespace: monitoring
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: grafana-sso-secret
    template:
      data:
        GF_AUTH_GOOGLE_CLIENT_ID: "{{ .googleClientId }}"
        GF_AUTH_GOOGLE_CLIENT_SECRET: "{{ .googleClientSecret }}"
  data:
  - secretKey: googleClientId
    remoteRef:
      key: /hetzner/sso/google-client-id
  - secretKey: googleClientSecret
    remoteRef:
      key: /hetzner/sso/google-client-secret
```

## DefGuard VPN Implementation

### 1. DefGuard Deployment

```yaml
# infrastructure/base/defguard/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: defguard
---
# infrastructure/base/defguard/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: defguard
  namespace: defguard
spec:
  replicas: 2
  selector:
    matchLabels:
      app: defguard
  template:
    metadata:
      labels:
        app: defguard
    spec:
      containers:
      - name: defguard
        image: ghcr.io/defguard/defguard:latest
        ports:
        - containerPort: 8000
          name: http
        env:
        - name: DEFGUARD_URL
          value: "https://vpn.your-domain.com"
        - name: DEFGUARD_ADMIN_USER
          value: "admin@your-domain.com"
        - name: DEFGUARD_DB_HOST
          value: "postgres.defguard.svc.cluster.local"
        - name: DEFGUARD_DB_NAME
          value: "defguard"
        - name: DEFGUARD_LDAP_URL
          value: ""  # Optional LDAP integration
        - name: DEFGUARD_OIDC_ENABLED
          value: "true"
        - name: DEFGUARD_OIDC_CLIENT_ID
          valueFrom:
            secretKeyRef:
              name: defguard-sso-secret
              key: client-id
        - name: DEFGUARD_OIDC_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: defguard-sso-secret
              key: client-secret
        - name: DEFGUARD_OIDC_ISSUER_URL
          value: "https://accounts.google.com"
        - name: DEFGUARD_OIDC_REDIRECT_URL
          value: "https://vpn.your-domain.com/api/v1/oauth/callback"
        - name: DEFGUARD_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: defguard-secret
              key: secret-key
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: defguard-data
---
apiVersion: v1
kind: Service
metadata:
  name: defguard
  namespace: defguard
spec:
  selector:
    app: defguard
  ports:
  - port: 8000
    targetPort: 8000
    name: http
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: defguard
  namespace: defguard
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - vpn.your-domain.com
    secretName: defguard-tls
  rules:
  - host: vpn.your-domain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: defguard
            port:
              number: 8000
```

### 2. WireGuard Gateway Configuration

```yaml
# infrastructure/base/defguard/wireguard-gateway.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: wireguard-config
  namespace: defguard
data:
  setup.sh: |
    #!/bin/bash
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    # Setup WireGuard interface
    ip link add dev wg0 type wireguard
    ip addr add 10.8.0.1/24 dev wg0
    wg setconf wg0 /etc/wireguard/wg0.conf
    ip link set up dev wg0
    
    # Setup NAT for VPN clients
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
    
    # Setup routing to cluster networks
    ip route add 10.244.0.0/16 dev wg0  # Pod network
    ip route add 10.245.0.0/16 dev wg0  # Service network
    ip route add 10.100.0.0/16 dev wg0  # Hetzner private network
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wireguard-gateway
  namespace: defguard
spec:
  selector:
    matchLabels:
      app: wireguard-gateway
  template:
    metadata:
      labels:
        app: wireguard-gateway
    spec:
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        effect: NoSchedule
      initContainers:
      - name: sysctl
        image: busybox
        securityContext:
          privileged: true
        command:
        - sh
        - -c
        - |
          sysctl -w net.ipv4.ip_forward=1
          sysctl -w net.ipv6.conf.all.forwarding=1
      containers:
      - name: wireguard
        image: ghcr.io/defguard/gateway:latest
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - SYS_MODULE
          privileged: true
        env:
        - name: DEFGUARD_URL
          value: "http://defguard.defguard.svc.cluster.local:8000"
        - name: DEFGUARD_TOKEN
          valueFrom:
            secretKeyRef:
              name: defguard-gateway-token
              key: token
        - name: DEFGUARD_GATEWAY_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
        - name: DEFGUARD_GATEWAY_PUBLIC_IP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        ports:
        - containerPort: 51820
          protocol: UDP
          hostPort: 51820
        volumeMounts:
        - name: wireguard-config
          mountPath: /etc/wireguard
        - name: host-modules
          mountPath: /lib/modules
          readOnly: true
      volumes:
      - name: wireguard-config
        configMap:
          name: wireguard-config
      - name: host-modules
        hostPath:
          path: /lib/modules
```

### 3. PostgreSQL for DefGuard

```yaml
# infrastructure/base/defguard/postgres.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: defguard
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
  storageClassName: hcloud-volumes
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: defguard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        env:
        - name: POSTGRES_DB
          value: defguard
        - name: POSTGRES_USER
          value: defguard
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
          subPath: postgres
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "512Mi"
            cpu: "500m"
      volumes:
      - name: postgres-storage
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: defguard
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
```

## Network Architecture with VPN

### 1. Cluster Network Configuration

```yaml
# infrastructure/overlays/management/patches/vpn-network-policy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-vpn-access
  namespace: kube-system
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  ingress:
  - from:
    - ipBlock:
        cidr: 10.8.0.0/24  # VPN client network
    ports:
    - protocol: TCP
      port: 6443  # Kubernetes API
---
apiVersion: v1
kind: Service
metadata:
  name: kubernetes-vpn
  namespace: default
spec:
  type: LoadBalancer
  loadBalancerSourceRanges:
  - 10.8.0.0/24  # Only allow VPN clients
  ports:
  - port: 6443
    targetPort: 6443
    protocol: TCP
  selector:
    component: kube-apiserver
```

### 2. VPN Client Configuration Template

```yaml
# Generated by DefGuard for each user
[Interface]
PrivateKey = <user-private-key>
Address = 10.8.0.X/32
DNS = 10.245.0.10  # Cluster DNS

[Peer]
PublicKey = <gateway-public-key>
Endpoint = vpn-gateway.your-domain.com:51820
AllowedIPs = 10.244.0.0/16, 10.245.0.0/16, 10.100.0.0/16
PersistentKeepalive = 25
```

## User Access Management

### 1. User Onboarding Script

```bash
#!/bin/bash
# scripts/onboard-user.sh

set -euo pipefail

USER_EMAIL=$1
USER_ROLE=${2:-viewer}  # admin, developer, devops, viewer

echo "Onboarding user: $USER_EMAIL with role: $USER_ROLE"

# 1. Ensure user exists in Google Workspace
# (This would be done via Google Admin SDK)

# 2. Add user to appropriate Google Group based on role
case $USER_ROLE in
  admin)
    GOOGLE_GROUP="platform-team@your-domain.com"
    K8S_ROLE="cluster-admin"
    ;;
  developer)
    GOOGLE_GROUP="dev-team@your-domain.com"
    K8S_ROLE="developer"
    ;;
  devops)
    GOOGLE_GROUP="devops-team@your-domain.com"
    K8S_ROLE="devops"
    ;;
  *)
    GOOGLE_GROUP="users@your-domain.com"
    K8S_ROLE="viewer"
    ;;
esac

# 3. Create Kubernetes RBAC for direct kubectl access via VPN
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oidc-${USER_EMAIL}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${K8S_ROLE}
subjects:
- kind: User
  name: ${USER_EMAIL}
  apiGroup: rbac.authorization.k8s.io
EOF

# 4. Create DefGuard user (via API)
curl -X POST https://vpn.your-domain.com/api/v1/users \
  -H "Authorization: Bearer $DEFGUARD_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "'$USER_EMAIL'",
    "first_name": "'$(echo $USER_EMAIL | cut -d@ -f1)'",
    "last_name": "User",
    "groups": ["'$GOOGLE_GROUP'"]
  }'

echo "User onboarded successfully!"
echo "Next steps:"
echo "1. User should login to DefGuard at https://vpn.your-domain.com"
echo "2. Download and install DefGuard client"
echo "3. Configure VPN connection"
echo "4. Access clusters via kubectl with VPN connected"
```

### 2. Kubeconfig Template for VPN Users

```yaml
# ~/.kube/config template for VPN users
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: <base64-encoded-ca-cert>
    server: https://10.100.1.1:6443  # Internal IP via VPN
  name: management
- cluster:
    certificate-authority-data: <base64-encoded-ca-cert>
    server: https://10.100.2.1:6443
  name: monitoring
- cluster:
    certificate-authority-data: <base64-encoded-ca-cert>
    server: https://10.100.3.1:6443
  name: dev
contexts:
- context:
    cluster: management
    user: google-oidc
  name: management
- context:
    cluster: monitoring
    user: google-oidc
  name: monitoring
- context:
    cluster: dev
    user: google-oidc
  name: dev
current-context: management
users:
- name: google-oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      args:
      - oidc-login
      - get-token
      - --oidc-issuer-url=https://accounts.google.com
      - --oidc-client-id=<google-client-id>
      - --oidc-client-secret=<google-client-secret>
      - --oidc-extra-scope=email
      - --oidc-extra-scope=profile
```

## Security Best Practices

### 1. Google Workspace Configuration

```yaml
# Recommended Google Workspace settings:
# 1. Enable 2-Step Verification for all users
# 2. Configure Advanced Protection Program for admins
# 3. Set up Context-Aware Access policies
# 4. Enable security keys (FIDO2) for critical accounts

# Group structure:
# - platform-team@your-domain.com (Admin access)
# - dev-team@your-domain.com (Developer access)
# - devops-team@your-domain.com (DevOps access)
# - contractors@your-domain.com (Limited access)
```

### 2. Network Security

```yaml
# infrastructure/base/network-policies/vpn-isolation.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: vpn-gateway-isolation
  namespace: defguard
spec:
  podSelector:
    matchLabels:
      app: wireguard-gateway
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - protocol: UDP
      port: 51820
  egress:
  - to:
    - ipBlock:
        cidr: 10.0.0.0/8  # All private networks
  - to:
    - namespaceSelector:
        matchLabels:
          name: defguard
    ports:
    - protocol: TCP
      port: 8000
```

### 3. Audit and Compliance

```yaml
# infrastructure/base/audit/defguard-audit.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: defguard-audit-config
  namespace: defguard
data:
  audit.yaml: |
    # DefGuard audit configuration
    audit:
      enabled: true
      retention_days: 90
      events:
        - user_login
        - user_logout
        - vpn_connect
        - vpn_disconnect
        - user_created
        - user_modified
        - user_deleted
        - mfa_enabled
        - mfa_disabled
      forward_to:
        - type: webhook
          url: https://monitoring.your-domain.com/api/audit
        - type: syslog
          host: syslog.monitoring.svc.cluster.local
          port: 514
```

## Monitoring and Alerting

### 1. VPN Metrics

```yaml
# infrastructure/monitoring/base/prometheus/vpn-metrics.yaml
apiVersion: v1
kind: ServiceMonitor
metadata:
  name: defguard-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: defguard
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: vpn-alerts
  namespace: monitoring
spec:
  groups:
  - name: vpn
    interval: 30s
    rules:
    - alert: VPNGatewayDown
      expr: up{job="defguard"} == 0
      for: 5m
      annotations:
        summary: "VPN Gateway is down"
        description: "DefGuard VPN gateway has been down for more than 5 minutes"
    
    - alert: HighVPNConnections
      expr: defguard_active_connections > 100
      for: 10m
      annotations:
        summary: "High number of VPN connections"
        description: "More than 100 active VPN connections detected"
    
    - alert: FailedAuthentications
      expr: rate(defguard_auth_failures_total[5m]) > 10
      for: 5m
      annotations:
        summary: "High authentication failure rate"
        description: "More than 10 failed authentications per minute"
```

### 2. Grafana Dashboard for VPN

```json
{
  "dashboard": {
    "title": "VPN Access Dashboard",
    "panels": [
      {
        "title": "Active VPN Connections",
        "targets": [
          {
            "expr": "defguard_active_connections"
          }
        ]
      },
      {
        "title": "Authentication Success Rate",
        "targets": [
          {
            "expr": "rate(defguard_auth_success_total[5m]) / (rate(defguard_auth_success_total[5m]) + rate(defguard_auth_failures_total[5m])) * 100"
          }
        ]
      },
      {
        "title": "VPN Traffic",
        "targets": [
          {
            "expr": "rate(defguard_bytes_transmitted_total[5m])"
          }
        ]
      },
      {
        "title": "Connected Users",
        "targets": [
          {
            "expr": "defguard_connected_users_info"
          }
        ]
      }
    ]
  }
}
```

## Implementation Checklist

### Phase 1: SSO Setup (Week 1)
- [ ] Create Google Cloud project and OAuth credentials
- [ ] Configure Google Workspace groups
- [ ] Deploy External Secrets for SSO credentials
- [ ] Configure ArgoCD with Google SSO
- [ ] Configure Grafana with Google SSO
- [ ] Test SSO authentication flows

### Phase 2: VPN Infrastructure (Week 2)
- [ ] Deploy DefGuard in management cluster
- [ ] Configure PostgreSQL backend
- [ ] Set up WireGuard gateways on control plane nodes
- [ ] Configure network policies for VPN access
- [ ] Create DefGuard ingress with TLS

### Phase 3: Integration (Week 3)
- [ ] Configure DefGuard with Google SSO
- [ ] Set up user synchronization
- [ ] Create onboarding automation scripts
- [ ] Configure Kubernetes OIDC authentication
- [ ] Test end-to-end access flow

### Phase 4: Monitoring & Documentation (Week 4)
- [ ] Deploy VPN monitoring and alerting
- [ ] Create Grafana dashboards
- [ ] Document user onboarding process
- [ ] Create troubleshooting guides
- [ ] Conduct security review

This implementation provides:
- **Centralized Authentication**: Google SSO for all web applications
- **Secure Access**: WireGuard VPN for kubectl and direct cluster access
- **Zero Trust**: MFA required for all connections
- **Audit Trail**: Complete logging of access and actions
- **Scalability**: Supports hundreds of concurrent users
- **High Availability**: Redundant VPN gateways across control plane nodes