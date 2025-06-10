#!/bin/bash
# scripts/install-argocd.sh

set -euo pipefail

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common-functions.sh"

# Source environment variables
source .envrc || { echo "Please create .envrc file first"; exit 1; }

echo -e "${BLUE}Installing ArgoCD on Management Cluster${NC}"

# Ensure we're using the management cluster context
export KUBECONFIG=kubeconfig-management

# Check cluster connectivity
kubectl cluster-info || {
    echo -e "${RED}Cannot connect to management cluster. Please run init-management-cluster.sh first${NC}"
    exit 1
}

# Add ArgoCD Helm repository
echo -e "${BLUE}Adding ArgoCD Helm repository...${NC}"
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create ArgoCD namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Generate ArgoCD admin password
ARGOCD_ADMIN_PASSWORD=$(openssl rand -base64 14)
ARGOCD_ADMIN_PASSWORD_BCRYPT=$(htpasswd -nbBC 10 "" "$ARGOCD_ADMIN_PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')

# Create ArgoCD values file
cat > bootstrap/management-cluster/argocd/argocd-values.yaml <<EOF
global:
  image:
    tag: v2.10.0

redis-ha:
  enabled: true

controller:
  replicas: 2

server:
  replicas: 2
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: argocd.mgmt.${BASE_DOMAIN}
    tls: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
      external-dns.alpha.kubernetes.io/hostname: argocd.mgmt.${BASE_DOMAIN}

repoServer:
  replicas: 2

applicationSet:
  replicas: 2

configs:
  params:
    server.insecure: false
    server.grpc.insecure: false
  
  secret:
    argocdServerAdminPassword: "${ARGOCD_ADMIN_PASSWORD_BCRYPT}"
  
  repositories:
    infrastructure:
      url: https://github.com/${GITHUB_ORG}/kubernetes-infrastructure
      name: infrastructure
      type: git
      username: ${GITHUB_USER}
      password: ${GITHUB_TOKEN}

  rbac:
    policy.default: role:readonly
    policy.csv: |
      p, role:admin, applications, *, */*, allow
      p, role:admin, clusters, *, *, allow
      p, role:admin, repositories, *, *, allow
      g, platform-team, role:admin
      g, dev-team, role:developer
      g, devops-team, role:devops
EOF

# Install cert-manager first (required for TLS)
echo -e "${BLUE}Installing cert-manager...${NC}"
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.14.0 \
    --set installCRDs=true \
    --wait

# Create Let's Encrypt cluster issuer
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@${BASE_DOMAIN}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: admin@${BASE_DOMAIN}
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
    - http01:
        ingress:
          class: nginx
EOF

# Install ingress-nginx
echo -e "${BLUE}Installing ingress-nginx...${NC}"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --set controller.replicaCount=2 \
    --set controller.service.type=LoadBalancer \
    --set controller.service.annotations."load-balancer\.hetzner\.cloud/location"=fsn1 \
    --set controller.service.annotations."load-balancer\.hetzner\.cloud/use-private-ip"="false" \
    --set controller.service.annotations."load-balancer\.hetzner\.cloud/name"=management-ingress \
    --wait

# Get Load Balancer IP (wait for it to be assigned)
echo -e "${BLUE}Waiting for Load Balancer IP...${NC}"
LB_IP=""
while [ -z "$LB_IP" ]; do
    LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -z "$LB_IP" ]; then
        echo -e "${YELLOW}Waiting for Load Balancer IP assignment...${NC}"
        sleep 10
    fi
done
echo -e "${GREEN}Load Balancer IP: $LB_IP${NC}"

# Install External DNS (optional, requires Route53 setup)
if [[ -n "${AWS_REGION:-}" ]]; then
    echo -e "${BLUE}Installing External DNS...${NC}"
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update
    
    kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
    
    # Note: This requires IAM role/policy setup for Route53
    helm upgrade --install external-dns bitnami/external-dns \
        --namespace external-dns \
        --set provider=aws \
        --set aws.region=${AWS_REGION} \
        --set domainFilters[0]=mgmt.${BASE_DOMAIN} \
        --set policy=sync \
        --set txtOwnerId=management-cluster \
        --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="arn:aws:iam::${AWS_ACCOUNT_ID}:role/management-external-dns" \
        --wait || {
            echo -e "${YELLOW}External DNS installation failed. Please configure AWS IAM roles first.${NC}"
        }
fi

# Install ArgoCD
echo -e "${BLUE}Installing ArgoCD...${NC}"
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd \
    --values bootstrap/management-cluster/argocd/argocd-values.yaml \
    --wait

# Wait for ArgoCD to be ready
echo -e "${BLUE}Waiting for ArgoCD to be ready...${NC}"
kubectl -n argocd wait --for=condition=available deployment --all --timeout=300s

# Create GitHub repository secret
kubectl create secret generic github-repo \
    --from-literal=username=${GITHUB_USER} \
    --from-literal=password=${GITHUB_TOKEN} \
    --namespace argocd \
    --dry-run=client -o yaml | kubectl apply -f -

# Save credentials securely
CREDS_FILE="argocd-credentials.txt"
cat > "$CREDS_FILE" <<EOF
ArgoCD Admin Credentials
========================
URL: https://argocd.mgmt.${BASE_DOMAIN}
Username: admin
Password: ${ARGOCD_ADMIN_PASSWORD}

Load Balancer IP: ${LB_IP}

DNS Configuration:
Please create an A record pointing argocd.mgmt.${BASE_DOMAIN} to ${LB_IP}

IMPORTANT: This file contains sensitive credentials.
Please save these credentials in a secure password manager and delete this file.
EOF

# Set restrictive permissions
chmod 600 "$CREDS_FILE"

# Display security warning
echo -e "${GREEN}ArgoCD credentials saved to: $CREDS_FILE${NC}"
echo -e "${RED}WARNING: This file contains sensitive credentials!${NC}"
echo -e "${YELLOW}Please:${NC}"
echo -e "${YELLOW}1. Save these credentials in a secure password manager${NC}"
echo -e "${YELLOW}2. Delete this file: rm $CREDS_FILE${NC}"
echo -e "${YELLOW}3. Consider using SSO instead of admin password${NC}"

# Optionally store in AWS Secrets Manager if available
if command -v aws >/dev/null 2>&1 && [[ -n "${AWS_PROFILE:-}" || -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    read -p "Store ArgoCD credentials in AWS Secrets Manager? (yes/no): " store_aws
    if [[ "$store_aws" == "yes" ]]; then
        aws_cli secretsmanager create-secret \
            --name "/hetzner/argocd/admin-credentials" \
            --description "ArgoCD admin credentials for management cluster" \
            --secret-string "{\"url\":\"https://argocd.mgmt.${BASE_DOMAIN}\",\"username\":\"admin\",\"password\":\"${ARGOCD_ADMIN_PASSWORD}\"}" \
            --region "${AWS_REGION}" 2>/dev/null || \
        aws_cli secretsmanager update-secret \
            --secret-id "/hetzner/argocd/admin-credentials" \
            --secret-string "{\"url\":\"https://argocd.mgmt.${BASE_DOMAIN}\",\"username\":\"admin\",\"password\":\"${ARGOCD_ADMIN_PASSWORD}\"}" \
            --region "${AWS_REGION}"
        
        echo -e "${GREEN}Credentials stored in AWS Secrets Manager${NC}"
        if [[ -n "${AWS_PROFILE:-}" ]]; then
            echo -e "${YELLOW}Retrieve with: aws secretsmanager get-secret-value --secret-id /hetzner/argocd/admin-credentials --profile ${AWS_PROFILE}${NC}"
        else
            echo -e "${YELLOW}Retrieve with: aws secretsmanager get-secret-value --secret-id /hetzner/argocd/admin-credentials${NC}"
        fi
    fi
fi

echo -e "${GREEN}✅ ArgoCD installed successfully!${NC}"
echo -e "${GREEN}Credentials saved to: argocd-credentials.txt${NC}"
echo ""
echo -e "${YELLOW}Important: Please configure DNS:${NC}"
echo -e "Create an A record: argocd.mgmt.${BASE_DOMAIN} -> ${LB_IP}"
echo ""
echo -e "${BLUE}Access ArgoCD:${NC}"
echo -e "URL: https://argocd.mgmt.${BASE_DOMAIN}"
echo -e "Username: admin"
echo -e "Password: ${ARGOCD_ADMIN_PASSWORD}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "1. Configure DNS records"
echo "2. Access ArgoCD UI and verify login"
echo "3. Apply root applications: ./scripts/apply-root-apps.sh"