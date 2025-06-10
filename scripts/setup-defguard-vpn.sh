#!/bin/bash
# scripts/setup-defguard-vpn.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DEFGUARD_NAMESPACE="defguard"
DEFGUARD_VERSION="latest"
POSTGRES_PASSWORD=$(openssl rand -base64 32)
DEFGUARD_SECRET_KEY=$(openssl rand -base64 32)
DOMAIN=${DOMAIN:-"your-domain.com"}

print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

check_prerequisites() {
    print_message $BLUE "Checking prerequisites..."
    
    if ! command -v kubectl &> /dev/null; then
        print_message $RED "kubectl is required but not installed."
        exit 1
    fi
    
    if ! command -v helm &> /dev/null; then
        print_message $RED "helm is required but not installed."
        exit 1
    fi
    
    print_message $GREEN "Prerequisites check passed!"
}

create_namespace() {
    print_message $BLUE "Creating DefGuard namespace..."
    kubectl create namespace $DEFGUARD_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -
}

create_secrets() {
    print_message $BLUE "Creating secrets..."
    
    # PostgreSQL secret
    kubectl create secret generic postgres-secret \
        --from-literal=password="$POSTGRES_PASSWORD" \
        --namespace $DEFGUARD_NAMESPACE \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # DefGuard secret
    kubectl create secret generic defguard-secret \
        --from-literal=secret-key="$DEFGUARD_SECRET_KEY" \
        --namespace $DEFGUARD_NAMESPACE \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Create External Secret for SSO
    cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: defguard-sso-secret
  namespace: $DEFGUARD_NAMESPACE
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: defguard-sso-secret
    template:
      data:
        client-id: "{{ .googleClientId }}"
        client-secret: "{{ .googleClientSecret }}"
  data:
  - secretKey: googleClientId
    remoteRef:
      key: /hetzner/sso/google-client-id
  - secretKey: googleClientSecret
    remoteRef:
      key: /hetzner/sso/google-client-secret
EOF
}

deploy_postgres() {
    print_message $BLUE "Deploying PostgreSQL..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: $DEFGUARD_NAMESPACE
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
  namespace: $DEFGUARD_NAMESPACE
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
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: postgres-storage
          mountPath: /var/lib/postgresql/data
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
  namespace: $DEFGUARD_NAMESPACE
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF
    
    print_message $YELLOW "Waiting for PostgreSQL to be ready..."
    kubectl wait --for=condition=ready pod -l app=postgres -n $DEFGUARD_NAMESPACE --timeout=300s
}

deploy_defguard() {
    print_message $BLUE "Deploying DefGuard..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: defguard-data
  namespace: $DEFGUARD_NAMESPACE
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: hcloud-volumes
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: defguard
  namespace: $DEFGUARD_NAMESPACE
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
      initContainers:
      - name: wait-for-postgres
        image: busybox:1.35
        command: ['sh', '-c', 'until nc -z postgres 5432; do echo waiting for postgres; sleep 2; done;']
      containers:
      - name: defguard
        image: ghcr.io/defguard/defguard:$DEFGUARD_VERSION
        ports:
        - containerPort: 8000
          name: http
        env:
        - name: DEFGUARD_URL
          value: "https://vpn.$DOMAIN"
        - name: DEFGUARD_ADMIN_USER
          value: "admin@$DOMAIN"
        - name: DEFGUARD_DB_HOST
          value: "postgres.$DEFGUARD_NAMESPACE.svc.cluster.local"
        - name: DEFGUARD_DB_PORT
          value: "5432"
        - name: DEFGUARD_DB_NAME
          value: "defguard"
        - name: DEFGUARD_DB_USER
          value: "defguard"
        - name: DEFGUARD_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-secret
              key: password
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
          value: "https://vpn.$DOMAIN/api/v1/oauth/callback"
        - name: DEFGUARD_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: defguard-secret
              key: secret-key
        - name: DEFGUARD_DISABLE_STATS
          value: "false"
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
        livenessProbe:
          httpGet:
            path: /api/v1/health
            port: 8000
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /api/v1/health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: defguard-data
---
apiVersion: v1
kind: Service
metadata:
  name: defguard
  namespace: $DEFGUARD_NAMESPACE
  labels:
    app: defguard
spec:
  selector:
    app: defguard
  ports:
  - port: 8000
    targetPort: 8000
    name: http
  - port: 9100
    targetPort: 9100
    name: metrics
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: defguard
  namespace: $DEFGUARD_NAMESPACE
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - vpn.$DOMAIN
    secretName: defguard-tls
  rules:
  - host: vpn.$DOMAIN
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: defguard
            port:
              number: 8000
EOF
    
    print_message $YELLOW "Waiting for DefGuard to be ready..."
    kubectl wait --for=condition=ready pod -l app=defguard -n $DEFGUARD_NAMESPACE --timeout=300s
}

