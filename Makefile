.PHONY: help setup check bootstrap deploy-management deploy-argocd deploy-all status clean

# Default target
help:
	@echo "Hetzner Multi-Cluster Kubernetes Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make setup          - Interactive setup wizard"
	@echo "  make configure      - Configure environment (.envrc)"
	@echo "  make check          - Check prerequisites"
	@echo "  make github         - Setup GitHub repositories"
	@echo "  make bootstrap      - Complete bootstrap (all clusters)"
	@echo "  make deploy-management - Deploy management cluster only"
	@echo "  make deploy-argocd  - Install ArgoCD on management cluster"
	@echo "  make deploy-all     - Deploy all clusters"
	@echo "  make status         - Show deployment status"
	@echo "  make secrets        - Manage secrets interactively"
	@echo "  make clean          - Clean up all resources (DESTRUCTIVE!)"
	@echo ""
	@echo "Quick start:"
	@echo "  1. make configure    # Interactive environment setup"
	@echo "  2. source .envrc"
	@echo "  3. make check        # Verify prerequisites"
	@echo "  4. make bootstrap    # Deploy everything"

# Run interactive setup
setup:
	@./setup.sh

# Check prerequisites
check:
	@./scripts/check-prerequisites.sh

# Setup GitHub repositories
github:
	@./scripts/setup-github-resources.sh

# Complete bootstrap
bootstrap: check
	@echo "Starting complete infrastructure bootstrap..."
	@./scripts/setup-github-resources.sh || { echo "GitHub setup failed"; exit 1; }
	@./scripts/setup-hetzner-resources.sh || { echo "Hetzner setup failed"; exit 1; }
	@./scripts/init-management-cluster.sh || { echo "Management cluster creation failed"; exit 1; }
	@./scripts/install-argocd.sh || { echo "ArgoCD installation failed"; exit 1; }
	@./scripts/apply-root-apps.sh || { echo "Root apps deployment failed"; exit 1; }
	@echo "Bootstrap complete! Check ArgoCD for application status."

# Resume bootstrap from specific steps
bootstrap-hetzner:
	@./scripts/setup-hetzner-resources.sh

bootstrap-cluster:
	@./scripts/init-management-cluster.sh

bootstrap-argocd:
	@./scripts/install-argocd.sh

bootstrap-apps:
	@./scripts/apply-root-apps.sh

# Deploy management cluster only
deploy-management: check
	@./scripts/init-management-cluster.sh

# Install ArgoCD
deploy-argocd:
	@./scripts/install-argocd.sh

# Deploy all clusters
deploy-all: deploy-management deploy-argocd
	@./scripts/apply-root-apps.sh
	@echo "Deploying workload clusters via GitOps..."
	@kubectl apply -f clusters/monitoring/
	@kubectl apply -f clusters/dev/
	@kubectl apply -f clusters/devops/
	@kubectl apply -f clusters/staging/

# Show status
status:
	@echo "=== Cluster Status ==="
	@kubectl get clusters -A 2>/dev/null || echo "No clusters found"
	@echo ""
	@echo "=== ArgoCD Applications ==="
	@kubectl -n argocd get applications 2>/dev/null || echo "ArgoCD not installed"
	@echo ""
	@echo "=== Nodes ==="
	@kubectl get nodes 2>/dev/null || echo "No nodes in current context"

# Manage secrets
secrets:
	@./scripts/manage-secrets.sh

# Clean up everything
clean:
	@echo "WARNING: This will delete all clusters and resources!"
	@echo "Press Ctrl+C to cancel, or Enter to continue..."
	@read confirm
	@echo "Deleting clusters..."
	@kubectl delete clusters --all -A 2>/dev/null || true
	@echo "Deleting Hetzner resources..."
	@hcloud server list -o noheader | awk '{print $$1}' | xargs -r -n1 hcloud server delete
	@hcloud load-balancer list -o noheader | awk '{print $$1}' | xargs -r -n1 hcloud load-balancer delete
	@hcloud volume list -o noheader | awk '{print $$1}' | xargs -r -n1 hcloud volume delete
	@echo "Cleanup complete."

# Create .envrc from example
env:
	@cp .envrc.example .envrc
	@echo "Created .envrc from example. Please edit it with your values."

# Configure environment interactively
configure:
	@./scripts/configure-environment.sh

# Show costs
costs:
	@echo "=== Estimated Monthly Costs ==="
	@echo "Management Cluster: €129"
	@echo "Monitoring Cluster: €227"
	@echo "Dev Cluster:        €65"
	@echo "DevOps Cluster:     €195"
	@echo "Staging Cluster:    €168"
	@echo "Load Balancers:     €50"
	@echo "Storage/Backups:    €100"
	@echo "DNS (Route53):      €20"
	@echo "=========================="
	@echo "Total:              ~€954/month"

# Validate configurations
validate:
	@echo "Validating cluster configurations..."
	@for cluster in management monitoring dev devops staging; do \
		echo "Checking $$cluster cluster config..."; \
		kubectl --dry-run=client apply -f clusters/$$cluster/ || exit 1; \
	done
	@echo "All configurations are valid!"

# Git operations
commit:
	@git add .
	@git commit -m "Update infrastructure configuration"
	@git push origin main

# Show logs
logs:
	@echo "=== CAPI Controller Logs ==="
	@kubectl -n capi-system logs -l control-plane=controller-manager --tail=20
	@echo ""
	@echo "=== CAPH Controller Logs ==="
	@kubectl -n caph-system logs -l control-plane=controller-manager --tail=20