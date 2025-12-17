#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Private AI functions
############################################################

# Install Private AI using Helm
install_private_ai() {
    log_info "Installing Private AI..."
    
    local privateai_release="privateai"
    local privateai_chart="helm-zetaris-privateai/privateai"
    local privateai_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Private AI is already installed
    log_info "Checking to see if Private AI release '$privateai_release' exists in namespace '$privateai_namespace'..."
    
    if helm list -n "$privateai_namespace" 2>/dev/null | grep -q "$privateai_release"; then
        echo "✅ Private AI release '$privateai_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$privateai_namespace" -l app=privateai --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Private AI pods are running"
            return 0
        else
            echo "⚠️  Private AI release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$privateai_namespace'..."

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$privateai_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$privateai_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Private AI..."

    # Debug: Display configuration being used
    log_info "Debug - Private AI configuration:"
    echo "   Environment: $ENVIRONMENT"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   Service Account: zetaris-sa"
    echo "   GPU Enabled: false"
    echo ""

    if helm upgrade --install "$privateai_release" "$privateai_chart" \
        --namespace "$privateai_namespace" \
        --set "ingress.baseDomain=$BASE_DNS_NAME" \
        --set "ingressprotocol=$DNS_PROTOCOL" \
        --set "environment=$ENVIRONMENT" \
        --set "gpuenabled=$PRIVATE_AI_GPU" \
        --set "storageclass=$STORAGE_CLASS" \
        --set "serviceaccount.name=zetaris-sa" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Private AI installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Private AI pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=privateai -n "$privateai_namespace" --timeout=900s; then
            log_success "Private AI is ready!"
            
            # Display Private AI information
            display_private_ai_info
            
            return 0
        else
            echo "❌ Private AI pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Private AI"
        return 1
    fi
}

