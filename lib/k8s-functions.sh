#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

# Create Kubernetes namespaces with error handling
create_namespaces() {
    local namespaces=("zetaris" "airflow" "cert-manager")
    
    log_info "Creating Kubernetes namespaces..."
    
    for namespace in "${namespaces[@]}"; do
        log_info "Creating namespace: $namespace"
        
        if kubectl get namespace "$namespace" &> /dev/null; then
            echo "✅ Namespace '$namespace' already exists"
        else
            if kubectl create namespace "$namespace"; then
                echo "✅ Namespace '$namespace' created successfully"
            else
                echo "❌ Failed to create namespace '$namespace'"
                return 1
            fi
        fi
    done
    
    log_success "All namespaces created successfully!"
    return 0
}

# Create service accounts in their respective namespaces
create_service_accounts() {
    # Array of "serviceaccount:namespace" pairs
    local service_accounts=(
        "zetaris-sa:zetaris"
        # Add more service accounts here as needed
        # "airflow-sa:airflow"
        # "cert-manager-sa:cert-manager"
    )
    
    log_info "Creating Kubernetes service accounts..."
    
    for sa_entry in "${service_accounts[@]}"; do
        local sa_name="${sa_entry%%:*}"
        local sa_namespace="${sa_entry#*:}"
        
        log_info "Creating service account: $sa_name in namespace: $sa_namespace"
        
        # Ensure namespace exists first
        if ! kubectl get namespace "$sa_namespace" &> /dev/null; then
            echo "⚠️  Namespace '$sa_namespace' does not exist. Creating it first..."
            if ! kubectl create namespace "$sa_namespace"; then
                echo "❌ Failed to create namespace '$sa_namespace'"
                return 1
            fi
        fi
        
        # Check if service account already exists
        if kubectl get serviceaccount "$sa_name" -n "$sa_namespace" &> /dev/null; then
            echo "✅ Service account '$sa_name' already exists in namespace '$sa_namespace'"
        else
            if kubectl create serviceaccount "$sa_name" -n "$sa_namespace"; then
                echo "✅ Service account '$sa_name' created successfully in namespace '$sa_namespace'"
            else
                echo "❌ Failed to create service account '$sa_name' in namespace '$sa_namespace'"
                return 1
            fi
        fi
    done
    
    echo "SUCCESS: All service accounts created successfully!"
    return 0
}

# Add Helm metadata to existing service account (for Helm management)
add_helm_metadata_to_serviceaccount() {
    local sa_name="$1"
    local sa_namespace="$2"
    local helm_release="$3"
    
    echo "LABELING: Adding Helm metadata to service account: $sa_name"
    
    # Check if service account exists
    if ! kubectl get serviceaccount "$sa_name" -n "$sa_namespace" &> /dev/null; then
        echo "❌ Service account '$sa_name' not found in namespace '$sa_namespace'"
        return 1
    fi
    
    # Add Helm labels
    kubectl label serviceaccount "$sa_name" -n "$sa_namespace" \
        app.kubernetes.io/managed-by=Helm \
        --overwrite
    
    # Add Helm annotations
    kubectl annotate serviceaccount "$sa_name" -n "$sa_namespace" \
        meta.helm.sh/release-name="$helm_release" \
        meta.helm.sh/release-namespace="$sa_namespace" \
        --overwrite
    
    echo "✅ Helm metadata added to service account '$sa_name'"
    return 0
}

# Add labels to namespaces
label_namespace() {
    local namespace="$1"
    local label_key="$2"
    local label_value="$3"
    
    echo "LABELING: Adding label to namespace: $namespace"
    
    # Check if namespace exists
    if ! kubectl get namespace "$namespace" &> /dev/null; then
        echo "❌ Namespace '$namespace' not found"
        return 1
    fi
    
    # Add the label
    if kubectl label namespace "$namespace" "$label_key=$label_value" --overwrite; then
        echo "✅ Label '$label_key=$label_value' added to namespace '$namespace'"
        return 0
    else
        echo "❌ Failed to add label to namespace '$namespace'"
        return 1
    fi
}

# Configure cert-manager namespace with required label
configure_cert_manager_namespace() {
    echo "CONFIG: Configuring cert-manager namespace..."
    
    # Ensure cert-manager namespace exists
    if ! kubectl get namespace cert-manager &> /dev/null; then
        echo "CREATING: Creating cert-manager namespace..."
        if ! kubectl create namespace cert-manager; then
            echo "❌ Failed to create cert-manager namespace"
            return 1
        fi
    fi
    
    # Add the cert-manager validation disable label
    if label_namespace "cert-manager" "certmanager.k8s.io/disable-validation" "true"; then
        echo "✅ cert-manager namespace configured successfully"
        return 0
    else
        return 1
    fi
}

