#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Digiavatar functions
############################################################

# Install Digiavatar using Helm
install_digiavatar() {
    echo "Installing Digiavatar..."
    
    local digiavatar_release="digiavatar"
    local digiavatar_chart="helm-zetaris-digiavatar/digiavatar"
    local digiavatar_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Digiavatar is already installed
    log_info "Checking to see if Digiavatar release '$digiavatar_release' exists in namespace '$digiavatar_namespace'..."
    
    if helm list -n "$digiavatar_namespace" 2>/dev/null | grep -q "$digiavatar_release"; then
        echo "✅ Digiavatar release '$digiavatar_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$digiavatar_namespace" -l app=digiavatar --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Digiavatar pods are running"
            return 0
        else
            echo "⚠️  Digiavatar release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$digiavatar_namespace'..."

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$digiavatar_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$digiavatar_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Digiavatar..."

    # Debug: Display configuration being used
    log_info "Debug - Digiavatar configuration:"
    echo "   Environment: $ENVIRONMENT"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Service Account: zetaris-sa"
    echo ""

    if helm upgrade --install "$digiavatar_release" "$digiavatar_chart" \
        --namespace "$digiavatar_namespace" \
        --set "ingressprotocol=$DNS_PROTOCOL" \
        --set "ingress.baseDomain=$BASE_DNS_NAME" \
        --set "environment=$ENVIRONMENT" \
        --set "serviceaccount=zetaris-sa" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Digiavatar installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Digiavatar pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=digiavatar -n "$digiavatar_namespace" --timeout=900s; then
            log_success "Digiavatar is ready!"
            
            # Display Digiavatar information
            display_digiavatar_info
            
            return 0
        else
            echo "❌ Digiavatar pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Digiavatar"
        return 1
    fi
}

