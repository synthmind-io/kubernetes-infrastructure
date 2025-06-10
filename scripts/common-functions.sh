#!/bin/bash
# scripts/common-functions.sh
# Common functions used across scripts

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# AWS CLI wrapper that handles profiles
aws_cli() {
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        aws --profile "${AWS_PROFILE}" "$@"
    else
        aws "$@"
    fi
}

# Retry function for network operations
retry() {
    local max_attempts=${1:-3}
    local delay=${2:-5}
    shift 2
    local command=("$@")
    local attempt=1
    
    until "${command[@]}"; do
        if (( attempt == max_attempts )); then
            echo -e "${RED}Command failed after $max_attempts attempts${NC}"
            return 1
        fi
        echo -e "${YELLOW}Attempt $attempt failed, retrying in ${delay}s...${NC}"
        sleep "$delay"
        ((attempt++))
    done
    return 0
}

# Check cluster health
check_cluster_health() {
    local context=$1
    echo -e "${BLUE}Checking cluster health for context: $context${NC}"
    
    # Check API server
    if ! kubectl --context="$context" cluster-info >/dev/null 2>&1; then
        echo -e "${RED}Cluster API server not responding${NC}"
        return 1
    fi
    
    # Check nodes
    if ! kubectl --context="$context" get nodes >/dev/null 2>&1; then
        echo -e "${RED}Cannot retrieve nodes${NC}"
        return 1
    fi
    
    # Check system pods
    local unhealthy_pods
    unhealthy_pods=$(kubectl --context="$context" -n kube-system get pods -o json | \
        jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.name')
    
    if [[ -n "$unhealthy_pods" ]]; then
        echo -e "${YELLOW}Unhealthy system pods found:${NC}"
        echo "$unhealthy_pods"
        return 1
    fi
    
    echo -e "${GREEN}Cluster health check passed${NC}"
    return 0
}

# State management functions
STATE_FILE=".deployment-state"

save_state() {
    local step=$1
    local status=${2:-"completed"}
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $step $status" >> "$STATE_FILE"
}

check_state() {
    local step=$1
    if [[ -f "$STATE_FILE" ]] && grep -q "$step completed" "$STATE_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Get current state of a step
get_state() {
    local step=$1
    if [[ -f "$STATE_FILE" ]]; then
        grep "$step" "$STATE_FILE" | tail -1 | awk '{print $3}'
    else
        echo "not_started"
    fi
}

# Wait for resource with timeout and status
wait_for_resource() {
    local resource=$1
    local namespace=${2:-default}
    local condition=${3:-Ready}
    local timeout=${4:-300}
    
    echo -e "${BLUE}Waiting for $resource to be $condition (timeout: ${timeout}s)...${NC}"
    
    if kubectl wait --for=condition="$condition" "$resource" -n "$namespace" --timeout="${timeout}s"; then
        echo -e "${GREEN}$resource is $condition${NC}"
        return 0
    else
        echo -e "${RED}Timeout waiting for $resource to be $condition${NC}"
        return 1
    fi
}

# Generate secure password
generate_password() {
    local length=${1:-24}
    openssl rand -base64 "$length" | tr -d "=+/" | cut -c1-"$length"
}

# Check if running in CI/CD environment
is_ci() {
    [[ -n "${CI:-}" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ -n "${GITLAB_CI:-}" ]]
}

# Get Load Balancer IP with retry
get_lb_ip() {
    local service=$1
    local namespace=$2
    local max_wait=${3:-300}
    local interval=10
    local elapsed=0
    
    echo -e "${BLUE}Waiting for Load Balancer IP for $service in $namespace...${NC}"
    
    while (( elapsed < max_wait )); do
        local ip
        ip=$(kubectl -n "$namespace" get svc "$service" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        
        if [[ -n "$ip" ]]; then
            echo -e "${GREEN}Load Balancer IP: $ip${NC}"
            echo "$ip"
            return 0
        fi
        
        sleep $interval
        (( elapsed += interval ))
        echo -e "${YELLOW}Still waiting... ($elapsed/$max_wait seconds)${NC}"
    done
    
    echo -e "${RED}Timeout waiting for Load Balancer IP${NC}"
    return 1
}

# Validate CIDR format
validate_cidr() {
    local cidr=$1
    if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        return 0
    else
        echo -e "${RED}Invalid CIDR format: $cidr${NC}"
        return 1
    fi
}

# Check if resource exists in Hetzner
hcloud_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    
    case $resource_type in
        server|network|firewall|placement-group|ssh-key|load-balancer|volume)
            hcloud "$resource_type" describe "$resource_name" >/dev/null 2>&1
            ;;
        *)
            echo -e "${RED}Unknown resource type: $resource_type${NC}"
            return 1
            ;;
    esac
}

# Export functions for use in other scripts
export -f aws_cli retry check_cluster_health save_state check_state get_state
export -f wait_for_resource generate_password is_ci get_lb_ip validate_cidr
export -f hcloud_resource_exists