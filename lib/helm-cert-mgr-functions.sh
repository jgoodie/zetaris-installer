#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Cert-Manager functions
############################################################

# Install cert-manager using Helm
install_cert_manager() {
    log_info "Installing cert-manager..."
    
    local cert_manager_release="cert-manager"
    local cert_manager_chart="jetstack/cert-manager"
    local cert_manager_namespace="cert-manager"
    local cert_manager_version="v1.7.0"
    
    # Check if cert-manager is already installed
    if helm list -n "$cert_manager_namespace" 2>/dev/null | grep -q "$cert_manager_release"; then
        echo "✅ cert-manager release '$cert_manager_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$cert_manager_namespace" -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "cert-manager pods are running"
            return 0
        else
            echo "⚠️  cert-manager release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Installing/upgrading cert-manager..."
    
    # Ensure namespace exists and has proper labels
    if ! kubectl get namespace "$cert_manager_namespace" &> /dev/null; then
        log_info "Creating cert-manager namespace..."
        kubectl create namespace "$cert_manager_namespace"
    fi
    
    # Add the disable validation label
    echo "Adding validation disable label to cert-manager namespace..."
    kubectl label namespace "$cert_manager_namespace" certmanager.k8s.io/disable-validation=true --overwrite
    
    # Install or upgrade cert-manager
    if helm upgrade --install "$cert_manager_release" "$cert_manager_chart" \
        --namespace "$cert_manager_namespace" \
        --version="$cert_manager_version" \
        --set installCRDs=true \
        --timeout=10m \
        --wait; then
        
        echo "✅ cert-manager installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for cert-manager pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=cert-manager -n "$cert_manager_namespace" --timeout=300s; then
            log_success "cert-manager is ready!"
            
            # Display cert-manager information
            display_cert_manager_info
            
            return 0
        else
            echo "❌ cert-manager pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install cert-manager"
        return 1
    fi
}

# Display cert-manager information
display_cert_manager_info() {
    local cert_manager_namespace="cert-manager"
    
    echo ""
    log_info "cert-manager Information:"
    echo "   Namespace: $cert_manager_namespace"
    echo "   Version: v1.7.0"
    echo "   CRDs: Installed"
    echo ""
    log_info "cert-manager Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$cert_manager_namespace" -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show cert-manager components
    echo "   Components:"
    kubectl get pods -n "$cert_manager_namespace" --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null | sed 's/^/     - /' || echo "     - (checking...)"
    
    # Show CRDs
    echo "   Custom Resource Definitions:"
    kubectl get crd | grep -E "(certificates|issuers|clusterissuers)" | awk '{print $1}' | sed 's/^/     - /' 2>/dev/null || echo "     - (checking...)"
    
    echo ""
    log_info "To create a Certificate Issuer:"
    echo "   kubectl apply -f your-issuer.yaml"
    echo ""
    log_info "To list Certificates:"
    echo "   kubectl get certificates -A"
    echo ""
}

# Verify cert-manager functionality
verify_cert_manager() {
    log_info "Verifying cert-manager functionality..."
    
    local cert_manager_namespace="cert-manager"
    
    # Check if namespace exists
    if ! kubectl get namespace "$cert_manager_namespace" &> /dev/null; then
        echo "❌ cert-manager namespace '$cert_manager_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$cert_manager_namespace" -l app.kubernetes.io/name=cert-manager --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running cert-manager pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running cert-manager pod(s)"
    
    # Check if CRDs are installed
    local crd_count
    crd_count=$(kubectl get crd 2>/dev/null | grep -c -E "(certificates|issuers|clusterissuers)" || echo "0")
    
    if [ "$crd_count" -ge 3 ]; then
        echo "✅ cert-manager CRDs are installed ($crd_count found)"
        
        # List the CRDs
        log_info "Available cert-manager CRDs:"
        kubectl get crd 2>/dev/null | grep -E "(certificates|issuers|clusterissuers)" | awk '{print $1}' | sed 's/^/   - /'
        
        return 0
    else
        echo "❌ cert-manager CRDs not found or incomplete ($crd_count found, expected at least 3)"
        return 1
    fi
}