# Display Digiavatar information
display_digiavatar_info() {
    local digiavatar_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "Digiavatar Information:"
    echo "   Namespace: $digiavatar_namespace"
    echo "   Environment: $ENVIRONMENT"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Service Account: zetaris-sa"
    echo ""
    log_info "Digiavatar Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$digiavatar_namespace" -l app=digiavatar --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name="digiavatar-svc"
    # Check if service exists
    if ! kubectl get svc "$service_name" -n "$digiavatar_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$digiavatar_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$digiavatar_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "N/A")
        echo "   Service Name: $service_name"
        echo "   Service IP: $service_ip"
        echo "   Service Port: $service_port"
    else
        echo "   Service Name: Not found"
        echo "   Service IP: N/A"
        echo "   Service Port: N/A"
    fi
    
    # Show ingress information
    local ingress_name
    ingress_name=$(kubectl get ingress -n "$digiavatar_namespace" | grep "digiavatar" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$ingress_name" != "N/A" ]; then
        echo "   Ingress Name: $ingress_name"
        local ingress_host
        ingress_host=$(kubectl get ingress "$ingress_name" -n "$digiavatar_namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
        echo "   Ingress Host: $ingress_host"
    else
        echo "   Ingress Name: Not configured"
        echo "   Ingress Host: N/A"
    fi

    echo ""
    log_info "Digiavatar URLs:"
    if [ "$service_name" != "" ]; then
        echo "   Internal: $DNS_PROTOCOL://$service_name.$digiavatar_namespace.svc.cluster.local:$service_port"
    fi
    
    if [ "$ingress_name" != "N/A" ] && [ "$ingress_host" != "N/A" ]; then
        echo "   External: $DNS_PROTOCOL://$ingress_host"
        echo "   External Digiavatar: $DNS_PROTOCOL://$ingress_host"
    fi
    
    echo ""
    log_info "To test Digiavatar:"
    echo "   kubectl exec -it \$(kubectl get pods -n $digiavatar_namespace -l app=digiavatar -o jsonpath='{.items[0].metadata.name}') -n $digiavatar_namespace -- ps aux | grep -E 'digiavatar|java|python'"
    echo ""
}

# Verify Digiavatar functionality
verify_digiavatar() {
    log_info "Verifying Digiavatar functionality..."
    
    local digiavatar_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$digiavatar_namespace" &> /dev/null; then
        echo "❌ Digiavatar namespace '$digiavatar_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$digiavatar_namespace" -l app=digiavatar --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Digiavatar pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Digiavatar pod(s)"
    
    # Check if Digiavatar service exists
    local service_name="digiavatar-svc"
    if ! kubectl get svc "$service_name" -n "$digiavatar_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Digiavatar service '$service_name' is available"
        
        # Get a Digiavatar pod
        local digiavatar_pod
        digiavatar_pod=$(kubectl get pods -n "$digiavatar_namespace" -l app=digiavatar -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$digiavatar_pod" ]; then
            log_info "Digiavatar pod '$digiavatar_pod' is available"
            echo "✅ Digiavatar is ready and accessible"
            return 0
        else
            echo "❌ No Digiavatar pods found"
            return 1
        fi
    else
        echo "❌ Digiavatar service not found"
        return 1
    fi
}

# Check Digiavatar logs for any issues
check_digiavatar_logs() {
    log_info "Checking Digiavatar logs for issues..."
    
    local digiavatar_namespace=${ZETARIS_NS:-zetaris}
    local digiavatar_pods
    digiavatar_pods=$(kubectl get pods -n "$digiavatar_namespace" -l app=digiavatar -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$digiavatar_pods" ]; then
        echo "❌ No Digiavatar pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Digiavatar pod
    for pod in $digiavatar_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$digiavatar_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
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
        log_info "To view full logs: kubectl logs -l app=digiavatar -n $digiavatar_namespace"
        return 1
    else
        echo "✅ No errors found in Digiavatar logs"
        return 0
    fi
}

# Test Digiavatar basic functionality
test_digiavatar() {
    log_info "Testing Digiavatar basic functionality..."
    
    local digiavatar_namespace=${ZETARIS_NS:-zetaris}
    local digiavatar_pod
    digiavatar_pod=$(kubectl get pods -n "$digiavatar_namespace" -l app=digiavatar -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$digiavatar_pod" ]; then
        echo "❌ No Digiavatar pods found"
        return 1
    fi
    
    # Check if Digiavatar process is running inside the pod
    log_info "Checking if Digiavatar process is running..."
    if kubectl exec -n "$digiavatar_namespace" "$digiavatar_pod" -- pgrep -f "node|serve" &>/dev/null; then
        echo "✅ Digiavatar process is running"
        
        # Test Digiavatar service connectivity
        log_info "Testing Digiavatar service connectivity..."
        local service_name="digiavatar-svc"
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$digiavatar_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$digiavatar_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "80")
        
        # Ensure service_port is a valid number
        if ! [[ "$service_port" =~ ^[0-9]+$ ]]; then
            service_port=80
        fi
        
        if [ -n "$service_ip" ]; then
            log_info "Testing Digiavatar endpoint: $service_ip:$service_port"
            
            # Use netcat test from a busybox pod to test service connectivity
            if kubectl run test-digiavatar-connection --image=busybox:latest --rm -i --restart=Never -n "$digiavatar_namespace" -- \
               nc -z -w5 "$service_ip" "$service_port" &>/dev/null; then
                echo "✅ Digiavatar port $service_port is accessible via netcat"
                return 0
            else
                echo "⚠️  Digiavatar port $service_port is not accessible"
                return 1
            fi
        else
            echo "❌ Could not get Digiavatar service IP"
            return 1
        fi
    else
        echo "⚠️  Digiavatar process is not running"
        return 1
    fi
}

# Main function to setup Digiavatar completely
setup_digiavatar() {
    log_success "Setting up Digiavatar for Zetaris..."
    
    # Install Digiavatar
    if ! install_digiavatar; then
        echo "❌ Failed to install Digiavatar"
        return 1
    fi
    
    # Wait a moment for Digiavatar to initialize
    log_info "Waiting for Digiavatar to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_digiavatar; then
        echo "❌ Digiavatar verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_digiavatar_logs; then
        echo "⚠️  Found issues in Digiavatar logs, but continuing..."
    fi
    
    # Test Digiavatar functionality
    if ! test_digiavatar; then
        echo "⚠️  Digiavatar functionality test failed, but continuing..."
    fi
    
    log_success "Digiavatar setup completed successfully!"
    return 0
}

# Cleanup Digiavatar installation
cleanup_digiavatar() {
    log_info "Cleaning up Digiavatar..."
    
    local digiavatar_release="digiavatar"
    local digiavatar_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$digiavatar_namespace" 2>/dev/null | grep -q "$digiavatar_release"; then
        log_info " Uninstalling Digiavatar Helm release..."
        helm uninstall "$digiavatar_release" -n "$digiavatar_namespace"
    else
        log_info " Digiavatar release not found"
    fi
    
    # Clean up any remaining secrets
    log_info "Cleaning up Digiavatar secrets..."
    kubectl delete secret -n "$digiavatar_namespace" -l app=digiavatar --ignore-not-found=true
    
    # Clean up any ingress
    log_info "Cleaning up Digiavatar ingress..."
    kubectl delete ingress -n "$digiavatar_namespace" -l app=digiavatar --ignore-not-found=true
    
    echo "✅ Digiavatar cleanup completed"
}