# Display Private AI information
display_private_ai_info() {
    local privateai_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "Private AI Information:"
    echo "   Namespace: $privateai_namespace"
    echo "   Environment: $ENVIRONMENT"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   Service Account: zetaris-sa"
    echo "   GPU Enabled: false"
    echo ""
    log_info "Private AI Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$privateai_namespace" -l app=privateai --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name="privateai-svc"
    # Check if service exists
    if ! kubectl get svc "$service_name" -n "$privateai_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$privateai_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$privateai_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "N/A")
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
    ingress_name=$(kubectl get ingress -n "$privateai_namespace" | grep "privateai" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$ingress_name" != "N/A" ]; then
        echo "   Ingress Name: $ingress_name"
        local ingress_host
        ingress_host=$(kubectl get ingress "$ingress_name" -n "$privateai_namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
        echo "   Ingress Host: $ingress_host"
    else
        echo "   Ingress Name: Not configured"
        echo "   Ingress Host: N/A"
    fi

    # Show PVC information (Private AI might have storage needs)
    echo "   Persistent Volume Claims:"
    kubectl get pvc -n "$privateai_namespace" -l app=privateai --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null || echo "     - No PVCs found"

    echo ""
    log_info "Private AI URLs:"
    if [ "$service_name" != "" ]; then
        echo "   Internal: $DNS_PROTOCOL://$service_name.$privateai_namespace.svc.cluster.local:$service_port"
    fi
    
    if [ "$ingress_name" != "N/A" ] && [ "$ingress_host" != "N/A" ]; then
        echo "   External: $DNS_PROTOCOL://$ingress_host"
        echo "   External Private AI: $DNS_PROTOCOL://$ingress_host"
    fi
    
    echo ""
    log_info "To test Private AI:"
    echo "   kubectl exec -it \$(kubectl get pods -n $privateai_namespace -l app=privateai -o jsonpath='{.items[0].metadata.name}') -n $privateai_namespace -- ps aux | grep -E 'privateai|python|java'"
    echo ""
}

# Verify Private AI functionality
verify_private_ai() {
    log_info "Verifying Private AI functionality..."
    
    local privateai_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$privateai_namespace" &> /dev/null; then
        echo "❌ Private AI namespace '$privateai_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$privateai_namespace" -l app=privateai --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Private AI pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Private AI pod(s)"
    
    # Check if Private AI service exists
    local service_name="privateai-svc"
    if ! kubectl get svc "$service_name" -n "$privateai_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Private AI service '$service_name' is available"
        
        # Get a Private AI pod
        local privateai_pod
        privateai_pod=$(kubectl get pods -n "$privateai_namespace" -l app=privateai -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$privateai_pod" ]; then
            log_info "Private AI pod '$privateai_pod' is available"
            echo "✅ Private AI is ready and accessible"
            return 0
        else
            echo "❌ No Private AI pods found"
            return 1
        fi
    else
        echo "❌ Private AI service not found"
        return 1
    fi
}

# Check Private AI logs for any issues
check_private_ai_logs() {
    log_info "Checking Private AI logs for issues..."
    
    local privateai_namespace=${ZETARIS_NS:-zetaris}
    local privateai_pods
    privateai_pods=$(kubectl get pods -n "$privateai_namespace" -l app=privateai -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$privateai_pods" ]; then
        echo "❌ No Private AI pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Private AI pod
    for pod in $privateai_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$privateai_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
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
        log_info "To view full logs: kubectl logs -l app=privateai -n $privateai_namespace"
        return 1
    else
        echo "✅ No errors found in Private AI logs"
        return 0
    fi
}

# Test Private AI basic functionality
test_private_ai() {
    log_info "Testing Private AI basic functionality..."
    
    local privateai_namespace=${ZETARIS_NS:-zetaris}
    local privateai_pod
    privateai_pod=$(kubectl get pods -n "$privateai_namespace" -l app=privateai -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$privateai_pod" ]; then
        echo "❌ No Private AI pods found"
        return 1
    fi
    
    # Check if Private AI process is running inside the pod
    log_info "Checking if Private AI process is running..."
    if kubectl exec -n "$privateai_namespace" "$privateai_pod" -- pgrep -f "flask" &>/dev/null; then
        echo "✅ Private AI process is running"
        
        # Test Private AI service connectivity
        log_info "Testing Private AI service connectivity..."
        local service_name="privateai-svc"
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$privateai_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$privateai_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "3001")
        
        # Ensure service_port is a valid number
        if ! [[ "$service_port" =~ ^[0-9]+$ ]]; then
            service_port=3001
        fi
        
        if [ -n "$service_ip" ]; then
            log_info "Testing Private AI endpoint: $service_ip:$service_port"
            
            # Use netcat test from a busybox pod to test service connectivity
            if kubectl run test-privateai-connection --image=busybox:latest --rm -i --restart=Never -n "$privateai_namespace" -- \
               nc -z -w5 "$service_ip" "$service_port" &>/dev/null; then
                echo "✅ Private AI port $service_port is accessible via netcat"
                return 0
            else
                echo "⚠️  Private AI port $service_port is not accessible"
                return 1
            fi
        else
            echo "❌ Could not get Private AI service IP"
            return 1
        fi
    else
        echo "⚠️  Private AI process is not running"
        return 1
    fi
}

# Main function to setup Private AI completely
setup_private_ai() {
    log_success "Setting up Private AI for Zetaris..."
    
    # Install Private AI
    if ! install_private_ai; then
        echo "❌ Failed to install Private AI"
        return 1
    fi
    
    # Wait a moment for Private AI to initialize
    log_info "Waiting for Private AI to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_private_ai; then
        echo "❌ Private AI verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_private_ai_logs; then
        echo "⚠️  Found issues in Private AI logs, but continuing..."
    fi
    
    # Test Private AI functionality
    if ! test_private_ai; then
        echo "⚠️  Private AI functionality test failed, but continuing..."
    fi
    
    log_success "Private AI setup completed successfully!"
    return 0
}

# Cleanup Private AI installation
cleanup_private_ai() {
    log_info "Cleaning up Private AI..."
    
    local privateai_release="privateai"
    local privateai_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$privateai_namespace" 2>/dev/null | grep -q "$privateai_release"; then
        log_info " Uninstalling Private AI Helm release..."
        helm uninstall "$privateai_release" -n "$privateai_namespace"
    else
        log_info " Private AI release not found"
    fi
    
    # Clean up PVCs
    log_info "Cleaning up Private AI PVCs..."
    kubectl delete pvc -n "$privateai_namespace" -l app=privateai --ignore-not-found=true
    
    # Clean up any remaining secrets
    log_info "Cleaning up Private AI secrets..."
    kubectl delete secret -n "$privateai_namespace" -l app=privateai --ignore-not-found=true
    
    # Clean up any ingress
    log_info "Cleaning up Private AI ingress..."
    kubectl delete ingress -n "$privateai_namespace" -l app=privateai --ignore-not-found=true
    
    echo "✅ Private AI cleanup completed"
}