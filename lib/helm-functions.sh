#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Helm functions
############################################################

# Check if Helm is installed and install if needed
install_helm() {
    local required_version="v3.10.0"  # Minimum required version
    local current_version=""
    
    log_info "Checking Helm installation..."
    
    # Check if helm command exists
    if command -v helm &> /dev/null; then
        current_version=$(helm version --short --client 2>/dev/null | cut -d: -f2 | tr -d ' ' || echo "")
        echo "✅ Helm found: $current_version"
        
        # Check if version meets minimum requirement
        if version_compare "$current_version" "$required_version"; then
            echo "✅ Helm version meets requirements ($required_version or higher)"
            return 0
        else
            echo "⚠️  Helm version $current_version is older than required $required_version"
            echo "Upgrading Helm..."
        fi
    else
        echo "❌ Helm not found. Installing Helm..."
    fi
    
    # Install/upgrade Helm
    echo "Downloading and installing Helm..."
    
    # Create temporary directory for installation
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    # Download and execute Helm installer
    # curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o "$temp_dir/get_helm.sh"; then
        chmod +x "$temp_dir/get_helm.sh"
        
        # Set installation directory (optional - defaults to /usr/local/bin)
        export HELM_INSTALL_DIR="${HELM_INSTALL_DIR:-/usr/local/bin}"
        
        # Run installer
        if "$temp_dir/get_helm.sh"; then
            echo "✅ Helm installed successfully!"
            
            # Verify installation
            if command -v helm &> /dev/null; then
                local new_version
                new_version=$(helm version --short --client 2>/dev/null | cut -d: -f2 | tr -d ' ')
                log_success "Helm $new_version is now available"
                
                # Initialize Helm (add stable repo)
                log_info "Initializing Helm repositories..."
                helm repo add stable https://charts.helm.sh/stable 2>/dev/null || true
                helm repo update
                
                return 0
            else
                echo "❌ Helm installation failed - command not found after installation"
                return 1
            fi
        else
            echo "❌ Helm installation script failed"
            return 1
        fi
    else
        echo "❌ Failed to download Helm installation script"
        return 1
    fi
}

# Compare semantic versions (returns 0 if current >= required)
version_compare() {
    local current="$1"
    local required="$2"
    
    # Remove 'v' prefix if present
    current="${current#v}"
    required="${required#v}"
    
    # Simple version comparison (works for semantic versions like 3.10.0)
    if [[ "$(printf '%s\n' "$required" "$current" | sort -V | head -n1)" == "$required" ]]; then
        return 0  # Current version is >= required
    else
        return 1  # Current version is < required
    fi
}

# Check Helm repositories and add common ones
setup_helm_repos() {
    log_info "Setting up Helm repositories..."
    
    local repos=(
        "stable:https://charts.helm.sh/stable"
        "bitnami:https://charts.bitnami.com/bitnami"
        "jetstack:https://charts.jetstack.io"
        "apache-airflow:https://airflow.apache.org"
        "spark-operator:https://kubeflow.github.io/spark-operator"
        "opensearch:https://opensearch-project.github.io/helm-charts/"
        "helm-postgres:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/openshift/$ZETARIS_RELEASE/postgres"
        "helm-zetaris-lightning-solr:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/HelmDeployment/$ZETARIS_RELEASE/solr/helm/"
        "helm-zetaris-lightning-server:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/zetaris-lightning/$ZETARIS_RELEASE/deployments/helm/"
        "helm-zetaris-lightning-api:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/lightning-api/$ZETARIS_RELEASE/deployments/helm/"
        "helm-zetaris-lightning-gui:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/lightning-gui/$ZETARIS_RELEASE/deployments/helm/"
        "helm-zetaris-lightning-zeppelin:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/zetaris-zeppelin/$ZETARIS_RELEASE/deployments/helm/"
        "helm-zetaris-digiavatar:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/digiavatar/$ZETARIS_RELEASE/deployments/helm/"
        "helm-zetaris-privateai:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/privateai/$ZETARIS_RELEASE/deployments/helm/"
        "helm-zetaris-airflow-ing:https://$ZETARIS_TOKEN@raw.githubusercontent.com/zetaris/HelmDeployment/$ZETARIS_RELEASE/airflow-ing/helm/"
    )
    
    for repo in "${repos[@]}"; do
        local name="${repo%%:*}"
        local url="${repo#*:}"
        
        log_info "Adding repository: $name"
        helm repo add "$name" "$url" 2>/dev/null || echo "⚠️  Repository $name already exists or failed to add"
    done
    
    echo "Updating repository cache..."
    helm repo update
    echo "✅ Helm repositories configured"
}

# Verify Helm can connect to Kubernetes
verify_helm_connectivity() {
    log_info "Verifying Helm connectivity to Kubernetes..."
    
    if helm list --all-namespaces &> /dev/null; then
        echo "✅ Helm can communicate with Kubernetes cluster"
        return 0
    else
        echo "❌ Helm cannot connect to Kubernetes cluster"
        log_info "Please check your kubectl configuration and cluster connectivity"
        return 1
    fi
}

# Main function to ensure Helm is ready
ensure_helm() {
    log_success "Ensuring Helm is installed and configured..."
    
    # Install Helm if needed
    if ! install_helm; then
        echo "❌ Failed to install Helm"
        return 1
    fi
    
    # Verify connectivity
    if ! verify_helm_connectivity; then
        echo "❌ Helm connectivity check failed"
        return 1
    fi
    
    # Setup repositories
    setup_helm_repos
    
    log_success "Helm is ready for use!"
    return 0
}