# Verify Kubernetes connectivity
verify_k8s_connectivity() {
    echo "VERIFYING: Verifying Kubernetes connectivity..."
    
    if kubectl cluster-info &> /dev/null; then
        echo "✅ Successfully connected to Kubernetes cluster"
        
        # Get cluster info
        local cluster_info
        cluster_info=$(kubectl config current-context 2>/dev/null || echo "unknown")
        echo "INFO: Current context: $cluster_info"
        
        # Check if we can list nodes
        local node_count
        node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        echo "INFO: Cluster nodes: $node_count"
        
        return 0
    else
        echo "❌ Cannot connect to Kubernetes cluster"
        echo "HINT: Please check your kubectl configuration and cluster connectivity"
        return 1
    fi
}

# Check required Kubernetes resources
check_k8s_prerequisites() {
    echo "CHECKING: Checking Kubernetes prerequisites..."
    
    local requirements_met=true
    
    # Check if kubectl is installed
    if command -v kubectl &> /dev/null; then
        echo "✅ kubectl is installed"
    else
        echo "❌ kubectl is not installed"
        requirements_met=false
    fi
    
    # Check Kubernetes connectivity
    if ! verify_k8s_connectivity; then
        requirements_met=false
    fi
    
    # Check for required storage classes
    local required_storage_classes=("${STORAGE_CLASS:-nfs-rwx}")
    
    for sc in "${required_storage_classes[@]}"; do
        if kubectl get storageclass "$sc" &> /dev/null; then
            echo "✅ Storage class '$sc' is available"
        else
            echo "⚠️  Storage class '$sc' not found"
            echo "INFO: Available storage classes:"
            kubectl get storageclass --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sed 's/^/   - /' || echo "   (none found)"
        fi
    done
    
    if $requirements_met; then
        echo "SUCCESS: All Kubernetes prerequisites met!"
        return 0
    else
        echo "❌ Some prerequisites are missing"
        return 1
    fi
}

# List all created resources for verification
list_k8s_resources() {
    local namespaces=("zetaris" "airflow" "cert-manager")
    
    echo "LISTING: Listing created Kubernetes resources..."
    
    for namespace in "${namespaces[@]}"; do
        if kubectl get namespace "$namespace" &> /dev/null; then
            echo ""
            echo "NAMESPACE: $namespace"
            
            # List service accounts
            local sa_count
            sa_count=$(kubectl get serviceaccounts -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
            if [ "$sa_count" -gt 0 ]; then
                echo "   Service Accounts:"
                kubectl get serviceaccounts -n "$namespace" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | sed 's/^/     - /' || true
            fi
            
            # List pods
            local pod_count
            pod_count=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | wc -l || echo "0")
            if [ "$pod_count" -gt 0 ]; then
                echo "   Pods:"
                kubectl get pods -n "$namespace" --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null | sed 's/^/     - /' || true
            fi
        fi
    done
}

# Main function to setup Kubernetes prerequisites
setup_k8s_environment() {
    echo "SETUP: Setting up Kubernetes environment for Zetaris..."
    
    # Check prerequisites
    if ! check_k8s_prerequisites; then
        echo "❌ Prerequisites check failed"
        return 1
    fi
    
    # Create namespaces
    if ! create_namespaces; then
        echo "❌ Failed to create namespaces"
        return 1
    fi
    
    # Create service accounts
    if ! create_service_accounts; then
        echo "❌ Failed to create service accounts"
        return 1
    fi
    
    # List resources for verification
    list_k8s_resources
    
    echo "SUCCESS: Kubernetes environment setup completed!"
    return 0
}

# Cleanup function for uninstall
cleanup_k8s_resources() {
    local namespaces=("zetaris" "airflow" "cert-manager")
    
    echo "CLEANUP: Cleaning up Kubernetes resources..."
    
    for namespace in "${namespaces[@]}"; do
        if kubectl get namespace "$namespace" &> /dev/null; then
            echo "DELETING: Deleting namespace: $namespace"
            kubectl delete namespace "$namespace" --ignore-not-found=true
        else
            echo "ℹ️  Namespace '$namespace' does not exist"
        fi
    done
    
    echo "✅ Kubernetes cleanup completed"
}

# Example usage functions - call these from your main installer
# setup_k8s_environment
# add_helm_metadata_to_serviceaccount "zetaris-sa" "zetaris" "lightning-server"