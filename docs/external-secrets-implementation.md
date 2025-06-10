# External Secrets Implementation with AWS Secrets Manager

## Overview

This guide implements External Secrets Operator (ESO) with AWS Secrets Manager as the backend for centralized secret management across all Kubernetes clusters in the Hetzner infrastructure.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                 AWS Secrets Manager                     │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │ /hetzner/   │  │ /hetzner/   │  │ /hetzner/   │    │
│  │ management/ │  │ monitoring/ │  │ workload/   │    │
│  │ secrets     │  │ secrets     │  │ secrets     │    │
│  └─────────────┘  └─────────────┘  └─────────────┘    │
└────────────────────────┬───────────────────────────────┘
                         │
    ┌────────────────────┼────────────────────┐
    │                    │                    │
┌───▼────────┐   ┌───────▼──────┐   ┌────────▼─────┐
│Management  │   │  Monitoring  │   │  Workload    │
│  Cluster   │   │   Cluster    │   │  Clusters    │
│            │   │              │   │              │
│ESO + IRSA  │   │ ESO + IRSA   │   │ ESO + IRSA   │
└────────────┘   └──────────────┘   └──────────────┘
```

## External Secrets Operator Configuration

### 1. ESO Installation

```yaml
# infrastructure/base/external-secrets/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
- name: external-secrets
  repo: https://charts.external-secrets.io
  version: 0.9.11
  releaseName: external-secrets
  namespace: external-secrets-system
  valuesFile: values.yaml

resources:
- namespace.yaml
- cluster-secret-store.yaml
```

```yaml
# infrastructure/base/external-secrets/values.yaml
replicaCount: 2

serviceAccount:
  create: true
  annotations:
    # This will be replaced per cluster with actual IAM role
    eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${CLUSTER_NAME}-external-secrets"

webhook:
  replicaCount: 2

certController:
  replicaCount: 2

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

# Enable metrics
metrics:
  service:
    enabled: true

# Pod disruption budget
podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

### 2. Cluster Secret Store Configuration

```yaml
# infrastructure/base/external-secrets/cluster-secret-store.yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets-system
---
# Per-environment secret stores
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: hetzner-secrets
  namespace: kube-system
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets-system
```

### 3. External Secret Examples

```yaml
# infrastructure/base/external-secrets/examples/hetzner-credentials.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: hetzner
  namespace: kube-system
spec:
  refreshInterval: 15m
  secretStoreRef:
    name: hetzner-secrets
    kind: SecretStore
  target:
    name: hetzner
    creationPolicy: Owner
    template:
      metadata:
        labels:
          clusterctl.cluster.x-k8s.io/move: ""
  data:
  - secretKey: hcloud
    remoteRef:
      key: /hetzner/${CLUSTER_NAME}/hcloud-token
  - secretKey: robot-user
    remoteRef:
      key: /hetzner/${CLUSTER_NAME}/robot-user
  - secretKey: robot-password
    remoteRef:
      key: /hetzner/${CLUSTER_NAME}/robot-password
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: argocd-github-creds
  namespace: argocd
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: github-repo
    creationPolicy: Owner
  data:
  - secretKey: username
    remoteRef:
      key: /hetzner/github/username
  - secretKey: password
    remoteRef:
      key: /hetzner/github/token
```

## AWS IAM Configuration

### 1. IAM Policy for External Secrets

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": [
        "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:/hetzner/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "secretsmanager:ResourceTag/hetzner-cluster": "${CLUSTER_NAME}"
        }
      }
    }
  ]
}
```

### 2. IRSA (IAM Roles for Service Accounts) Setup

```yaml
# For non-EKS clusters, we'll use OIDC provider setup
apiVersion: v1
kind: ConfigMap
metadata:
  name: irsa-setup
  namespace: kube-system
