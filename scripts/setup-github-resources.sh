#!/bin/bash
# scripts/setup-github-resources.sh
#
# Sets up GitHub repositories and resources for the Kubernetes infrastructure
# 
# Usage: 
#   ./setup-github-resources.sh [github-profile]
#
# Examples:
#   ./setup-github-resources.sh                    # Interactive profile selection
#   ./setup-github-resources.sh casperakos         # Use specific profile
#   GITHUB_PROFILE=itsironis ./setup-github-resources.sh  # Use env var
#
# The script will:
# 1. Switch to the specified GitHub profile (if multiple profiles exist)
# 2. Create the kubernetes-infrastructure repository
# 3. Set up GitHub tokens and OAuth apps
# 4. Update .envrc with all GitHub-related variables

set -euo pipefail

# Check for command line argument
if [[ $# -eq 1 ]]; then
    export GITHUB_PROFILE="$1"
    echo "Using GitHub profile from command line: $GITHUB_PROFILE"
fi

# Source environment variables
source .envrc || { echo "Please create .envrc file first"; exit 1; }

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Setting up GitHub Resources${NC}"

# Check for required tools
command -v gh >/dev/null 2>&1 || { echo -e "${RED}GitHub CLI (gh) is required but not installed. Install with: brew install gh${NC}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo -e "${RED}jq is required but not installed. Install with: brew install jq${NC}" >&2; exit 1; }

# Function to update .envrc file
update_envrc() {
    local var_name=$1
    local var_value=$2
    local var_comment=${3:-}
    
    if [[ -f .envrc ]]; then
        # Check if variable exists
        if grep -q "^export ${var_name}=" .envrc; then
            # Update existing variable
            sed -i.bak "s|^export ${var_name}=.*|export ${var_name}=\"${var_value}\"|" .envrc
            echo -e "${GREEN}✓ Updated ${var_name} in .envrc${NC}"
        else
            # Add new variable
            if [[ -n "$var_comment" ]]; then
                echo -e "\n# ${var_comment}" >> .envrc
            fi
            echo "export ${var_name}=\"${var_value}\"" >> .envrc
            echo -e "${GREEN}✓ Added ${var_name} to .envrc${NC}"
        fi
    fi
}

# Check if gh is authenticated
if ! gh auth status >/dev/null 2>&1; then
    echo -e "${YELLOW}GitHub CLI not authenticated. Starting login process...${NC}"
    gh auth login
fi

# Check for multiple accounts
echo -e "${BLUE}Checking GitHub CLI authentication...${NC}"
auth_status=$(gh auth status 2>&1)
active_account=$(echo "$auth_status" | grep -B1 "Active account: true" | grep "Logged in to" | sed 's/.*account \(.*\) (.*/\1/')

# Show all available accounts
echo -e "${BLUE}Available GitHub accounts:${NC}"
accounts=()
while IFS= read -r line; do
    if [[ "$line" =~ "Logged in to" ]]; then
        account=$(echo "$line" | sed 's/.*account \(.*\) (.*/\1/')
        accounts+=("$account")
        if [[ "$account" == "$active_account" ]]; then
            echo -e "${GREEN}  ✓ $account (active)${NC}"
        else
            echo -e "${YELLOW}  - $account${NC}"
        fi
    fi
done <<< "$auth_status"

# Check if we have multiple accounts
account_count=$(echo "$auth_status" | grep -c "Logged in to")
if [[ $account_count -gt 1 ]]; then
    echo -e "${BLUE}Multiple GitHub accounts detected.${NC}"
    
    # Check if GITHUB_PROFILE env var is set
    if [[ -n "${GITHUB_PROFILE:-}" ]]; then
        echo -e "${BLUE}Profile specified: ${GITHUB_PROFILE}${NC}"
        target_account="$GITHUB_PROFILE"
        
        # Validate the profile exists
        if [[ ! " ${accounts[@]} " =~ " ${target_account} " ]]; then
            echo -e "${RED}Error: Profile '${target_account}' not found in gh CLI accounts${NC}"
            echo -e "${YELLOW}Available profiles: ${accounts[*]}${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}Choose which account to use:${NC}"
        select account_choice in "${accounts[@]}" "Keep current ($active_account)"; do
            if [[ -n "$account_choice" ]]; then
                if [[ "$account_choice" == "Keep current ($active_account)" ]]; then
                    target_account="$active_account"
                else
                    target_account="$account_choice"
                fi
                break
            fi
        done
    fi
    
    # Switch account if different from active
    if [[ -n "$target_account" ]] && [[ "$target_account" != "$active_account" ]]; then
        echo -e "${BLUE}Switching to account: $target_account${NC}"
        gh auth switch -u "$target_account"
        active_account="$target_account"
    fi
fi

# Get authenticated user (refresh after potential switch)
CURRENT_USER=$(gh api user --jq .login)
echo -e "${GREEN}Using GitHub account: $CURRENT_USER${NC}"

# Update profile in .envrc for future runs
update_envrc "GITHUB_PROFILE" "$CURRENT_USER" "GitHub CLI profile to use"

# Update GITHUB_USER in .envrc if not set
if [[ -z "${GITHUB_USER:-}" ]] || [[ "${GITHUB_USER}" == "your-github-username" ]]; then
    update_envrc "GITHUB_USER" "$CURRENT_USER" "GitHub username"
    export GITHUB_USER="$CURRENT_USER"
fi

# Update GITHUB_ORG if not set or is default
if [[ -z "${GITHUB_ORG:-}" ]] || [[ "${GITHUB_ORG}" == "your-github-org" ]]; then
    # Check if user has organizations
    orgs=$(gh api user/orgs --jq '.[].login' 2>/dev/null || echo "")
    if [[ -n "$orgs" ]]; then
        echo -e "${BLUE}Found organizations: ${orgs}${NC}"
        read -p "Enter organization name (or press Enter to use personal account): " org_choice
        if [[ -n "$org_choice" ]]; then
            update_envrc "GITHUB_ORG" "$org_choice" "GitHub organization"
            export GITHUB_ORG="$org_choice"
        else
            update_envrc "GITHUB_ORG" "$CURRENT_USER" "GitHub organization (personal account)"
            export GITHUB_ORG="$CURRENT_USER"
        fi
    else
        update_envrc "GITHUB_ORG" "$CURRENT_USER" "GitHub organization (personal account)"
        export GITHUB_ORG="$CURRENT_USER"
    fi
fi

# Function to check if repo exists
repo_exists() {
    local repo=$1
    gh repo view "${GITHUB_ORG}/${repo}" >/dev/null 2>&1
}

# Function to create repository
create_repo() {
    local repo_name=$1
    local description=$2
    local is_private=${3:-false}
    
    if repo_exists "$repo_name"; then
        echo -e "${YELLOW}Repository ${GITHUB_ORG}/${repo_name} already exists${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Creating repository: ${GITHUB_ORG}/${repo_name}${NC}"
    
    local visibility="public"
    if [[ "$is_private" == "true" ]]; then
        visibility="private"
    fi
    
    # Create in organization if GITHUB_ORG is set and different from user
    if [[ -n "${GITHUB_ORG}" ]] && [[ "${GITHUB_ORG}" != "${CURRENT_USER}" ]]; then
        gh repo create "${GITHUB_ORG}/${repo_name}" \
            --description "$description" \
            --${visibility} \
            --clone=false
    else
        gh repo create "${repo_name}" \
            --description "$description" \
            --${visibility} \
            --clone=false
    fi
}

# Create main infrastructure repository
echo -e "${BLUE}Creating repositories...${NC}"
create_repo "kubernetes-infrastructure" "Hetzner Multi-Cluster Kubernetes Infrastructure (GitOps)" false

# Initialize the repository with our local content
echo -e "${BLUE}Initializing kubernetes-infrastructure repository...${NC}"
if [[ ! -d .git ]]; then
    git init
    git add .
    git commit -m "Initial commit: Hetzner CAPH multi-cluster infrastructure"
fi

# Add remote if not exists
if ! git remote | grep -q origin; then
    git remote add origin "https://github.com/${GITHUB_ORG}/kubernetes-infrastructure.git"
fi

# Push to GitHub
echo -e "${BLUE}Pushing to GitHub...${NC}"
git branch -M main
git push -u origin main || {
    echo -e "${YELLOW}Failed to push. You may need to force push if the repo already has content:${NC}"
    echo "  git push -u origin main --force"
}

# Create application repositories (optional - for demo apps)
echo -e "${BLUE}Creating optional application repositories...${NC}"
create_repo "demo-app" "Demo application for Kubernetes clusters" false
create_repo "monitoring-config" "Monitoring configuration for Grafana dashboards and alerts" false

# Create/update GitHub App or Personal Access Token for ArgoCD
echo -e "${BLUE}Setting up GitHub access for ArgoCD...${NC}"

# Check if we have a valid token
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    echo -e "${YELLOW}No GITHUB_TOKEN found in environment${NC}"
    echo -e "${BLUE}Creating a new Personal Access Token for ArgoCD...${NC}"
    
    # Try to create PAT with gh CLI (requires gh version 2.18+)
    if gh auth token &>/dev/null; then
        # Use existing gh auth token
        GITHUB_TOKEN=$(gh auth token)
        echo -e "${GREEN}✓ Using existing gh CLI token${NC}"
        update_envrc "GITHUB_TOKEN" "$GITHUB_TOKEN" "GitHub Personal Access Token (from gh CLI)"
    else
        echo -e "${YELLOW}Could not get token automatically. Please create one manually:${NC}"
        echo "1. Go to: https://github.com/settings/tokens/new"
        echo "2. Name: ArgoCD-CAPH-$(date +%Y%m%d)"
        echo "3. Expiration: 90 days"
        echo "4. Scopes: repo, admin:repo_hook"
        echo ""
        read -p "Paste your GitHub token here (or press Enter to skip): " manual_token
        if [[ -n "$manual_token" ]]; then
            GITHUB_TOKEN="$manual_token"
            update_envrc "GITHUB_TOKEN" "$GITHUB_TOKEN" "GitHub Personal Access Token"
            export GITHUB_TOKEN="$manual_token"
        fi
    fi
else
    echo -e "${GREEN}✓ Using existing GITHUB_TOKEN from environment${NC}"
fi

# Create webhook for ArgoCD (will be configured after ArgoCD is installed)
echo -e "${BLUE}Note: ArgoCD webhook will be configured after ArgoCD installation${NC}"

# Create GitHub OAuth App for SSO (optional)
echo -e "${BLUE}Setting up GitHub OAuth App for SSO (optional)...${NC}"
echo -e "${YELLOW}To enable GitHub SSO for ArgoCD and other services:${NC}"
echo "1. Go to: https://github.com/organizations/${GITHUB_ORG}/settings/applications"
echo "   Or for personal: https://github.com/settings/applications/new"
echo "2. Click 'New OAuth App'"
echo "3. Application name: CAPH Kubernetes Platform"
echo "4. Homepage URL: https://argocd.mgmt.${BASE_DOMAIN}"
echo "5. Authorization callback URL: https://argocd.mgmt.${BASE_DOMAIN}/api/dex/callback"
echo "6. Click 'Register application'"
echo ""
read -p "Have you created the OAuth App? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter GitHub OAuth Client ID: " oauth_client_id
    read -s -p "Enter GitHub OAuth Client Secret: " oauth_client_secret
    echo
    if [[ -n "$oauth_client_id" ]] && [[ -n "$oauth_client_secret" ]]; then
        update_envrc "GITHUB_OAUTH_CLIENT_ID" "$oauth_client_id" "GitHub OAuth App Client ID"
        update_envrc "GITHUB_OAUTH_CLIENT_SECRET" "$oauth_client_secret" "GitHub OAuth App Client Secret"
        export GITHUB_OAUTH_CLIENT_ID="$oauth_client_id"
        export GITHUB_OAUTH_CLIENT_SECRET="$oauth_client_secret"
    fi
fi

# Create deploy keys for clusters (optional - for private repos)
if [[ ! -f ~/.ssh/caph-deploy-key ]]; then
    echo -e "${BLUE}Creating deploy key for repository access...${NC}"
    ssh-keygen -t ed25519 -f ~/.ssh/caph-deploy-key -C "caph-argocd@${GITHUB_ORG}" -N ""
    
    echo -e "${BLUE}Adding deploy key to repository...${NC}"
    gh repo deploy-key add ~/.ssh/caph-deploy-key.pub \
        -R "${GITHUB_ORG}/kubernetes-infrastructure" \
        -t "CAPH ArgoCD Access" \
        --allow-write
    
    # Update .envrc with deploy key path
    update_envrc "GITHUB_DEPLOY_KEY" "$HOME/.ssh/caph-deploy-key" "GitHub deploy key for ArgoCD"
fi

# Store repository URLs in .envrc
update_envrc "GITHUB_INFRA_REPO" "https://github.com/${GITHUB_ORG}/kubernetes-infrastructure" "Main infrastructure repository"
update_envrc "GITHUB_INFRA_REPO_SSH" "git@github.com:${GITHUB_ORG}/kubernetes-infrastructure.git" "SSH URL for infrastructure repository"

# Create branch protection rules
echo -e "${BLUE}Setting up branch protection for main branch...${NC}"
gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_ORG}/kubernetes-infrastructure/branches/main/protection" \
    -f required_status_checks='{"strict":true,"contexts":[]}' \
    -f enforce_admins=false \
    -f required_pull_request_reviews='{"dismiss_stale_reviews":true,"require_code_owner_reviews":false,"required_approving_review_count":1}' \
    -f restrictions=null \
    -f allow_force_pushes=false \
    -f allow_deletions=false 2>/dev/null || {
        echo -e "${YELLOW}Note: Branch protection requires admin access. You may need to configure this manually.${NC}"
    }

# Create initial directory structure in the repo
echo -e "${BLUE}Creating initial directory structure...${NC}"
directories=(
    "clusters/management"
    "clusters/monitoring" 
    "clusters/dev"
    "clusters/devops"
    "clusters/staging"
    "infrastructure/base"
    "infrastructure/overlays"
    "applications/management"
    "applications/monitoring"
    "applications/dev"
    "applications/devops"
    "applications/staging"
)

for dir in "${directories[@]}"; do
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        touch "$dir/.gitkeep"
    fi
done

# Create README for the repository
if [[ ! -f "README.md" ]] || [[ $(wc -l < README.md) -lt 10 ]]; then
    echo -e "${BLUE}Updating repository README...${NC}"
    cat > README-github.md << 'EOF'
# Kubernetes Infrastructure

This repository contains the GitOps configuration for our Hetzner-based Kubernetes multi-cluster platform.

## Architecture

- **Management Cluster**: Hosts CAPI controllers, ArgoCD, and cluster management tools
- **Monitoring Cluster**: Centralized monitoring with Prometheus, Loki, and Grafana  
- **Dev Cluster**: Development environment
- **DevOps Cluster**: CI/CD and build infrastructure
- **Staging Cluster**: Pre-production environment

## Repository Structure

```
.
├── clusters/          # Cluster definitions (CAPI resources)
├── infrastructure/    # Core infrastructure components
├── applications/      # Application deployments per cluster
└── scripts/          # Helper scripts
```

## Getting Started

See the main documentation in the `docs/` directory.

## ArgoCD Access

ArgoCD UI: https://argocd.mgmt.${BASE_DOMAIN}

## Managed by

- Cluster API Provider Hetzner (CAPH)
- ArgoCD for GitOps
- External Secrets Operator
- Cilium CNI
EOF
    
    # Only update README if it's very basic
    if [[ $(wc -l < README.md) -lt 10 ]]; then
        mv README-github.md README.md
    else
        rm README-github.md
    fi
fi

# Commit and push the structure
if [[ -n $(git status --porcelain) ]]; then
    echo -e "${BLUE}Committing directory structure...${NC}"
    git add -A
    git commit -m "Add GitOps directory structure"
    git push origin main
fi

# Create GitHub Actions workflow for validation (optional)
echo -e "${BLUE}Creating GitHub Actions workflow...${NC}"
mkdir -p .github/workflows
cat > .github/workflows/validate.yml << 'EOF'
name: Validate Kubernetes Manifests

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v3
    
    - name: Validate Kubernetes manifests
      uses: instrumenta/kubeval-action@master
      with:
        files: ./clusters,./infrastructure,./applications
        
    - name: Run yamllint
      uses: ibiqlik/action-yamllint@v3
      with:
        file_or_dir: .
        config_file: .yamllint.yml
EOF

# Create yamllint config
cat > .yamllint.yml << 'EOF'
extends: default

rules:
  line-length:
    max: 150
  comments:
    min-spaces-from-content: 1
  braces:
    max-spaces-inside: 1
  brackets:
    max-spaces-inside: 1
  truthy:
    allowed-values: ['true', 'false', 'yes', 'no', 'on', 'off']

ignore: |
  .git/
  scripts/
  docs/
EOF

# Commit workflow
if [[ -n $(git status --porcelain) ]]; then
    git add -A
    git commit -m "Add GitHub Actions validation workflow"
    git push origin main
fi

# Summary
echo -e "${GREEN}✅ GitHub setup completed!${NC}"
echo -e "${BLUE}Resources created:${NC}"
echo "  - Repository: https://github.com/${GITHUB_ORG}/kubernetes-infrastructure"
echo "  - Deploy key: ~/.ssh/caph-deploy-key"
echo "  - Directory structure initialized"
echo "  - GitHub Actions workflow added"

# Show what was updated in .envrc
if [[ -f .envrc.bak ]]; then
    echo -e "\n${BLUE}Environment variables updated in .envrc:${NC}"
    diff -u .envrc.bak .envrc | grep "^+export" | sed 's/^+/  - /' || true
    rm -f .envrc.bak
fi

echo -e "\n${YELLOW}Important:${NC}"
echo "1. Reload your environment: source .envrc"
echo "2. Create webhooks after ArgoCD is deployed"

echo -e "\n${BLUE}Next steps:${NC}"
echo "1. source .envrc"
echo "2. make bootstrap  # or continue with ./setup.sh"