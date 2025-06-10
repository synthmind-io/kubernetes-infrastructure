#!/bin/bash
# scripts/setup-hetzner-resources.sh

set -euo pipefail

# Source environment variables
source .envrc || { echo "Please create .envrc file first"; exit 1; }

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse command line arguments for non-interactive mode
ALLOWED_SSH_IPS="${ALLOWED_SSH_IPS:-}"
ALLOWED_API_IPS="${ALLOWED_API_IPS:-}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"

# Usage information
if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $0"
    echo "Environment variables for non-interactive mode:"
    echo "  ALLOWED_SSH_IPS='1.2.3.4/32,5.6.7.8/32'  # Comma-separated IPs"
    echo "  ALLOWED_API_IPS='1.2.3.4/32,5.6.7.8/32'  # Comma-separated IPs"
    echo "  NON_INTERACTIVE=true                      # Skip prompts"
    exit 0
fi

echo -e "${BLUE}Setting up Hetzner Resources${NC}"

# Check for required tools
command -v hcloud >/dev/null 2>&1 || { echo -e "${RED}hcloud CLI is required but not installed. Please install it first.${NC}" >&2; exit 1; }
command -v ssh-keygen >/dev/null 2>&1 || { echo -e "${RED}ssh-keygen is required but not installed.${NC}" >&2; exit 1; }

# Verify Hetzner token
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
    echo -e "${RED}HCLOUD_TOKEN is not set. Please check your .envrc file.${NC}"
    exit 1
fi

# Configure hcloud CLI
echo -e "${BLUE}Creating hcloud context...${NC}"
hcloud context create caph-clusters 2>/dev/null || echo -e "${YELLOW}Context may already exist${NC}"
echo -e "${BLUE}Using hcloud context...${NC}"
hcloud context use caph-clusters
echo -e "${BLUE}Active context:${NC}"
hcloud context active

# Function to check if resource exists
resource_exists() {
    local resource_type=$1
    local resource_name=$2
    hcloud $resource_type list -o noheader | grep -q "^${resource_name}\s" || false
}

# Create SSH key if it doesn't exist
echo -e "${BLUE}Setting up SSH keys...${NC}"

# Check if SSH key exists locally
SSH_KEY_PATH="${HOME}/.ssh/${HETZNER_SSH_KEY}"
if [[ ! -f "${SSH_KEY_PATH}" ]]; then
    echo -e "${YELLOW}Creating SSH key pair: ${SSH_KEY_PATH}${NC}"
    ssh-keygen -t ed25519 -f "${SSH_KEY_PATH}" -C "kubernetes@hetzner" -N ""
else
    echo -e "${GREEN}SSH key already exists: ${SSH_KEY_PATH}${NC}"
fi

# Upload SSH key to Hetzner if it doesn't exist
if ! resource_exists ssh-key "${HETZNER_SSH_KEY}"; then
    echo -e "${BLUE}Uploading SSH key to Hetzner...${NC}"
    hcloud ssh-key create \
        --name "${HETZNER_SSH_KEY}" \
        --public-key-from-file "${SSH_KEY_PATH}.pub" \
        --label "managed-by=caph"
else
    echo -e "${GREEN}SSH key already exists in Hetzner: ${HETZNER_SSH_KEY}${NC}"
fi

# Create networks for each cluster
echo -e "${BLUE}Setting up networks...${NC}"

declare -A NETWORKS=(
    ["management"]="10.0.0.0/16"
    ["monitoring"]="10.246.0.0/16"
    ["dev"]="10.248.0.0/16"
    ["devops"]="10.250.0.0/16"
    ["staging"]="10.252.0.0/16"
)

