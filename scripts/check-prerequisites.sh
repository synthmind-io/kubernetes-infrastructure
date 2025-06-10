#!/bin/bash
# scripts/check-prerequisites.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Checking prerequisites...${NC}"

# Track if all prerequisites are met
PREREQS_MET=true

# Function to check command
check_command() {
    local cmd=$1
    local version_flag=${2:---version}
    local min_version=${3:-}
    local install_hint=${4:-}
    
    if command -v $cmd >/dev/null 2>&1; then
        local version=$($cmd $version_flag 2>&1 | head -n1)
        echo -e "${GREEN}✓${NC} $cmd: $version"
        
        # TODO: Add version comparison if min_version is provided
    else
        echo -e "${RED}✗${NC} $cmd: NOT INSTALLED"
        if [[ -n "$install_hint" ]]; then
            echo -e "  ${YELLOW}Install with: $install_hint${NC}"
        fi
        PREREQS_MET=false
    fi
}

# Function to check environment variable
check_env_var() {
    local var_name=$1
    local description=$2
    local example=${3:-}
    local is_optional=${4:-false}
    
    if [[ -n "${!var_name:-}" ]]; then
        # Mask sensitive values
        local display_value="${!var_name}"
        if [[ "$var_name" == *"TOKEN"* ]] || [[ "$var_name" == *"PASSWORD"* ]]; then
            display_value="${display_value:0:4}****"
        fi
        echo -e "${GREEN}✓${NC} $var_name: $display_value"
    else
        echo -e "${RED}✗${NC} $var_name: NOT SET ($description)"
        if [[ -n "$example" ]]; then
            echo -e "  ${YELLOW}Example: export $var_name=$example${NC}"
        fi
        if [[ "$is_optional" != "true" ]]; then
            PREREQS_MET=false
        fi
    fi
}

echo -e "\n${BLUE}Checking required tools...${NC}"

# Kubernetes tools
check_command kubectl "version --client" "1.29" "brew install kubectl"
check_command helm version "3.14" "brew install helm"
check_command kind --version "" "brew install kind"
check_command clusterctl version "1.7.0" "brew install clusterctl"

# Cloud tools
check_command hcloud version "" "brew install hcloud"
check_command aws --version "2" "brew install awscli"
check_command gh --version "" "brew install gh"

# Development tools
check_command git --version "" "brew install git"
check_command jq --version "" "brew install jq"
check_command yq --version "" "brew install yq"
check_command htpasswd "-?" "" "brew install httpd"
check_command envsubst --version "" "brew install gettext"

# Optional but recommended
echo -e "\n${BLUE}Checking optional tools...${NC}"
check_command argocd version "" "brew install argocd"
check_command velero version "" "brew install velero"

echo -e "\n${BLUE}Checking environment variables...${NC}"

# Check if .envrc exists
if [[ -f .envrc ]]; then
    source .envrc
    echo -e "${GREEN}✓${NC} .envrc file found and sourced"
else
    echo -e "${RED}✗${NC} .envrc file not found"
    echo -e "  ${YELLOW}Create with: cp .envrc.example .envrc${NC}"
    PREREQS_MET=false
fi

# Hetzner variables
check_env_var HCLOUD_TOKEN "Hetzner Cloud API token" "hcloud_xxxxxxxxxxx"
check_env_var HETZNER_SSH_KEY "SSH key name in Hetzner" "hetzner-k8s"

# AWS variables
check_env_var AWS_REGION "AWS region" "eu-central-1"
check_env_var AWS_ACCOUNT_ID "AWS account ID" "123456789012"

# Check for AWS profile or credentials
if [[ -n "${AWS_PROFILE:-}" ]]; then
    echo -e "${GREEN}✓${NC} AWS_PROFILE: $AWS_PROFILE"
    # AWS SSO profiles might need login first, so check more carefully
    if aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        echo -e "  ${GREEN}Profile is valid and authenticated${NC}"
    elif aws configure get region --profile "$AWS_PROFILE" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}Profile exists but may need authentication${NC}"
        echo -e "  ${YELLOW}Try: aws sso login --profile $AWS_PROFILE${NC}"
        # Don't fail if profile exists but needs auth
    else
        echo -e "  ${RED}Profile '$AWS_PROFILE' not found${NC}"
        PREREQS_MET=false
    fi
else
    # Check for credentials
    check_env_var AWS_ACCESS_KEY_ID "AWS access key" "AKIAXXXXXXXX"
    check_env_var AWS_SECRET_ACCESS_KEY "AWS secret key" "xxxxxxxxxx"
fi

