#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# OpenSearch functions
############################################################

# Install OpenSearch using Helm
install_opensearch() {
    log_info "Installing OpenSearch..."
    
    local opensearch_release="opensearch"
    local opensearch_chart="opensearch/opensearch"
    local opensearch_namespace=${ZETARIS_NS:-zetaris}
    local opensearch_version="2.11.0"
    
    # Check if OpenSearch is already installed
    log_info "Checking to see if OpenSearch release '$opensearch_release' exists in namespace '$opensearch_namespace'..."
    
    if helm list -n "$opensearch_namespace" 2>/dev/null | grep -q "$opensearch_release"; then
        echo "✅ OpenSearch release '$opensearch_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "OpenSearch pods are running"
            return 0
        else
            echo "⚠️  OpenSearch release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$opensearch_namespace'..."

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$opensearch_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$opensearch_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    # Install or upgrade OpenSearch

    log_info "Installing/upgrading OpenSearch..."

    if helm upgrade --install "$opensearch_release" "$opensearch_chart" \
        --namespace "$opensearch_namespace" \
        --set "image.tag=$opensearch_version" \
        --set "serviceAccount.name=zetaris-sa" \
        --timeout=5m \
        --wait; then
        
        echo "✅ OpenSearch installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for OpenSearch pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=opensearch -n "$opensearch_namespace" --timeout=600s; then
            log_success "OpenSearch is ready!"
            
            # Display OpenSearch information
            log_info "OpenSearch info:"
            display_opensearch_info
            
            return 0
        else
            echo "❌ OpenSearch pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install OpenSearch"
        return 1
    fi
}

