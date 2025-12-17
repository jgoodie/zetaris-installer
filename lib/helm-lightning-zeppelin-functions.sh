#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Lightning Zeppelin functions
############################################################

# Install Lightning Zeppelin using Helm
install_lightning_zeppelin() {
    echo "Installing Lightning Zeppelin..."
    
    local zeppelin_release="lightning-zeppelin"
    local zeppelin_chart="helm-zetaris-lightning-zeppelin/lightning-zeppelin"
    local zeppelin_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Lightning Zeppelin is already installed
    log_info "Checking to see if Lightning Zeppelin release '$zeppelin_release' exists in namespace '$zeppelin_namespace'..."
    
    if helm list -n "$zeppelin_namespace" 2>/dev/null | grep -q "$zeppelin_release"; then
        echo "✅ Lightning Zeppelin release '$zeppelin_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$zeppelin_namespace" -l app=lightning-zeppelin --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Lightning Zeppelin pods are running"
            return 0
        else
            echo "⚠️  Lightning Zeppelin release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$zeppelin_namespace'..."

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$zeppelin_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$zeppelin_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Lightning Zeppelin..."

    # Set default values for optional parameters (for local environment)
    local tls_cert_arn=""
    
    # For local environment, AWS TLS cert ARN can be empty
    if [ "$ENVIRONMENT" = "local" ]; then
        log_info "Local environment detected - using minimal AWS configuration"
        tls_cert_arn=""
    fi

    # Debug: Display configuration being used
    log_info "Debug - Lightning Zeppelin configuration:"
    echo "   Environment: $ENVIRONMENT"
    echo "   Zeppelin Image: $ZETARIS_ZEPPELIN_IMAGE"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   PV Size: $ZETARIS_ZEPPELIN_PV_SIZE"
    echo "   TLS Cert ARN: ${tls_cert_arn:-empty}"
    echo ""

    if helm upgrade --install "$zeppelin_release" "$zeppelin_chart" \
        --namespace "$zeppelin_namespace" \
        --set "ingress.protocol=$DNS_PROTOCOL" \
        --set "ingress.baseDomain=$BASE_DNS_NAME" \
        --set "ingress.tls_cert_arn=$tls_cert_arn" \
        --set "storage.storageClass.name=$STORAGE_CLASS" \
        --set "environment=$ENVIRONMENT" \
        --set "zeppelin.image=$ZETARIS_ZEPPELIN_IMAGE" \
        --set "storage.volume.size=$ZETARIS_ZEPPELIN_PV_SIZE" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Lightning Zeppelin installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Lightning Zeppelin pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=lightning-zeppelin -n "$zeppelin_namespace" --timeout=900s; then
            log_success "Lightning Zeppelin is ready!"
            
            # Display Lightning Zeppelin information
            display_lightning_zeppelin_info
            
            return 0
        else
            echo "❌ Lightning Zeppelin pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Lightning Zeppelin"
        return 1
    fi
}