data:
  setup.sh: |
    #!/bin/bash
    # This creates an OIDC provider for non-EKS Kubernetes clusters
    
    CLUSTER_NAME=$1
    OIDC_PROVIDER_URL=$2
    
    # Create OIDC provider in AWS
    aws iam create-open-id-connect-provider \
      --url $OIDC_PROVIDER_URL \
      --client-id-list sts.amazonaws.com \
      --thumbprint-list "$(openssl s_client -servername $OIDC_PROVIDER_URL -showcerts -connect $OIDC_PROVIDER_URL:443 < /dev/null 2>/dev/null | openssl x509 -fingerprint -sha1 -noout | cut -d'=' -f2 | tr -d ':')"
```

## Secret Management Scripts

### 1. Master Secret Management Script

```bash
#!/bin/bash
# scripts/manage-secrets.sh

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
AWS_REGION="${AWS_REGION:-eu-central-1}"
SECRET_PREFIX="/hetzner"
ENVIRONMENTS=("management" "monitoring" "dev" "devops" "staging")

# Function to print colored output
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    print_message $BLUE "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_message $RED "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_message $RED "AWS credentials not configured. Please run 'aws configure'."
        exit 1
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        print_message $RED "jq is not installed. Please install it first."
        exit 1
    fi
    
    print_message $GREEN "Prerequisites check passed!"
}

# Function to create or update a secret
create_or_update_secret() {
    local secret_name=$1
    local secret_value=$2
    local description=$3
    local tags=$4
    
    # Check if secret exists
    if aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION" &> /dev/null; then
        print_message $YELLOW "Updating existing secret: $secret_name"
        aws secretsmanager update-secret \
            --secret-id "$secret_name" \
            --secret-string "$secret_value" \
            --description "$description" \
            --region "$AWS_REGION"
    else
        print_message $GREEN "Creating new secret: $secret_name"
        aws secretsmanager create-secret \
            --name "$secret_name" \
            --secret-string "$secret_value" \
            --description "$description" \
            --tags "$tags" \
            --region "$AWS_REGION"
    fi
}

# Function to create Hetzner secrets
create_hetzner_secrets() {
    local environment=$1
    
    print_message $BLUE "Creating Hetzner secrets for $environment environment..."
    
    # Prompt for Hetzner Cloud token
    read -sp "Enter Hetzner Cloud token for $environment: " hcloud_token
    echo
    
    # Create HCloud token secret
    create_or_update_secret \
        "${SECRET_PREFIX}/${environment}/hcloud-token" \
        "$hcloud_token" \
        "Hetzner Cloud API token for $environment cluster" \
        "Key=hetzner-cluster,Value=$environment Key=type,Value=hcloud-token"
    
    # Check if we need Robot credentials
    read -p "Do you need Hetzner Robot credentials for $environment? (y/n): " need_robot
    
    if [[ "$need_robot" == "y" ]]; then
        read -p "Enter Hetzner Robot username: " robot_user
        read -sp "Enter Hetzner Robot password: " robot_password
        echo
        
        create_or_update_secret \
            "${SECRET_PREFIX}/${environment}/robot-user" \
            "$robot_user" \
            "Hetzner Robot username for $environment cluster" \
            "Key=hetzner-cluster,Value=$environment Key=type,Value=robot-user"
        
        create_or_update_secret \
            "${SECRET_PREFIX}/${environment}/robot-password" \
            "$robot_password" \
            "Hetzner Robot password for $environment cluster" \
            "Key=hetzner-cluster,Value=$environment Key=type,Value=robot-password"
    fi
}

# Function to create GitHub secrets
create_github_secrets() {
    print_message $BLUE "Creating GitHub secrets..."
    
    read -p "Enter GitHub username: " github_user
    read -sp "Enter GitHub personal access token: " github_token
    echo
    
    create_or_update_secret \
        "${SECRET_PREFIX}/github/username" \
        "$github_user" \
        "GitHub username for GitOps" \
        "Key=type,Value=github Key=usage,Value=gitops"
    
    create_or_update_secret \
        "${SECRET_PREFIX}/github/token" \
        "$github_token" \
        "GitHub personal access token for GitOps" \
        "Key=type,Value=github Key=usage,Value=gitops"
}

