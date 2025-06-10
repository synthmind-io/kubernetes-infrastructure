#!/bin/bash
# scripts/configure-environment.sh
# Interactive script to configure .envrc file

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Environment Configuration Helper${NC}"
echo -e "${BLUE}This script will help you configure your .envrc file${NC}"
echo ""

# Check if .envrc exists
if [[ -f .envrc ]]; then
    echo -e "${YELLOW}Found existing .envrc file${NC}"
    read -p "Do you want to update it? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting without changes."
        exit 0
    fi
    # Backup existing file
    cp .envrc .envrc.backup.$(date +%Y%m%d-%H%M%S)
    echo -e "${GREEN}Backed up existing .envrc${NC}"
else
    # Copy from example
    cp .envrc.example .envrc
    echo -e "${GREEN}Created new .envrc from template${NC}"
fi

# Function to update or add environment variable
update_env_var() {
    local var_name=$1
    local prompt=$2
    local default_value=${3:-}
    local is_secret=${4:-false}
    
    # Get current value if exists
    current_value=$(grep "^export $var_name=" .envrc 2>/dev/null | cut -d'"' -f2 || echo "")
    
    # Use default if no current value
    if [[ -z "$current_value" ]] && [[ -n "$default_value" ]]; then
        current_value=$default_value
    fi
    
    # Show current value (masked if secret)
    if [[ -n "$current_value" ]]; then
        if [[ "$is_secret" == "true" ]]; then
            echo -e "Current $var_name: ${current_value:0:4}****"
        else
            echo -e "Current $var_name: $current_value"
        fi
    fi
    
    # Prompt for new value
    if [[ "$is_secret" == "true" ]]; then
        read -s -p "$prompt [press Enter to keep current]: " new_value
        echo
    else
        read -p "$prompt [press Enter to keep current]: " new_value
    fi
    
    # Update if new value provided
    if [[ -n "$new_value" ]]; then
        # Escape special characters for sed
        escaped_new_value=$(printf '%s\n' "$new_value" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i.tmp "s|^export $var_name=.*|export $var_name=\"$escaped_new_value\"|" .envrc
        rm -f .envrc.tmp
        echo -e "${GREEN}✓ Updated $var_name${NC}"
    else
        echo -e "${YELLOW}↳ Keeping current value${NC}"
    fi
}

# Hetzner Configuration
echo -e "\n${BLUE}=== Hetzner Configuration ===${NC}"
update_env_var "HCLOUD_TOKEN" "Hetzner Cloud API token" "" true
update_env_var "HETZNER_SSH_KEY" "SSH key name for Hetzner" "hetzner-k8s" false

# AWS Configuration
echo -e "\n${BLUE}=== AWS Configuration ===${NC}"

# Check if AWS CLI is configured with profiles
aws_profiles=$(aws configure list-profiles 2>/dev/null || echo "")
if [[ -n "$aws_profiles" ]]; then
    echo -e "${BLUE}Available AWS profiles:${NC}"
    echo "$aws_profiles" | while read -r profile; do
        echo "  - $profile"
    done
    echo ""
    
    read -p "Do you want to use an AWS profile instead of credentials? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "Enter AWS profile name: " aws_profile
        if [[ -n "$aws_profile" ]]; then
            update_env_var "AWS_PROFILE" "AWS profile" "$aws_profile" false
            # Comment out credential vars if they exist
            if grep -q "^export AWS_ACCESS_KEY_ID=" .envrc; then
                sed -i.tmp 's/^export AWS_ACCESS_KEY_ID/# export AWS_ACCESS_KEY_ID/' .envrc
                sed -i.tmp 's/^export AWS_SECRET_ACCESS_KEY/# export AWS_SECRET_ACCESS_KEY/' .envrc
                rm -f .envrc.tmp
            fi
            # Get region and account from profile
            profile_region=$(aws configure get region --profile "$aws_profile" 2>/dev/null || echo "")
            if [[ -n "$profile_region" ]]; then
                update_env_var "AWS_REGION" "AWS region" "$profile_region" false
            else
                update_env_var "AWS_REGION" "AWS region" "eu-central-1" false
            fi
            # Try to get account ID
            if account_id=$(aws sts get-caller-identity --profile "$aws_profile" --query Account --output text 2>/dev/null); then
                update_env_var "AWS_ACCOUNT_ID" "AWS account ID" "$account_id" false
            else
                update_env_var "AWS_ACCOUNT_ID" "AWS account ID" "" false
            fi
        fi
    else
        # Use credentials
        update_env_var "AWS_REGION" "AWS region" "eu-central-1" false
        update_env_var "AWS_ACCOUNT_ID" "AWS account ID" "" false
        update_env_var "AWS_ACCESS_KEY_ID" "AWS access key ID" "" false
        update_env_var "AWS_SECRET_ACCESS_KEY" "AWS secret access key" "" true
        # Comment out profile if it exists
        if grep -q "^export AWS_PROFILE=" .envrc; then
            sed -i.tmp 's/^export AWS_PROFILE/# export AWS_PROFILE/' .envrc
            rm -f .envrc.tmp
        fi
    fi
else
    # No profiles found, use credentials
    echo -e "${YELLOW}No AWS profiles found. Using credential configuration.${NC}"
    update_env_var "AWS_REGION" "AWS region" "eu-central-1" false
    update_env_var "AWS_ACCOUNT_ID" "AWS account ID" "" false
    update_env_var "AWS_ACCESS_KEY_ID" "AWS access key ID" "" false
    update_env_var "AWS_SECRET_ACCESS_KEY" "AWS secret access key" "" true
fi

# GitHub Configuration
echo -e "\n${BLUE}=== GitHub Configuration ===${NC}"
update_env_var "GITHUB_USER" "GitHub username" "" false
update_env_var "GITHUB_ORG" "GitHub organization (or username for personal)" "" false
update_env_var "GITHUB_TOKEN" "GitHub personal access token" "" true

# Domain Configuration
echo -e "\n${BLUE}=== Domain Configuration ===${NC}"
update_env_var "BASE_DOMAIN" "Base domain for clusters" "" false

# Optional SSO Configuration
echo -e "\n${BLUE}=== Optional: SSO Configuration ===${NC}"
read -p "Do you want to configure Google OAuth for SSO? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    update_env_var "GOOGLE_CLIENT_ID" "Google OAuth client ID" "" false
    update_env_var "GOOGLE_CLIENT_SECRET" "Google OAuth client secret" "" true
    update_env_var "GOOGLE_DOMAIN" "Restrict to domain (e.g., company.com)" "" false
fi

# Optional Monitoring
echo -e "\n${BLUE}=== Optional: Monitoring Configuration ===${NC}"
read -p "Do you want to configure Slack alerts? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    update_env_var "SLACK_WEBHOOK_URL" "Slack webhook URL" "" true
    update_env_var "SLACK_CHANNEL" "Slack channel" "#kubernetes-alerts" false
fi

# Validate configuration
echo -e "\n${BLUE}Validating configuration...${NC}"

# Source the file to check
source .envrc >/dev/null 2>&1 || true

# Check required variables
required_vars=(
    "HCLOUD_TOKEN"
    "AWS_REGION"
    "AWS_ACCOUNT_ID"
    "GITHUB_USER"
    "GITHUB_ORG"
    "BASE_DOMAIN"
)

all_valid=true
for var in "${required_vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo -e "${RED}✗ $var is not set${NC}"
        all_valid=false
    else
        echo -e "${GREEN}✓ $var is set${NC}"
    fi
done

if $all_valid; then
    echo -e "\n${GREEN}✅ Environment configuration is valid!${NC}"
    echo -e "${YELLOW}Run 'source .envrc' to load the environment${NC}"
else
    echo -e "\n${RED}❌ Some required variables are missing${NC}"
    echo -e "${YELLOW}Please run this script again to set missing values${NC}"
fi

# Show next steps
echo -e "\n${BLUE}Next steps:${NC}"
echo "1. source .envrc"
echo "2. make check"
echo "3. make github"
echo "4. make bootstrap"