for cluster in "${!NETWORKS[@]}"; do
    network_name="${cluster}-network"
    network_cidr="${NETWORKS[$cluster]}"
    
    if ! resource_exists network "${network_name}"; then
        echo -e "${BLUE}Creating network: ${network_name} (${network_cidr})${NC}"
        hcloud network create \
            --name "${network_name}" \
            --ip-range "${network_cidr}" \
            --label "cluster=${cluster}" \
            --label "managed-by=caph"
        
        # Create subnet
        subnet_cidr="${network_cidr}"
        echo -e "${BLUE}Creating subnet for ${network_name}${NC}"
        hcloud network add-subnet "${network_name}" \
            --type cloud \
            --network-zone eu-central \
            --ip-range "${subnet_cidr}"
    else
        echo -e "${GREEN}Network already exists: ${network_name}${NC}"
    fi
done

# Create placement groups for each cluster
echo -e "${BLUE}Setting up placement groups...${NC}"

CLUSTERS=("management" "monitoring" "dev" "devops" "staging")

for cluster in "${CLUSTERS[@]}"; do
    pg_name="${cluster}-pg"
    
    if ! resource_exists placement-group "${pg_name}"; then
        echo -e "${BLUE}Creating placement group: ${pg_name}${NC}"
        hcloud placement-group create \
            --name "${pg_name}" \
            --type spread \
            --label "cluster=${cluster}" \
            --label "managed-by=caph"
    else
        echo -e "${GREEN}Placement group already exists: ${pg_name}${NC}"
    fi
done

# Create firewall rules
echo -e "${BLUE}Setting up firewall rules...${NC}"

# Management cluster firewall
if ! resource_exists firewall "management-firewall"; then
    echo -e "${BLUE}Creating management cluster firewall...${NC}"
    
    # Create the firewall
    hcloud firewall create --name "management-firewall" \
        --label "cluster=management" \
        --label "managed-by=caph"
    
    # Configure SSH access
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        ssh_sources="${ALLOWED_SSH_IPS:-0.0.0.0/0}"
        echo -e "${BLUE}Using SSH source IPs: $ssh_sources${NC}"
    else
        echo -e "${YELLOW}=== SSH Access Configuration ===${NC}"
        echo -e "${YELLOW}For production, restrict SSH to your IP ranges.${NC}"
        echo -e "${YELLOW}Examples: '1.2.3.4/32' for single IP, '10.0.0.0/8' for network${NC}"
        read -p "Enter allowed SSH source IPs (comma-separated) [default: 0.0.0.0/0]: " ssh_sources
        ssh_sources=${ssh_sources:-"0.0.0.0/0"}
        
        if [[ "$ssh_sources" == "0.0.0.0/0" ]]; then
            echo -e "${RED}WARNING: SSH access will be open to the internet!${NC}"
            read -p "Are you sure? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                echo -e "${YELLOW}Please re-run and specify your IP ranges${NC}"
                exit 1
            fi
        fi
    fi
    
    # Add SSH rules
    IFS=',' read -ra SSH_IPS <<< "$ssh_sources"
    for ip in "${SSH_IPS[@]}"; do
        ip=$(echo "$ip" | xargs)  # Trim whitespace
        hcloud firewall add-rule management-firewall \
            --direction in \
            --source-ips "$ip" \
            --protocol tcp \
            --port 22 \
            --description "SSH access from $ip"
    done
    
    # Configure Kubernetes API access
    if [[ "$NON_INTERACTIVE" == "true" ]]; then
        api_sources="${ALLOWED_API_IPS:-0.0.0.0/0}"
        echo -e "${BLUE}Using API source IPs: $api_sources${NC}"
    else
        echo -e "${YELLOW}=== Kubernetes API Access Configuration ===${NC}"
        echo -e "${YELLOW}Restrict API access to management networks/VPN for security.${NC}"
        read -p "Enter allowed API source IPs (comma-separated) [default: 0.0.0.0/0]: " api_sources
        api_sources=${api_sources:-"0.0.0.0/0"}
    fi
    
    # Add Kubernetes API rules
    IFS=',' read -ra API_IPS <<< "$api_sources"
    for ip in "${API_IPS[@]}"; do
        ip=$(echo "$ip" | xargs)  # Trim whitespace
        hcloud firewall add-rule management-firewall \
            --direction in \
            --source-ips "$ip" \
            --protocol tcp \
            --port 6443 \
            --description "Kubernetes API from $ip"
    done
    
    # Allow HTTP/HTTPS for ingress
    hcloud firewall add-rule management-firewall \
        --direction in \
        --source-ips 0.0.0.0/0 \
        --protocol tcp \
        --port 80 \
        --description "HTTP"
    
    hcloud firewall add-rule management-firewall \
        --direction in \
        --source-ips 0.0.0.0/0 \
        --protocol tcp \
        --port 443 \
        --description "HTTPS"
    
    # Allow NodePort range
    hcloud firewall add-rule management-firewall \
        --direction in \
        --source-ips 0.0.0.0/0 \
        --protocol tcp \
        --port 30000-32767 \
        --description "NodePort services"
    
    # Allow internal communication
    hcloud firewall add-rule management-firewall \
        --direction in \
        --source-ips 10.0.0.0/8 \
        --protocol tcp \
        --port any \
        --description "Internal cluster communication"
    
    hcloud firewall add-rule management-firewall \
        --direction in \
        --source-ips 10.0.0.0/8 \
        --protocol udp \
        --port any \
        --description "Internal cluster communication UDP"
