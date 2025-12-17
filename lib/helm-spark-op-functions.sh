#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi


############################################################
# Spark-Operator functions
############################################################

# Install Spark Operator using Helm
install_spark_operator() {
    log_info "Installing Spark Operator..."
    
    local spark_release="spark-operator"
    local spark_chart="spark-operator/spark-operator"
    local spark_namespace="spark-operator"
    local spark_version="1.2.15"
    
    # Check if Spark Operator is already installed
    if helm list -n "$spark_namespace" 2>/dev/null | grep -q "$spark_release"; then
        echo "✅ Spark Operator release '$spark_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$spark_namespace" -l app.kubernetes.io/name=spark-operator --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Spark Operator pods are running"
            return 0
        else
            echo "⚠️  Spark Operator release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Installing/upgrading Spark Operator..."
    
    # Install or upgrade Spark Operator
    if helm upgrade --install "$spark_release" "$spark_chart" \
        --namespace "$spark_namespace" \
        --create-namespace \
        --version="$spark_version" \
        --set webhook.enable=true \
        --timeout=10m \
        --wait; then
        
        echo "✅ Spark Operator installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Spark Operator pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=spark-operator -n "$spark_namespace" --timeout=300s; then
            log_success "Spark Operator is ready!"
            
            # Display Spark Operator information
            display_spark_operator_info
            
            return 0
        else
            echo "❌ Spark Operator pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Spark Operator"
        return 1
    fi
}

# Display Spark Operator information
display_spark_operator_info() {
    local spark_namespace="spark-operator"
    
    echo ""
    log_info "Spark Operator Information:"
    echo "   Namespace: $spark_namespace"
    echo "   Version: 1.2.15"
    echo "   Webhook: Enabled"
    echo ""
    log_info "Spark Operator Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$spark_namespace" -l app.kubernetes.io/name=spark-operator --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show CRDs
    echo "   Custom Resource Definitions:"
    kubectl get crd | grep -E "(sparkapplications|sparkscheduledapplications)" | sed 's/^/     - /' 2>/dev/null || echo "     - (checking...)"
    
    echo ""
    log_info "To create a Spark Application:"
    echo "   kubectl apply -f your-spark-app.yaml"
    echo ""
    log_info "To list Spark Applications:"
    echo "   kubectl get sparkapplications -n $spark_namespace"
    echo ""
}

# Verify Spark Operator functionality
verify_spark_operator() {
    log_info "Verifying Spark Operator functionality..."
    
    local spark_namespace="spark-operator"
    
    # Check if namespace exists
    if ! kubectl get namespace "$spark_namespace" &> /dev/null; then
        echo "❌ Spark Operator namespace '$spark_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local pod_count
    pod_count=$(kubectl get pods -n "$spark_namespace" -l app.kubernetes.io/name=spark-operator --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "$pod_count" -eq 0 ]; then
        echo "❌ No running Spark Operator pods found"
        return 1
    fi
    
    echo "✅ Found $pod_count running Spark Operator pod(s)"
    
    # Check if CRDs are installed
    local crd_count
    crd_count=$(kubectl get crd 2>/dev/null | grep -c -E "(sparkapplications|sparkscheduledapplications)" || echo "0")
    
    if [ "$crd_count" -ge 1 ]; then
        echo "✅ Spark Operator CRDs are installed ($crd_count found)"
        
        # List the CRDs
        log_info "Available Spark CRDs:"
        kubectl get crd 2>/dev/null | grep -E "(sparkapplications|sparkscheduledapplications)" | awk '{print $1}' | sed 's/^/   - /'
        
        return 0
    else
        echo "❌ Spark Operator CRDs not found"
        return 1
    fi
}

# Check Spark Operator logs for any issues
check_spark_operator_logs() {
    log_info "Checking Spark Operator logs for issues..."
    
    local spark_namespace="spark-operator"
    local spark_pod
    spark_pod=$(kubectl get pods -n "$spark_namespace" -l app.kubernetes.io/name=spark-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$spark_pod" ]; then
        echo "❌ No Spark Operator pods found"
        return 1
    fi
    
    log_info "Checking logs for pod: $spark_pod"
    
    # Check for errors in recent logs
    local error_count
    error_count=$(kubectl logs "$spark_pod" -n "$spark_namespace" --tail=50 2>/dev/null | grep -i -c "error\|failed\|panic" 2>/dev/null || echo "0")
    # Clean any whitespace/newlines from error_count
    error_count=$(echo "$error_count" | tr -d '\n\r' | xargs)
    
    if [ "${error_count:-0}" -eq 0 ]; then
        echo "✅ No recent errors found in Spark Operator logs"
        return 0
    else
        echo "⚠️  Found $error_count potential error(s) in recent logs"
        log_info "To view full logs: kubectl logs $spark_pod -n $spark_namespace"
        
        # Show last few lines with potential issues
        log_info "Recent log entries with potential issues:"
        kubectl logs "$spark_pod" -n "$spark_namespace" --tail=20 2>/dev/null | grep -i "error\|failed\|panic" | head -5 | sed 's/^/   /'
        
        return 1
    fi
}

# Main function to setup Spark Operator completely
setup_spark_operator() {
    log_success "Setting up Spark Operator for Zetaris..."
    
    # Install Spark Operator
    if ! install_spark_operator; then
        echo "❌ Failed to install Spark Operator"
        return 1
    fi
    
    # Wait a moment for initialization
    log_info "Waiting for Spark Operator to initialize..."
    sleep 5
    
    # Verify functionality
    if ! verify_spark_operator; then
        echo "❌ Spark Operator verification failed"
        return 1
    fi
    
    # Check logs for any issues
    check_spark_operator_logs
    
    log_success "Spark Operator setup completed successfully!"
    return 0
}

# Cleanup Spark Operator installation
cleanup_spark_operator() {
    log_info "Cleaning up Spark Operator..."
    
    local spark_release="spark-operator"
    local spark_namespace="spark-operator"
    
    # Uninstall Helm release
    if helm list -n "$spark_namespace" 2>/dev/null | grep -q "$spark_release"; then
        log_info " Uninstalling Spark Operator Helm release..."
        helm uninstall "$spark_release" -n "$spark_namespace"
    else
        log_info " Spark Operator release not found"
    fi
    
    # Clean up CRDs (optional - be careful as this affects cluster-wide resources)
    echo "⚠️  Cleaning up Spark Operator CRDs..."
    kubectl delete crd sparkapplications.sparkoperator.k8s.io --ignore-not-found=true
    kubectl delete crd sparkscheduledapplications.sparkoperator.k8s.io --ignore-not-found=true
    
    # Delete namespace
    log_info " Deleting Spark Operator namespace..."
    kubectl delete namespace "$spark_namespace" --ignore-not-found=true
    
    echo "✅ Spark Operator cleanup completed"
}

