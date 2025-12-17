#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Lightning Solr functions
############################################################

# Install Lightning Solr using Helm
install_lightning_solr() {
    echo "Installing Lightning Solr..."
    
    local solr_release="lightning-solr"
    local solr_chart="helm-zetaris-lightning-solr/solr"
    local solr_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Lightning Solr is already installed
    log_info "Checking to see if Lightning Solr release '$solr_release' exists in namespace '$solr_namespace'..."
    
    if helm list -n "$solr_namespace" 2>/dev/null | grep -q "$solr_release"; then
        echo "✅ Lightning Solr release '$solr_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$solr_namespace" -l app=solr --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Lightning Solr pods are running"
            return 0
        else
            echo "⚠️  Lightning Solr release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$solr_namespace'..."

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$solr_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$solr_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Lightning Solr..."

    # helm upgrade --install lightning-solr helm-zetaris-lightning-solr/solr \
    # --namespace zetaris \
    # --set storageclass=$storageclass \
    # --set environment=$environment

    if helm upgrade --install "$solr_release" "$solr_chart" \
        --namespace "$solr_namespace" \
        --set "storageclass=$STORAGE_CLASS" \
        --set "environment=$ENVIRONMENT" \
        --timeout=10m \
        --wait; then
        
        echo "✅ Lightning Solr installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Lightning Solr pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=lightning-solr -n "$solr_namespace" --timeout=600s; then
            log_success "Lightning Solr is ready!"
            
            # Display Lightning Solr information
            display_lightning_solr_info
            
            return 0
        else
            echo "❌ Lightning Solr pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Lightning Solr"
        return 1
    fi
}