else
    echo -e "${GREEN}Management firewall already exists${NC}"
fi

# Create basic firewall for other clusters (can be customized later)
for cluster in monitoring dev devops staging; do
    firewall_name="${cluster}-firewall"
    
    if ! resource_exists firewall "${firewall_name}"; then
        echo -e "${BLUE}Creating ${cluster} cluster firewall...${NC}"
        
        hcloud firewall create --name "${firewall_name}" \
            --label "cluster=${cluster}" \
            --label "managed-by=caph"
        
        # Basic rules - SSH and internal communication
        hcloud firewall add-rule "${firewall_name}" \
            --direction in \
            --source-ips 10.0.0.0/8 \
            --protocol tcp \
            --port 22 \
            --description "SSH from internal networks"
        
        hcloud firewall add-rule "${firewall_name}" \
            --direction in \
            --source-ips 10.0.0.0/8 \
            --protocol tcp \
            --port any \
            --description "Internal cluster communication"
        
        hcloud firewall add-rule "${firewall_name}" \
            --direction in \
            --source-ips 10.0.0.0/8 \
            --protocol udp \
            --port any \
            --description "Internal cluster communication UDP"
    else
        echo -e "${GREEN}${cluster} firewall already exists${NC}"
    fi
done

# Create S3 buckets for backups (if using Hetzner Object Storage)
echo -e "${BLUE}Note: S3 buckets for Velero backups should be created manually in Hetzner Cloud Console${NC}"
echo -e "${YELLOW}Required buckets:${NC}"
echo "  - velero-backups-management"
echo "  - velero-backups-monitoring"
echo "  - velero-backups-dev"
echo "  - velero-backups-devops"
echo "  - velero-backups-staging"

# Summary
echo -e "${GREEN}✅ Hetzner resources setup completed!${NC}"
echo -e "${BLUE}Resources created/verified:${NC}"
echo "  - SSH Key: ${HETZNER_SSH_KEY}"
echo "  - Networks: ${!NETWORKS[@]}"
echo "  - Placement Groups: ${CLUSTERS[@]}"
echo "  - Firewalls: management-firewall, monitoring-firewall, dev-firewall, devops-firewall, staging-firewall"

echo -e "${BLUE}Next steps:${NC}"
echo "1. Create S3 buckets for Velero backups in Hetzner Cloud Console"
echo "2. Run: make deploy-management"
echo "3. Configure AWS Secrets Manager: make secrets"