# Function to create monitoring secrets
create_monitoring_secrets() {
    print_message $BLUE "Creating monitoring secrets..."
    
    # S3 credentials for Thanos/Loki
    read -p "Enter S3 access key for monitoring: " s3_access_key
    read -sp "Enter S3 secret key for monitoring: " s3_secret_key
    echo
    
    create_or_update_secret \
        "${SECRET_PREFIX}/monitoring/s3-access-key" \
        "$s3_access_key" \
        "S3 access key for monitoring storage" \
        "Key=type,Value=s3 Key=usage,Value=monitoring"
    
    create_or_update_secret \
        "${SECRET_PREFIX}/monitoring/s3-secret-key" \
        "$s3_secret_key" \
        "S3 secret key for monitoring storage" \
        "Key=type,Value=s3 Key=usage,Value=monitoring"
    
    # Alerting integrations
    read -p "Enter Slack webhook URL (press enter to skip): " slack_webhook
    if [[ -n "$slack_webhook" ]]; then
        create_or_update_secret \
            "${SECRET_PREFIX}/monitoring/slack-webhook" \
            "$slack_webhook" \
            "Slack webhook for alerts" \
            "Key=type,Value=slack Key=usage,Value=alerting"
    fi
    
    read -p "Enter PagerDuty service key (press enter to skip): " pagerduty_key
    if [[ -n "$pagerduty_key" ]]; then
        create_or_update_secret \
            "${SECRET_PREFIX}/monitoring/pagerduty-key" \
            "$pagerduty_key" \
            "PagerDuty service key for critical alerts" \
            "Key=type,Value=pagerduty Key=usage,Value=alerting"
    fi
}

# Function to create SSO secrets
create_sso_secrets() {
    print_message $BLUE "Creating SSO secrets..."
    
    read -p "Enter Google OAuth Client ID: " google_client_id
    read -sp "Enter Google OAuth Client Secret: " google_client_secret
    echo
    
    create_or_update_secret \
        "${SECRET_PREFIX}/sso/google-client-id" \
        "$google_client_id" \
        "Google OAuth Client ID for SSO" \
        "Key=type,Value=sso Key=provider,Value=google"
    
    create_or_update_secret \
        "${SECRET_PREFIX}/sso/google-client-secret" \
        "$google_client_secret" \
        "Google OAuth Client Secret for SSO" \
        "Key=type,Value=sso Key=provider,Value=google"
    
    read -p "Enter allowed email domains (comma-separated): " allowed_domains
    create_or_update_secret \
        "${SECRET_PREFIX}/sso/allowed-domains" \
        "$allowed_domains" \
        "Allowed email domains for SSO" \
        "Key=type,Value=sso Key=usage,Value=domain-whitelist"
}

# Function to create ArgoCD secrets
create_argocd_secrets() {
    print_message $BLUE "Creating ArgoCD secrets..."
    
    read -p "Enter ArgoCD admin password: " argocd_password
    
    # Hash the password using bcrypt
    hashed_password=$(htpasswd -nbBC 10 "" "$argocd_password" | tr -d ':\n' | sed 's/$2y/$2a/')
    
    create_or_update_secret \
        "${SECRET_PREFIX}/argocd/admin-password" \
        "$hashed_password" \
        "ArgoCD admin password (bcrypt hashed)" \
        "Key=type,Value=argocd Key=usage,Value=auth"
    
    # OIDC configuration
    read -p "Configure OIDC for ArgoCD? (y/n): " configure_oidc
    if [[ "$configure_oidc" == "y" ]]; then
        read -p "Enter OIDC client ID: " oidc_client_id
        read -sp "Enter OIDC client secret: " oidc_client_secret
        echo
        
        create_or_update_secret \
            "${SECRET_PREFIX}/argocd/oidc-client-id" \
            "$oidc_client_id" \
            "OIDC client ID for ArgoCD" \
            "Key=type,Value=oidc Key=usage,Value=argocd"
        
        create_or_update_secret \
            "${SECRET_PREFIX}/argocd/oidc-client-secret" \
            "$oidc_client_secret" \
            "OIDC client secret for ArgoCD" \
            "Key=type,Value=oidc Key=usage,Value=argocd"
    fi
}