deploy_wireguard_gateway() {
    print_message $BLUE "Deploying WireGuard Gateway..."
    
    # Generate gateway token
    GATEWAY_TOKEN=$(openssl rand -hex 32)
    
    kubectl create secret generic defguard-gateway-token \
        --from-literal=token="$GATEWAY_TOKEN" \
        --namespace $DEFGUARD_NAMESPACE \
        --dry-run=client -o yaml | kubectl apply -f -
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: wireguard-config
  namespace: $DEFGUARD_NAMESPACE
data:
  setup.sh: |
    #!/bin/bash
    # Enable IP forwarding
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv6.conf.all.forwarding=1
    
    # Setup NAT for VPN clients
    iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
    
    # Setup routing to cluster networks
    ip route add 10.244.0.0/16 dev wg0 || true  # Pod network
    ip route add 10.245.0.0/16 dev wg0 || true  # Service network
    ip route add 10.100.0.0/16 dev wg0 || true  # Hetzner private network
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: wireguard-gateway
  namespace: $DEFGUARD_NAMESPACE
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
          value: "http://defguard.$DEFGUARD_NAMESPACE.svc.cluster.local:8000"
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
        - name: DEFGUARD_GATEWAY_NETWORK
          value: "10.8.0.0/24"
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
EOF
}

create_network_policies() {
    print_message $BLUE "Creating network policies..."
    
    cat <<EOF | kubectl apply -f -
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
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: defguard-access
  namespace: $DEFGUARD_NAMESPACE
spec:
  podSelector:
    matchLabels:
      app: defguard
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8000
  - from:
    - podSelector:
        matchLabels:
          app: wireguard-gateway
    ports:
    - protocol: TCP
      port: 8000
EOF
}

create_monitoring() {
    print_message $BLUE "Creating monitoring configuration..."
    
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceMonitor
metadata:
  name: defguard-metrics
  namespace: $DEFGUARD_NAMESPACE
spec:
  selector:
    matchLabels:
      app: defguard
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
EOF
}

print_summary() {
    print_message $GREEN "\nDefGuard VPN deployment completed!"
    print_message $BLUE "\nAccess Information:"
    echo "  DefGuard URL: https://vpn.$DOMAIN"
    echo "  Admin User: admin@$DOMAIN"
    echo "  WireGuard Port: 51820/UDP"
    
    print_message $YELLOW "\nNext Steps:"
    echo "1. Configure DNS to point vpn.$DOMAIN to your ingress IP"
    echo "2. Access DefGuard web interface and complete setup"
    echo "3. Create VPN locations and configure gateways"
    echo "4. Onboard users through the web interface"
    echo "5. Users can download DefGuard client from: https://github.com/DefGuard/client/releases"
    
    print_message $BLUE "\nUseful Commands:"
    echo "  View logs: kubectl logs -n $DEFGUARD_NAMESPACE -l app=defguard"
    echo "  View gateway logs: kubectl logs -n $DEFGUARD_NAMESPACE -l app=wireguard-gateway"
    echo "  Get gateway token: kubectl get secret -n $DEFGUARD_NAMESPACE defguard-gateway-token -o jsonpath='{.data.token}' | base64 -d"
}

# Main execution
main() {
    print_message $BLUE "DefGuard VPN Setup for Hetzner Kubernetes Clusters"
    print_message $BLUE "=================================================="
    
    check_prerequisites
    create_namespace
    create_secrets
    deploy_postgres
    deploy_defguard
    deploy_wireguard_gateway
    create_network_policies
    create_monitoring
    print_summary
}

# Run main function
main