# Display OpenSearch information
display_opensearch_info() {
    local opensearch_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "OpenSearch Information:"
    echo "   Namespace: $opensearch_namespace"
    echo "   Version: 2.11.0"
    echo "   Service Account: zetaris-sa"
    echo "   Storage Class: $STORAGE_CLASS"
    echo ""
    log_info "OpenSearch Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_ip
    service_ip=$(kubectl get svc opensearch-master -n "$opensearch_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
    echo "   Service IP: $service_ip"
    echo "   Service Port: 9200"
    
    # Show PVC information
    echo "   Persistent Volume Claims:"
    # kubectl get pvc -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null | sed 's/^/     - /' || echo "     - (checking...)"
    kubectl get pvc -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null

    echo ""
    log_info "OpenSearch URLs:"
    echo "   Internal: http://opensearch-master.$opensearch_namespace.svc.cluster.local:9200"
    echo "   Dashboard: http://opensearch-master.$opensearch_namespace.svc.cluster.local:5601"
    echo ""
    log_info "To test OpenSearch:"
    echo "   kubectl exec -it \$(kubectl get pods -n $opensearch_namespace -l app.kubernetes.io/name=opensearch -o jsonpath='{.items[0].metadata.name}') -n $opensearch_namespace -- curl -X GET 'localhost:9200'"
    echo ""
}

# Verify OpenSearch functionality
verify_opensearch() {
    log_info "Verifying OpenSearch functionality..."
    
    local opensearch_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$opensearch_namespace" &> /dev/null; then
        echo "❌ OpenSearch namespace '$opensearch_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    # running_pods=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    running_pods=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running OpenSearch pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running OpenSearch pod(s)"
    
    # Check if service exists
    if kubectl get svc opensearch-cluster-master -n "$opensearch_namespace" &> /dev/null; then
        echo "✅ OpenSearch service is available"
        
        # # Test OpenSearch connectivity
        # local opensearch_pod
        # # opensearch_pod=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        # opensearch_pod=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        # if [ -n "$opensearch_pod" ]; then
        #     log_info "Testing OpenSearch connectivity..."
        #     if kubectl exec -n "$opensearch_namespace" "$opensearch_pod" -- curl -s -X GET 'localhost:9200' &>/dev/null; then
        #         echo "✅ OpenSearch is responding to requests"
        #         return 0
        #     else
        #         echo "⚠️  OpenSearch is not responding to requests yet"
        #         return 1
        #     fi
        # fi
    else
        echo "❌ OpenSearch service not found"
        return 1
    fi
}

# Check OpenSearch logs for any issues
check_opensearch_logs() {
    log_info "Checking OpenSearch logs for issues..."
    
    local opensearch_namespace=${ZETARIS_NS:-zetaris}
    local opensearch_pods
    opensearch_pods=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$opensearch_pods" ]; then
        echo "❌ No OpenSearch pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each OpenSearch pod
    for pod in $opensearch_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$opensearch_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
        # Ensure error_count is a valid integer
        if ! [[ "$error_count" =~ ^[0-9]+$ ]]; then
            error_count=0
        fi
        
        if [ "$error_count" -eq 0 ]; then
            echo "✅ No recent errors found in $pod logs"
        else
            echo "⚠️  Found $error_count potential error(s) in $pod logs"
            has_errors=true
        fi
    done
    
    if [ "$has_errors" = true ]; then
        log_info "To view full logs: kubectl logs -l app.kubernetes.io/name=opensearch -n $opensearch_namespace"
        return 1
    else
        echo "✅ No errors found in OpenSearch logs"
        return 0
    fi
}

# Test OpenSearch with a simple query
test_opensearch() {
    log_info "Testing OpenSearch with a simple query..."
    
    local opensearch_namespace=${ZETARIS_NS:-zetaris}
    local opensearch_pod
    opensearch_pod=$(kubectl get pods -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$opensearch_pod" ]; then
        echo "❌ No OpenSearch pods found"
        return 1
    fi
    
    # Test cluster health
    log_info "Checking cluster health..."
    if kubectl exec -n "$opensearch_namespace" "$opensearch_pod" -- curl -s -X GET 'localhost:9200/_cluster/health' 2>/dev/null | grep -q '"status":"green\|yellow"'; then
        echo "✅ OpenSearch cluster is healthy"
        
        # Test basic indexing
        log_info "Testing basic indexing..."
        if kubectl exec -n "$opensearch_namespace" "$opensearch_pod" -- curl -s -X PUT 'localhost:9200/test-index' -H 'Content-Type: application/json' -d '{"settings":{"number_of_shards":1}}' &>/dev/null; then
            echo "✅ Test index created successfully"
            
            # Clean up test index
            kubectl exec -n "$opensearch_namespace" "$opensearch_pod" -- curl -s -X DELETE 'localhost:9200/test-index' &>/dev/null
            log_info "Test index cleaned up"
            
            return 0
        else
            echo "⚠️  Failed to create test index"
            return 1
        fi
    else
        echo "⚠️  OpenSearch cluster health check failed"
        return 1
    fi
}

# Main function to setup OpenSearch completely
setup_opensearch() {
    log_success "Setting up OpenSearch for Zetaris..."
    
    # Install OpenSearch
    if ! install_opensearch; then
        echo "❌ Failed to install OpenSearch"
        return 1
    fi
    
    # Wait a moment for OpenSearch to initialize
    log_info "Waiting for OpenSearch to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_opensearch; then
        echo "❌ OpenSearch verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_opensearch_logs; then
        echo "⚠️  Found issues in OpenSearch logs, but continuing..."
    fi
    
    # Test OpenSearch functionality
    if ! test_opensearch; then
        echo "⚠️  OpenSearch functionality test failed, but continuing..."
    fi
    
    log_success "OpenSearch setup completed successfully!"
    return 0
}

# Cleanup OpenSearch installation
cleanup_opensearch() {
    log_info "Cleaning up OpenSearch..."
    
    local opensearch_release="opensearch"
    local opensearch_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$opensearch_namespace" 2>/dev/null | grep -q "$opensearch_release"; then
        log_info " Uninstalling OpenSearch Helm release..."
        helm uninstall "$opensearch_release" -n "$opensearch_namespace"
    else
        log_info " OpenSearch release not found"
    fi

    # Force delete any remaining pods
    log_info "Deleting OpenSearch pods..."
    kubectl delete pod opensearch-cluster-master-0 opensearch-cluster-master-1 opensearch-cluster-master-2 -n zetaris --force --grace-period=0

    
    # Clean up PVCs
    # kubectl delete pvc -n zetaris -l app.kubernetes.io/name=opensearch --force --grace-period=0
    log_info "Cleaning up OpenSearch PVCs..."
    kubectl delete pvc -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --force --grace-period=0 --ignore-not-found=true
    
    log_info "Cleaning up OpenSearch statefulsets..."
    kubectl delete statefulset -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --force --grace-period=0

    # Clean up any remaining secrets
    log_info "Cleaning up OpenSearch secrets..."
    kubectl delete secret -n "$opensearch_namespace" -l app.kubernetes.io/name=opensearch --ignore-not-found=true

    echo "✅ OpenSearch cleanup completed"
}