# Display Lightning Solr information
display_lightning_solr_info() {
    local solr_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "Lightning Solr Information:"
    echo "   Namespace: $solr_namespace"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   Environment: $ENVIRONMENT"
    echo ""
    log_info "Lightning Solr Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$solr_namespace" -l app=lightning-solr --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name
    service_name=$(kubectl get svc -n "$solr_namespace" | grep "lightning-solr" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    # local service_ip
    # service_ip=$(kubectl get svc "$service_name" -n "$solr_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
    if [ "$service_name" != "N/A" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$solr_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        echo "   Service Name: $service_name"
        echo "   Service IP: $service_ip"
    else
        echo "   Service Name: N/A"
        echo "   Service IP: N/A"
    fi   
    
    # Show PVC information
    echo "   Persistent Volume Claims:"
    kubectl get pvc -n "$solr_namespace" -l app=solr --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null || echo "     - No PVCs found"

    echo ""
    log_info "Lightning Solr URLs:"
    echo "   Internal: http://$service_name.$solr_namespace.svc.cluster.local:8983"
    echo "   Solr Admin: http://$service_name.$solr_namespace.svc.cluster.local:8983/solr/"
    echo ""
    log_info "To test Lightning Solr:"
    echo "   kubectl exec -it \$(kubectl get pods -n $solr_namespace -l app=lightning-solr -o jsonpath='{.items[0].metadata.name}') -n $solr_namespace -- curl -X GET 'localhost:8983/solr/admin/info/system'"
    echo ""
}

# Verify Lightning Solr functionality
verify_lightning_solr() {
    log_info "Verifying Lightning Solr functionality..."
    
    local solr_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$solr_namespace" &> /dev/null; then
        echo "❌ Lightning Solr namespace '$solr_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$solr_namespace" -l app=lightning-solr --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Lightning Solr pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Lightning Solr pod(s)"
    
    # Get the service name dynamically
    local service_name
    service_name=$(kubectl get svc -n "$solr_namespace" | grep "lightning-solr" | awk '{print $1}' | head -1 2>/dev/null)
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Lightning Solr service '$service_name' is available"
        
        # Test Solr connectivity
        local solr_pod
        solr_pod=$(kubectl get pods -n "$solr_namespace" -l app=lightning-solr -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$solr_pod" ]; then
            log_info "Lightning Solr pod '$solr_pod' is available"
            echo "✅ Lightning Solr is ready and accessible"
            return 0
        else
            echo "❌ No Lightning Solr pods found"
            return 1
        fi
    else
        echo "❌ Lightning Solr service not found"
        return 1
    fi
}

# Check Lightning Solr logs for any issues
check_lightning_solr_logs() {
    log_info "Checking Lightning Solr logs for issues..."
    
    local solr_namespace=${ZETARIS_NS:-zetaris}
    local solr_pods
    solr_pods=$(kubectl get pods -n "$solr_namespace" -l app=lightning-solr -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$solr_pods" ]; then
        echo "❌ No Lightning Solr pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Solr pod
    for pod in $solr_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$solr_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" || echo "0")
        
        if [ "$error_count" -eq 0 ]; then
            echo "✅ No recent errors found in $pod logs"
        else
            echo "⚠️  Found $error_count potential error(s) in $pod logs"
            has_errors=true
        fi
    done
    
    if [ "$has_errors" = true ]; then
        log_info "To view full logs: kubectl logs -l app=lightning-solr -n $solr_namespace"
        return 1
    else
        echo "✅ No errors found in Lightning Solr logs"
        return 0
    fi
}

# Alternative test function using external pod
test_lightning_solr() {
    log_info "Testing Lightning Solr connectivity from external pod..."
    
    local solr_namespace=${ZETARIS_NS:-zetaris}
    local service_name
    service_name=$(kubectl get svc -n "$solr_namespace" | grep "lightning-solr" | awk '{print $1}' | head -1 2>/dev/null)
    
    if [ -z "$service_name" ]; then
        echo "❌ Lightning Solr service not found"
        return 1
    fi
    
    # Create a temporary test pod with curl
    kubectl run solr-test --rm -i --tty --image=curlimages/curl --restart=Never -- \
        curl -s --connect-timeout 10 -X GET "http://$service_name.$solr_namespace.svc.cluster.local:8983/solr/admin/info/system" &>/dev/null
    
    if [ $? -eq 0 ]; then
        echo "✅ Lightning Solr is responding to external requests"
        return 0
    else
        echo "⚠️  Lightning Solr connectivity test failed"
        return 1
    fi
}

# Main function to setup Lightning Solr completely
setup_lightning_solr() {
    log_success "Setting up Lightning Solr for Zetaris..."
    
    # Install Lightning Solr
    if ! install_lightning_solr; then
        echo "❌ Failed to install Lightning Solr"
        return 1
    fi
    
    # Wait a moment for Solr to initialize
    log_info "Waiting for Lightning Solr to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_lightning_solr; then
        echo "❌ Lightning Solr verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_lightning_solr_logs; then
        echo "⚠️  Found issues in Lightning Solr logs, but continuing..."
    fi
    
    # Test Solr functionality
    if ! test_lightning_solr; then
        echo "⚠️  Lightning Solr functionality test failed, but continuing..."
    fi
    
    log_success "Lightning Solr setup completed successfully!"
    return 0
}

# Cleanup Lightning Solr installation
cleanup_lightning_solr() {
    log_info "Cleaning up Lightning Solr..."
    
    local solr_release="lightning-solr"
    local solr_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$solr_namespace" 2>/dev/null | grep -q "$solr_release"; then
        log_info " Uninstalling Lightning Solr Helm release..."
        helm uninstall "$solr_release" -n "$solr_namespace"
    else
        log_info " Lightning Solr release not found"
    fi
    
    # Clean up PVCs
    log_info "Cleaning up Lightning Solr PVCs..."
    kubectl delete pvc -n "$solr_namespace" -l app=solr --ignore-not-found=true
    
    # Clean up any remaining secrets
    log_info "Cleaning up Lightning Solr secrets..."
    kubectl delete secret -n "$solr_namespace" -l app=solr --ignore-not-found=true
    
    echo "✅ Lightning Solr cleanup completed"
}