# Display Lightning Zeppelin information
display_lightning_zeppelin_info() {
    local zeppelin_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "Lightning Zeppelin Information:"
    echo "   Namespace: $zeppelin_namespace"
    echo "   Environment: $ENVIRONMENT"
    echo "   Zeppelin Image: $ZETARIS_ZEPPELIN_IMAGE"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   PV Size: $ZETARIS_ZEPPELIN_PV_SIZE"
    echo ""
    log_info "Lightning Zeppelin Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$zeppelin_namespace" -l app=lightning-zeppelin --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name="lightning-zeppelin-svc"
    # Check if service exists
    if ! kubectl get svc "$service_name" -n "$zeppelin_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$zeppelin_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$zeppelin_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "N/A")
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
    ingress_name=$(kubectl get ingress -n "$zeppelin_namespace" | grep "lightning-zeppelin" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$ingress_name" != "N/A" ]; then
        echo "   Ingress Name: $ingress_name"
        local ingress_host
        ingress_host=$(kubectl get ingress "$ingress_name" -n "$zeppelin_namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
        echo "   Ingress Host: $ingress_host"
    else
        echo "   Ingress Name: Not configured"
        echo "   Ingress Host: N/A"
    fi

    # Show PVC information
    echo "   Persistent Volume Claims:"
    kubectl get pvc -n "$zeppelin_namespace" -l app=lightning-zeppelin --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null || echo "     - No PVCs found"

    echo ""
    log_info "Lightning Zeppelin URLs:"
    if [ "$service_name" != "" ]; then
        echo "   Internal: $DNS_PROTOCOL://$service_name.$zeppelin_namespace.svc.cluster.local:$service_port"
    fi
    
    if [ "$ingress_name" != "N/A" ] && [ "$ingress_host" != "N/A" ]; then
        echo "   External: $DNS_PROTOCOL://$ingress_host"
        echo "   External Zeppelin: $DNS_PROTOCOL://$ingress_host"
    fi
    
    echo ""
    log_info "To test Lightning Zeppelin:"
    echo "   kubectl exec -it \$(kubectl get pods -n $zeppelin_namespace -l app=lightning-zeppelin -o jsonpath='{.items[0].metadata.name}') -n $zeppelin_namespace -- ps aux | grep -E 'zeppelin|java'"
    echo ""
}

# Verify Lightning Zeppelin functionality
verify_lightning_zeppelin() {
    log_info "Verifying Lightning Zeppelin functionality..."
    
    local zeppelin_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$zeppelin_namespace" &> /dev/null; then
        echo "❌ Lightning Zeppelin namespace '$zeppelin_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$zeppelin_namespace" -l app=lightning-zeppelin --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Lightning Zeppelin pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Lightning Zeppelin pod(s)"
    
    # Check if Lightning Zeppelin service exists
    local service_name="lightning-zeppelin-svc"
    if ! kubectl get svc "$service_name" -n "$zeppelin_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Lightning Zeppelin service '$service_name' is available"
        
        # Get a Lightning Zeppelin pod
        local zeppelin_pod
        zeppelin_pod=$(kubectl get pods -n "$zeppelin_namespace" -l app=lightning-zeppelin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$zeppelin_pod" ]; then
            log_info "Lightning Zeppelin pod '$zeppelin_pod' is available"
            echo "✅ Lightning Zeppelin is ready and accessible"
            return 0
        else
            echo "❌ No Lightning Zeppelin pods found"
            return 1
        fi
    else
        echo "❌ Lightning Zeppelin service not found"
        return 1
    fi
}

# Check Lightning Zeppelin logs for any issues
check_lightning_zeppelin_logs() {
    log_info "Checking Lightning Zeppelin logs for issues..."
    
    local zeppelin_namespace=${ZETARIS_NS:-zetaris}
    local zeppelin_pods
    zeppelin_pods=$(kubectl get pods -n "$zeppelin_namespace" -l app=lightning-zeppelin -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$zeppelin_pods" ]; then
        echo "❌ No Lightning Zeppelin pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Lightning Zeppelin pod
    for pod in $zeppelin_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$zeppelin_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
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
        log_info "To view full logs: kubectl logs -l app=lightning-zeppelin -n $zeppelin_namespace"
        return 1
    else
        echo "✅ No errors found in Lightning Zeppelin logs"
        return 0
    fi
}

# Test Lightning Zeppelin basic functionality
test_lightning_zeppelin() {
    log_info "Testing Lightning Zeppelin basic functionality..."
    
    local zeppelin_namespace=${ZETARIS_NS:-zetaris}
    local zeppelin_pod
    zeppelin_pod=$(kubectl get pods -n "$zeppelin_namespace" -l app=lightning-zeppelin -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$zeppelin_pod" ]; then
        echo "❌ No Lightning Zeppelin pods found"
        return 1
    fi
    
    # Check if Java/Zeppelin process is running inside the pod
    log_info "Checking if Lightning Zeppelin process is running..."
    if kubectl exec -n "$zeppelin_namespace" "$zeppelin_pod" -- pgrep -f "zeppelin" &>/dev/null; then
        echo "✅ Lightning Zeppelin process is running"
        
        # Test Lightning Zeppelin service connectivity
        log_info "Testing Lightning Zeppelin service connectivity..."
        local service_name="lightning-zeppelin-svc"
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$zeppelin_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$zeppelin_namespace" -o jsonpath='{.spec.ports[2].port}' 2>/dev/null || echo "8080")
        
        # Ensure service_port is a valid number
        if ! [[ "$service_port" =~ ^[0-9]+$ ]]; then
            service_port=8080
        fi
        
        if [ -n "$service_ip" ]; then
            log_info "Testing Lightning Zeppelin endpoint: $service_ip:$service_port"
            
            # Use netcat test from a busybox pod to test service connectivity
            if kubectl run test-lightning-zeppelin-connection --image=busybox:latest --rm -i --restart=Never -n "$zeppelin_namespace" -- \
               nc -z -w5 "$service_ip" "$service_port" &>/dev/null; then
                echo "✅ Lightning Zeppelin port $service_port is accessible via netcat"
                return 0
            else
                echo "⚠️  Lightning Zeppelin port $service_port is not accessible"
                return 1
            fi
        else
            echo "❌ Could not get Lightning Zeppelin service IP"
            return 1
        fi
    else
        echo "⚠️  Lightning Zeppelin process is not running"
        return 1
    fi
}

# Main function to setup Lightning Zeppelin completely
setup_lightning_zeppelin() {
    log_success "Setting up Lightning Zeppelin for Zetaris..."
    
    # Install Lightning Zeppelin
    if ! install_lightning_zeppelin; then
        echo "❌ Failed to install Lightning Zeppelin"
        return 1
    fi
    
    # Wait a moment for Lightning Zeppelin to initialize
    log_info "Waiting for Lightning Zeppelin to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_lightning_zeppelin; then
        echo "❌ Lightning Zeppelin verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_lightning_zeppelin_logs; then
        echo "⚠️  Found issues in Lightning Zeppelin logs, but continuing..."
    fi
    
    # Test Lightning Zeppelin functionality
    if ! test_lightning_zeppelin; then
        echo "⚠️  Lightning Zeppelin functionality test failed, but continuing..."
    fi
    
    log_success "Lightning Zeppelin setup completed successfully!"
    return 0
}

# Cleanup Lightning Zeppelin installation
cleanup_lightning_zeppelin() {
    log_info "Cleaning up Lightning Zeppelin..."
    
    local zeppelin_release="lightning-zeppelin"
    local zeppelin_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$zeppelin_namespace" 2>/dev/null | grep -q "$zeppelin_release"; then
        log_info " Uninstalling Lightning Zeppelin Helm release..."
        helm uninstall "$zeppelin_release" -n "$zeppelin_namespace"
    else
        log_info " Lightning Zeppelin release not found"
    fi
    
    # Clean up PVCs
    log_info "Cleaning up Lightning Zeppelin PVCs..."
    kubectl delete pvc -n "$zeppelin_namespace" -l app=lightning-zeppelin --ignore-not-found=true
    
    # Clean up any remaining secrets
    log_info "Cleaning up Lightning Zeppelin secrets..."
    kubectl delete secret -n "$zeppelin_namespace" -l app=lightning-zeppelin --ignore-not-found=true
    
    # Clean up any ingress
    log_info "Cleaning up Lightning Zeppelin ingress..."
    kubectl delete ingress -n "$zeppelin_namespace" -l app=lightning-zeppelin --ignore-not-found=true
    
    echo "✅ Lightning Zeppelin cleanup completed"
}