# Function to list secrets
list_secrets() {
    local filter=$1
    print_message $BLUE "Listing secrets with filter: $filter"
    
    aws secretsmanager list-secrets \
        --region "$AWS_REGION" \
        --filters Key=name,Values="${SECRET_PREFIX}/${filter}" \
        --query 'SecretList[*].[Name,Description,LastChangedDate]' \
        --output table
}

# Function to backup secrets
backup_secrets() {
    local backup_dir="secrets-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"
    
    print_message $BLUE "Backing up secrets to $backup_dir..."
    
    # Get all secrets
    secrets=$(aws secretsmanager list-secrets \
        --region "$AWS_REGION" \
        --filters Key=name,Values="${SECRET_PREFIX}/" \
        --query 'SecretList[*].Name' \
        --output text)
    
    for secret in $secrets; do
        print_message $YELLOW "Backing up $secret..."
        secret_file="${backup_dir}/$(echo $secret | tr '/' '_').json"
        
        # Get secret value and metadata
        aws secretsmanager describe-secret \
            --secret-id "$secret" \
            --region "$AWS_REGION" > "${secret_file}.metadata.json"
        
        aws secretsmanager get-secret-value \
            --secret-id "$secret" \
            --region "$AWS_REGION" \
            --query 'SecretString' \
            --output text > "${secret_file}.value"
    done
    
    # Create a tar archive
    tar -czf "${backup_dir}.tar.gz" "$backup_dir"
    rm -rf "$backup_dir"
    
    print_message $GREEN "Backup completed: ${backup_dir}.tar.gz"
}

# Function to rotate a secret
rotate_secret() {
    local secret_name=$1
    
    print_message $BLUE "Rotating secret: $secret_name"
    
    # Get current secret
    current_value=$(aws secretsmanager get-secret-value \
        --secret-id "$secret_name" \
        --region "$AWS_REGION" \
        --query 'SecretString' \
        --output text)
    
    print_message $YELLOW "Current value: [HIDDEN]"
    read -sp "Enter new value: " new_value
    echo
    
    # Update the secret
    aws secretsmanager update-secret \
        --secret-id "$secret_name" \
        --secret-string "$new_value" \
        --region "$AWS_REGION"
    
    print_message $GREEN "Secret rotated successfully!"
}

# Function to delete a secret
delete_secret() {
    local secret_name=$1
    
    print_message $YELLOW "WARNING: This will schedule the secret for deletion!"
    read -p "Are you sure you want to delete $secret_name? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        aws secretsmanager delete-secret \
            --secret-id "$secret_name" \
            --recovery-window-in-days 7 \
            --region "$AWS_REGION"
        
        print_message $GREEN "Secret scheduled for deletion in 7 days"
    else
        print_message $BLUE "Deletion cancelled"
    fi
}

# Main menu
show_menu() {
    echo
    print_message $BLUE "=== Hetzner Kubernetes Secrets Manager ==="
    echo "1. Create all secrets for an environment"
    echo "2. Create Hetzner secrets only"
    echo "3. Create GitHub secrets"
    echo "4. Create monitoring secrets"
    echo "5. Create ArgoCD secrets"
    echo "6. List secrets"
    echo "7. Backup all secrets"
    echo "8. Rotate a secret"
    echo "9. Delete a secret"
    echo "0. Exit"
    echo
}

