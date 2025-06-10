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
    echo "6. Create SSO secrets"
    echo "7. List secrets"
    echo "8. Backup all secrets"
    echo "9. Rotate a secret"
    echo "10. Delete a secret"
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
                            create_sso_secrets
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
                create_sso_secrets
                ;;
            7)
                read -p "Enter filter (or press enter for all): " filter
                list_secrets "${filter}*"
                ;;
            8)
                backup_secrets
                ;;
            9)
                read -p "Enter secret name to rotate: " secret_name
                rotate_secret "$secret_name"
                ;;
            10)
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

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Script is being executed, run main
    main
fi