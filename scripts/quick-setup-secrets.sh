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