# Main script
main() {
    check_prerequisites
    
    while true; do
        show_menu
        read -p "Select an option: " choice
        
        case $choice in
            1)
                print_message $BLUE "Select environment:"
                select env in "${ENVIRONMENTS[@]}"; do
                    if [[ -n "$env" ]]; then
                        create_hetzner_secrets "$env"
                        if [[ "$env" == "management" ]]; then
                            create_github_secrets
                            create_argocd_secrets
                        fi
                        if [[ "$env" == "monitoring" ]]; then
                            create_monitoring_secrets
                        fi
                        break
                    fi
                done
                ;;
            2)
                print_message $BLUE "Select environment:"
                select env in "${ENVIRONMENTS[@]}"; do
                    if [[ -n "$env" ]]; then
                        create_hetzner_secrets "$env"
                        break
                    fi
                done
                ;;
            3)
                create_github_secrets
                ;;
            4)
                create_monitoring_secrets
                ;;
            5)
                create_argocd_secrets
                ;;
            6)
                read -p "Enter filter (or press enter for all): " filter
                list_secrets "${filter}*"
                ;;
            7)
                backup_secrets
                ;;
            8)
                read -p "Enter secret name to rotate: " secret_name
                rotate_secret "$secret_name"
                ;;
            9)
                read -p "Enter secret name to delete: " secret_name
                delete_secret "$secret_name"
                ;;
            0)
                print_message $GREEN "Goodbye!"
                exit 0
                ;;
            *)
                print_message $RED "Invalid option!"
                ;;
        esac
    done
}

# Run main function
main
```

### 2. Secret Validation Script

```bash
#!/bin/bash
# scripts/validate-secrets.sh

set -euo pipefail

# Configuration
AWS_REGION="${AWS_REGION:-eu-central-1}"
SECRET_PREFIX="/hetzner"

# Required secrets per environment
declare -A REQUIRED_SECRETS
REQUIRED_SECRETS["management"]="hcloud-token"
REQUIRED_SECRETS["monitoring"]="hcloud-token s3-access-key s3-secret-key"
REQUIRED_SECRETS["dev"]="hcloud-token"
REQUIRED_SECRETS["devops"]="hcloud-token robot-user robot-password"
REQUIRED_SECRETS["staging"]="hcloud-token robot-user robot-password"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

validate_environment() {
    local env=$1
    local missing=0
    
    echo -e "${YELLOW}Validating secrets for $env environment...${NC}"
    
    for secret in ${REQUIRED_SECRETS[$env]}; do
        secret_name="${SECRET_PREFIX}/${env}/${secret}"
        
        if aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION" &> /dev/null; then
            echo -e "${GREEN}✓ $secret_name${NC}"
        else
            echo -e "${RED}✗ $secret_name (MISSING)${NC}"
            ((missing++))
        fi
    done
    
    # Check common secrets for management cluster
    if [[ "$env" == "management" ]]; then
        for secret in "github/username" "github/token" "argocd/admin-password"; do
            secret_name="${SECRET_PREFIX}/${secret}"
            
            if aws secretsmanager describe-secret --secret-id "$secret_name" --region "$AWS_REGION" &> /dev/null; then
                echo -e "${GREEN}✓ $secret_name${NC}"
            else
                echo -e "${RED}✗ $secret_name (MISSING)${NC}"
                ((missing++))
            fi
        done
    fi
    
    if [[ $missing -eq 0 ]]; then
        echo -e "${GREEN}All required secrets are present for $env!${NC}"
    else
        echo -e "${RED}Missing $missing required secrets for $env${NC}"
        return 1
    fi
}

# Validate all environments
all_valid=true
for env in management monitoring dev devops staging; do
    echo
    if ! validate_environment "$env"; then
        all_valid=false
    fi
done

echo
if $all_valid; then
    echo -e "${GREEN}All environments have required secrets!${NC}"
    exit 0
else
    echo -e "${RED}Some environments are missing required secrets${NC}"
    exit 1