# GitHub variables
# Check if using gh CLI profile or token
if [[ -n "${GITHUB_PROFILE:-}" ]]; then
    echo -e "${GREEN}✓${NC} GITHUB_PROFILE: $GITHUB_PROFILE"
    # Check if gh CLI is authenticated
    if gh auth status >/dev/null 2>&1; then
        echo -e "  ${GREEN}GitHub CLI authenticated${NC}"
        # Try to get token from gh CLI if GITHUB_TOKEN is empty
        if [[ -z "${GITHUB_TOKEN:-}" ]]; then
            export GITHUB_TOKEN=$(gh auth token 2>/dev/null || echo "")
        fi
    else
        echo -e "  ${RED}GitHub CLI not authenticated${NC}"
        echo -e "  ${YELLOW}Run: gh auth login${NC}"
        PREREQS_MET=false
    fi
else
    # Not using profile, so token is required
    check_env_var GITHUB_TOKEN "GitHub personal access token" "ghp_xxxxxxxxxxxx"
fi

check_env_var GITHUB_USER "GitHub username" "yourusername"
check_env_var GITHUB_ORG "GitHub organization" "yourorg"

# Domain
check_env_var BASE_DOMAIN "Base domain for clusters" "example.com"
# Warn if using example.com
if [[ "${BASE_DOMAIN}" == "example.com" ]]; then
    echo -e "  ${YELLOW}Warning: Using example.com - update to your real domain${NC}"
fi

# Optional variables
echo -e "\n${BLUE}Checking optional environment variables...${NC}"
check_env_var HETZNER_ROBOT_USER "Hetzner Robot username (for bare metal)" "username" true
check_env_var HETZNER_ROBOT_PASSWORD "Hetzner Robot password" "password" true

# Check connectivity
echo -e "\n${BLUE}Checking connectivity...${NC}"

# Check Hetzner API
if [[ -n "${HCLOUD_TOKEN:-}" ]]; then
    if hcloud server list >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Hetzner API connection successful"
    else
        echo -e "${RED}✗${NC} Cannot connect to Hetzner API (check token)"
        PREREQS_MET=false
    fi
fi

# Check AWS credentials
if [[ -n "${AWS_PROFILE:-}" ]] || [[ -n "${AWS_ACCESS_KEY_ID:-}" ]]; then
    if aws sts get-caller-identity >/dev/null 2>&1; then
        account=$(aws sts get-caller-identity --query Account --output text)
        identity=$(aws sts get-caller-identity --query Arn --output text)
        echo -e "${GREEN}✓${NC} AWS credentials valid"
        echo -e "  Account: $account"
        echo -e "  Identity: $identity"
    else
        echo -e "${RED}✗${NC} AWS credentials invalid"
        if [[ -n "${AWS_PROFILE:-}" ]]; then
            echo -e "  ${YELLOW}Check profile: aws configure list --profile ${AWS_PROFILE}${NC}"
        fi
        PREREQS_MET=false
    fi
fi

# Check GitHub authentication
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    if curl -s -H "Authorization: token ${GITHUB_TOKEN}" https://api.github.com/user >/dev/null; then
        echo -e "${GREEN}✓${NC} GitHub token valid"
    else
        echo -e "${RED}✗${NC} GitHub token invalid"
        PREREQS_MET=false
    fi
elif [[ -n "${GITHUB_PROFILE:-}" ]]; then
    # Already checked above with gh CLI
    echo -e "${GREEN}✓${NC} Using GitHub CLI authentication"
else
    echo -e "${RED}✗${NC} No GitHub authentication configured"
    echo -e "${YELLOW}Either set GITHUB_TOKEN or use gh CLI with GITHUB_PROFILE${NC}"
    PREREQS_MET=false
fi

# Check disk space
echo -e "\n${BLUE}Checking system resources...${NC}"
available_space=$(df -h . | awk 'NR==2 {print $4}')
echo -e "${GREEN}✓${NC} Available disk space: $available_space"

# Check Docker
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Docker daemon is running"
    else
        echo -e "${RED}✗${NC} Docker daemon is not running"
        echo -e "  ${YELLOW}Start with: open -a Docker${NC}"
        PREREQS_MET=false
    fi
else
    echo -e "${RED}✗${NC} Docker not installed"
    echo -e "  ${YELLOW}Install Docker Desktop from docker.com${NC}"
    PREREQS_MET=false
fi

# Summary
echo -e "\n${BLUE}===================${NC}"
if $PREREQS_MET; then
    echo -e "${GREEN}✅ All prerequisites met!${NC}"
    echo -e "${GREEN}You can proceed with cluster deployment.${NC}"
    exit 0
else
    echo -e "${RED}❌ Some prerequisites are missing.${NC}"
    echo -e "${YELLOW}Please install missing tools and set required environment variables.${NC}"
    exit 1
fi