# Check cert-manager logs for any issues
check_cert_manager_logs() {
    log_info "Checking cert-manager logs for issues..."
    
    local cert_manager_namespace="cert-manager"
    local cert_manager_pods
    cert_manager_pods=$(kubectl get pods -n "$cert_manager_namespace" -l app.kubernetes.io/name=cert-manager -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$cert_manager_pods" ]; then
        echo "❌ No cert-manager pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each cert-manager pod
    for pod in $cert_manager_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$cert_manager_namespace" --tail=50 2>/dev/null | grep -i -c "error\|failed\|panic" || echo "0")
        
        if [ "$error_count" -eq 0 ]; then
            echo "✅ No recent errors found in $pod logs"
        else
            echo "⚠️  Found $error_count potential error(s) in $pod logs"
            has_errors=true
        fi
    done
    
    if [ "$has_errors" = true ]; then
        log_info "To view full logs: kubectl logs -l app.kubernetes.io/name=cert-manager -n $cert_manager_namespace"
        return 1
    else
        echo "✅ No errors found in cert-manager logs"
        return 0
    fi
}

# Test cert-manager with a simple self-signed issuer
test_cert_manager() {
    log_info "Testing cert-manager with a self-signed issuer..."
    
    local cert_manager_namespace="cert-manager"
    local test_issuer_name="test-selfsigned-issuer"
    
    # Create a simple self-signed ClusterIssuer for testing
    cat <<EOF | kubectl apply -f - 2>/dev/null
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: $test_issuer_name
spec:
  selfSigned: {}
EOF
    
    if [ $? -eq 0 ]; then
        echo "✅ Test ClusterIssuer created successfully"
        
        # Wait a moment for the issuer to be ready
        sleep 5
        
        # Check if the issuer is ready
        if kubectl get clusterissuer "$test_issuer_name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
            echo "✅ Test ClusterIssuer is ready"
            
            # Clean up the test issuer
            kubectl delete clusterissuer "$test_issuer_name" --ignore-not-found=true
            log_info "Test ClusterIssuer cleaned up"
            
            return 0
        else
            echo "⚠️  Test ClusterIssuer is not ready"
            kubectl delete clusterissuer "$test_issuer_name" --ignore-not-found=true
            return 1
        fi
    else
        echo "❌ Failed to create test ClusterIssuer"
        return 1
    fi
}

# Main function to setup cert-manager completely
setup_cert_manager() {
    log_success "Setting up cert-manager for Zetaris..."
    
    # Install cert-manager
    if ! install_cert_manager; then
        echo "❌ Failed to install cert-manager"
        return 1
    fi
    
    # Wait a moment for initialization
    log_info "Waiting for cert-manager to initialize..."
    sleep 10
    
    # Verify functionality
    if ! verify_cert_manager; then
        echo "❌ cert-manager verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_cert_manager_logs; then
        echo "⚠️  Found issues in cert-manager logs, but continuing..."
    fi
    
    # Test cert-manager functionality
    if ! test_cert_manager; then
        echo "⚠️  cert-manager functionality test failed, but continuing..."
    fi
    
    log_success "cert-manager setup completed successfully!"
    return 0
}

# Cleanup cert-manager installation
cleanup_cert_manager() {
    log_info "Cleaning up cert-manager..."
    
    local cert_manager_release="cert-manager"
    local cert_manager_namespace="cert-manager"
    
    # Clean up any existing certificates and issuers first
    log_info "Cleaning up certificates and issuers..."
    kubectl delete certificates --all --all-namespaces --ignore-not-found=true
    kubectl delete issuers --all --all-namespaces --ignore-not-found=true
    kubectl delete clusterissuers --all --ignore-not-found=true
    
    # Uninstall Helm release
    if helm list -n "$cert_manager_namespace" 2>/dev/null | grep -q "$cert_manager_release"; then
        log_info " Uninstalling cert-manager Helm release..."
        helm uninstall "$cert_manager_release" -n "$cert_manager_namespace"
    else
        log_info " cert-manager release not found"
    fi
    
    # Clean up CRDs (optional - be careful as this affects cluster-wide resources)
    echo "⚠️  Cleaning up cert-manager CRDs..."
    kubectl delete crd certificates.cert-manager.io --ignore-not-found=true
    kubectl delete crd certificaterequests.cert-manager.io --ignore-not-found=true
    kubectl delete crd issuers.cert-manager.io --ignore-not-found=true
    kubectl delete crd clusterissuers.cert-manager.io --ignore-not-found=true
    kubectl delete crd orders.acme.cert-manager.io --ignore-not-found=true
    kubectl delete crd challenges.acme.cert-manager.io --ignore-not-found=true
    
    # Delete namespace
    log_info " Deleting cert-manager namespace..."
    kubectl delete namespace "$cert_manager_namespace" --ignore-not-found=true
    
    echo "✅ cert-manager cleanup completed"
}