fi
```

### 3. IAM Setup Script

```bash
#!/bin/bash
# scripts/setup-iam-for-external-secrets.sh

set -euo pipefail

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION="${AWS_REGION:-eu-central-1}"
CLUSTERS=("management" "monitoring" "dev" "devops" "staging")

# Create IAM policy for External Secrets
create_iam_policy() {
    local policy_name="HetznerExternalSecretsPolicy"
    
    cat > /tmp/external-secrets-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetResourcePolicy",
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
        "secretsmanager:ListSecretVersionIds"
      ],
      "Resource": [
        "arn:aws:secretsmanager:${AWS_REGION}:${AWS_ACCOUNT_ID}:secret:/hetzner/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets"
      ],
      "Resource": "*"
    }
  ]
}
EOF

    # Create or update policy
    if aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" &> /dev/null; then
        echo "Updating existing policy..."
        POLICY_VERSION=$(aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" --query 'Policy.DefaultVersionId' --output text)
        aws iam create-policy-version \
            --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${policy_name}" \
            --policy-document file:///tmp/external-secrets-policy.json \
            --set-as-default
    else
        echo "Creating new policy..."
        aws iam create-policy \
            --policy-name "${policy_name}" \
            --policy-document file:///tmp/external-secrets-policy.json
    fi
    
    rm /tmp/external-secrets-policy.json
}

# Create IAM role for each cluster
create_iam_role() {
    local cluster_name=$1
    local oidc_provider=$2
    local role_name="${cluster_name}-external-secrets"
    
    # Create trust policy
    cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${oidc_provider}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${oidc_provider}:sub": "system:serviceaccount:external-secrets-system:external-secrets",
          "${oidc_provider}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

    # Create or update role
    if aws iam get-role --role-name "${role_name}" &> /dev/null; then
        echo "Updating trust policy for role ${role_name}..."
        aws iam update-assume-role-policy \
            --role-name "${role_name}" \
            --policy-document file:///tmp/trust-policy.json
    else
        echo "Creating role ${role_name}..."
        aws iam create-role \
            --role-name "${role_name}" \
            --assume-role-policy-document file:///tmp/trust-policy.json
    fi
    
    # Attach policy to role
    aws iam attach-role-policy \
        --role-name "${role_name}" \
        --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/HetznerExternalSecretsPolicy"
    
    # Tag the role
    aws iam tag-role \
        --role-name "${role_name}" \
        --tags Key=Cluster,Value="${cluster_name}" Key=Purpose,Value=external-secrets
    
    rm /tmp/trust-policy.json
    
    echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${role_name}"
}

# Main execution
echo "Setting up IAM for External Secrets..."

# Create the policy
create_iam_policy

# For each cluster, you'll need to provide the OIDC provider endpoint
echo
echo "To complete the setup, run the following for each cluster after it's created:"
echo
for cluster in "${CLUSTERS[@]}"; do
    echo "# For ${cluster} cluster:"
    echo "OIDC_PROVIDER=\$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer | sed 's|https://||')"
    echo "./setup-iam-for-external-secrets.sh create-role ${cluster} \$OIDC_PROVIDER"
    echo
done

# Handle role creation if called with parameters
if [[ "${1:-}" == "create-role" ]] && [[ -n "${2:-}" ]] && [[ -n "${3:-}" ]]; then
    create_iam_role "$2" "$3"
fi
```

### 4. Quick Setup Script

```bash
#!/bin/bash
# scripts/quick-setup-secrets.sh

# Quick setup for development environment
set -euo pipefail

echo "Quick Secret Setup for Hetzner Kubernetes"
echo "========================================"
echo

# Check if AWS CLI is configured
if ! aws sts get-caller-identity &> /dev/null; then
    echo "Please configure AWS CLI first:"
    echo "aws configure"
    exit 1
fi

