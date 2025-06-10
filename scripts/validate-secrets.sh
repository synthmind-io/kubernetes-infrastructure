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