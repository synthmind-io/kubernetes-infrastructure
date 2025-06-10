#!/bin/bash
# Main setup script for Hetzner Multi-Cluster Kubernetes

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Banner
cat << "EOF"
╔═══════════════════════════════════════════════════════════════╗
║     Hetzner Multi-Cluster Kubernetes Setup                    ║
║     Production-Ready Infrastructure with CAPH                 ║
╚═══════════════════════════════════════════════════════════════╝
EOF

echo -e "${BLUE}Welcome to the Hetzner Multi-Cluster Kubernetes setup!${NC}"
echo -e "${BLUE}This script will help you deploy a production-ready Kubernetes infrastructure.${NC}"
echo ""

# Function to check if .envrc exists
check_env() {
    if [ ! -f .envrc ]; then
        echo -e "${RED}Error: .envrc file not found!${NC}"
        echo -e "${YELLOW}Please create .envrc with the following template:${NC}"
        cat << 'EOF'

# Create .envrc file with:
cat > .envrc <<'END'
# Hetzner
export HCLOUD_TOKEN="your-hetzner-cloud-token"
export HETZNER_SSH_KEY="hetzner-k8s"
export HETZNER_ROBOT_USER=""  # Only if using bare metal
export HETZNER_ROBOT_PASSWORD=""  # Only if using bare metal

# AWS
export AWS_REGION="eu-central-1"
export AWS_ACCOUNT_ID="123456789012"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"

# GitHub
export GITHUB_TOKEN="ghp_your_token"
export GITHUB_USER="your-username"
export GITHUB_ORG="your-org"

# Domain
export BASE_DOMAIN="your-domain.com"

# Cluster names
export CLUSTERS=("management" "monitoring" "dev" "devops" "staging")
END

EOF
        exit 1
    fi
    source .envrc
}

# Function to display menu
show_menu() {
    echo ""
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${PURPLE}                    MAIN MENU                                  ${NC}"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════${NC}"
    echo "1)  Check prerequisites"
    echo "2)  Configure environment (.envrc)"
    echo "3)  Create repository structure"
    echo "4)  Setup GitHub repositories and access"
    echo "5)  Setup Hetzner resources (SSH keys, networks, etc.)"
    echo "6)  Configure AWS Secrets Manager"
    echo "7)  Deploy Management Cluster"
    echo "8)  Install ArgoCD"
    echo "9)  Apply GitOps configurations"
    echo "10) Deploy Monitoring Cluster"
    echo "11) Deploy Workload Clusters (Dev, DevOps, Staging)"
    echo "12) Full automated deployment (runs all steps)"
    echo "13) Show deployment status"
    echo "14) Cleanup everything"
    echo "0)  Exit"
    echo -e "${PURPLE}═══════════════════════════════════════════════════════════════${NC}"
}

# Function to check prerequisites
check_prerequisites() {
    echo -e "${BLUE}Checking prerequisites...${NC}"
    ./scripts/check-prerequisites.sh
}

# Function to create repository structure
create_structure() {
    echo -e "${BLUE}Creating repository structure...${NC}"
    
    # Create directories
    mkdir -p {bootstrap/{management-cluster/{cluster-api,argocd},root-apps},clusters/{management,monitoring,dev,devops,staging},infrastructure/{base/{cert-manager,ingress-nginx,cilium,hcloud-ccm,hcloud-csi,external-secrets,external-dns,vector,velero,defguard},monitoring/{base/{prometheus,loki,grafana,thanos}},overlays/{management,monitoring,dev,devops,staging}},applications/{base,overlays/{management,monitoring,dev,devops,staging}},scripts,docs}
    
    # Create .gitignore
    cat > .gitignore <<EOF
.envrc
.env
*.backup
*.key
*.pem
kubeconfig*
secrets/
tmp/
argocd-credentials.txt
.DS_Store
EOF

    echo -e "${GREEN}✅ Repository structure created!${NC}"
}

# Function to show status
show_status() {
    echo -e "${BLUE}Deployment Status:${NC}"
    echo ""
    
    # Check clusters
    echo -e "${YELLOW}Clusters:${NC}"
    if kubectl config get-contexts 2>/dev/null | grep -q management; then
        echo -e "  ${GREEN}✓${NC} Management cluster"
    else
        echo -e "  ${RED}✗${NC} Management cluster"
    fi
    
    # Check ArgoCD
    if kubectl get ns argocd &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} ArgoCD installed"
        kubectl -n argocd get applications 2>/dev/null || true
    else
        echo -e "  ${RED}✗${NC} ArgoCD not installed"
    fi
    
    # Check other clusters
    for cluster in monitoring dev devops staging; do
        if kubectl get cluster $cluster -n default &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} $cluster cluster"
        else
            echo -e "  ${RED}✗${NC} $cluster cluster"
        fi
    done
}

# Function to run full deployment
full_deployment() {
    echo -e "${BLUE}Starting full automated deployment...${NC}"
    echo -e "${YELLOW}This will take approximately 30-45 minutes.${NC}"
    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return
    fi
    
    check_prerequisites
    create_structure
    ./scripts/setup-github-resources.sh
    ./scripts/setup-hetzner-resources.sh
    ./scripts/manage-secrets.sh
    ./scripts/init-management-cluster.sh
    ./scripts/install-argocd.sh
    ./scripts/apply-root-apps.sh
    
    echo -e "${GREEN}✅ Full deployment completed!${NC}"
    echo -e "${YELLOW}Please configure DNS records as shown above.${NC}"
}

# Function to cleanup
cleanup() {
    echo -e "${RED}WARNING: This will delete all clusters and resources!${NC}"
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Cleanup cancelled."
        return
    fi
    
    echo -e "${RED}Cleaning up all resources...${NC}"
    
    # Delete clusters
    for cluster in staging devops dev monitoring; do
        kubectl delete cluster $cluster -n default --ignore-not-found
    done
    
    # Delete Hetzner resources
    hcloud load-balancer list -o noheader | awk '{print $1}' | xargs -r -n1 hcloud load-balancer delete
    hcloud volume list -o noheader | awk '{print $1}' | xargs -r -n1 hcloud volume delete
    hcloud server list -o noheader | awk '{print $1}' | xargs -r -n1 hcloud server delete
    
    echo -e "${GREEN}Cleanup completed.${NC}"
}

# Main script
main() {
    check_env
    
    while true; do
        show_menu
        read -p "Select an option: " choice
        
        case $choice in
            1) check_prerequisites ;;
            2) ./scripts/configure-environment.sh; source .envrc ;;
            3) create_structure ;;
            4) ./scripts/setup-github-resources.sh ;;
            5) ./scripts/setup-hetzner-resources.sh ;;
            6) ./scripts/manage-secrets.sh ;;
            7) ./scripts/init-management-cluster.sh ;;
            8) ./scripts/install-argocd.sh ;;
            9) ./scripts/apply-root-apps.sh ;;
            10) echo "Deploy monitoring cluster - Coming soon" ;;
            11) echo "Deploy workload clusters - Coming soon" ;;
            12) full_deployment ;;
            13) show_status ;;
            14) cleanup ;;
            0) 
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0 
                ;;
            *) 
                echo -e "${RED}Invalid option!${NC}"
                ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Run main function
main