# Source the main script functions
source "$(dirname "$0")/manage-secrets.sh"

# Run prerequisites check
check_prerequisites

# Setup secrets for all environments
for env in management monitoring dev devops staging; do
    echo
    echo "Setting up $env environment..."
    
    # Set default values for development
    if [[ "${USE_DEFAULTS:-}" == "true" ]]; then
        # Use environment variables or defaults
        HCLOUD_TOKEN="${HCLOUD_TOKEN:-dummy-token-$env}"
        ROBOT_USER="${ROBOT_USER:-robot-user}"
        ROBOT_PASSWORD="${ROBOT_PASSWORD:-robot-pass}"
        
        create_or_update_secret \
            "/hetzner/${env}/hcloud-token" \
            "$HCLOUD_TOKEN" \
            "Hetzner Cloud token for $env" \
            "Key=hetzner-cluster,Value=$env"
        
        if [[ "$env" =~ ^(devops|staging)$ ]]; then
            create_or_update_secret \
                "/hetzner/${env}/robot-user" \
                "$ROBOT_USER" \
                "Robot user for $env" \
                "Key=hetzner-cluster,Value=$env"
            
            create_or_update_secret \
                "/hetzner/${env}/robot-password" \
                "$ROBOT_PASSWORD" \
                "Robot password for $env" \
                "Key=hetzner-cluster,Value=$env"
        fi
    else
        # Interactive setup
        create_hetzner_secrets "$env"
    fi
done

# Setup common secrets
if [[ "${USE_DEFAULTS:-}" == "true" ]]; then
    # GitHub
    create_or_update_secret "/hetzner/github/username" "git" "GitHub username" "Key=type,Value=github"
    create_or_update_secret "/hetzner/github/token" "dummy-github-token" "GitHub token" "Key=type,Value=github"
    
    # ArgoCD
    create_or_update_secret "/hetzner/argocd/admin-password" '$2a$10$rBi6jCkV8YGtlWKxB9hBkuHoraloIY8LFx.AQsK1M2XYJ7fwnfUGO' "ArgoCD admin password" "Key=type,Value=argocd"
    
    # Monitoring
    create_or_update_secret "/hetzner/monitoring/s3-access-key" "dummy-s3-key" "S3 access key" "Key=type,Value=s3"
    create_or_update_secret "/hetzner/monitoring/s3-secret-key" "dummy-s3-secret" "S3 secret key" "Key=type,Value=s3"
fi

echo
echo "Running validation..."
./validate-secrets.sh

echo
echo "Setup complete!"
```

## Integration with Cluster Deployment

### 1. Bootstrap External Secrets in Cluster

```yaml
# infrastructure/base/external-secrets/bootstrap.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets-system
  annotations:
    # This annotation will be patched per cluster
    eks.amazonaws.com/role-arn: "arn:aws:iam::ACCOUNT_ID:role/CLUSTER_NAME-external-secrets"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: external-secrets-view
rules:
- apiGroups: ["external-secrets.io"]
  resources: ["externalsecrets", "secretstores", "clustersecretstores"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: external-secrets-view
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: external-secrets-view
subjects:
- kind: Group
  name: system:authenticated
  apiGroup: rbac.authorization.k8s.io
```

### 2. Kustomization Overlay per Environment

```yaml
# infrastructure/overlays/dev/external-secrets-patch.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: external-secrets
  namespace: external-secrets-system
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/dev-external-secrets"
---
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: eu-central-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets-system
```

This comprehensive implementation provides:

1. **Centralized Secret Management**: All secrets stored in AWS Secrets Manager
2. **Automated Scripts**: Easy creation, rotation, and validation of secrets
3. **IAM Integration**: Proper IRSA setup for secure access
4. **Environment Isolation**: Separate secrets per cluster/environment
5. **GitOps Ready**: External Secrets automatically sync from AWS to Kubernetes

The scripts handle the complete lifecycle of secrets management while maintaining security best practices.