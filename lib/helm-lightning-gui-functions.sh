#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Lightning GUI functions
############################################################

# Install Lightning GUI using Helm
install_lightning_gui() {
    log_info "Installing Lightning GUI..."
    
    local gui_release="lightning-gui"
    local gui_chart="helm-zetaris-lightning-gui/lightning-gui"
    local gui_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Lightning GUI is already installed
    log_info "Checking Lightning GUI release '$gui_release' in namespace '$gui_namespace'"
    
    if helm list -n "$gui_namespace" 2>/dev/null | grep -q "$gui_release"; then
        echo "✅ Lightning GUI release '$gui_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$gui_namespace" -l app=lightning-gui --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Lightning GUI pods are running"
            return 0
        else
            echo "⚠️  Lightning GUI release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$gui_namespace'"

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$gui_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$gui_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Lightning GUI..."

    # Set default values for optional parameters (for local environment)
    local tls_cert_arn=""
    
    # For local environment, AWS TLS cert ARN can be empty
    if [ "$ENVIRONMENT" = "local" ]; then
        log_info "Local environment detected - using minimal AWS configuration"
        tls_cert_arn=""
    fi

    # Debug: Display configuration being used
    log_debug "Lightning GUI configuration:"
    echo "   Environment: $ENVIRONMENT"
    echo "   GUI Image: $ZETARIS_GUI_IMAGE"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   TLS Cert ARN: ${tls_cert_arn:-empty}"
    echo ""

    if helm upgrade --install "$gui_release" "$gui_chart" \
        --namespace "$gui_namespace" \
        --set "guiImage=$ZETARIS_GUI_IMAGE" \
        --set "ingress.protocol=$DNS_PROTOCOL" \
        --set "aws.ingress.tls_cert_arn=$tls_cert_arn" \
        --set "ingress.baseDomain=$BASE_DNS_NAME" \
        --set "environment=$ENVIRONMENT" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Lightning GUI installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Lightning GUI pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=lightning-gui -n "$gui_namespace" --timeout=900s; then
            log_success "Lightning GUI is ready!"
            
            # Display Lightning GUI information
            display_lightning_gui_info
            
            return 0
        else
            echo "❌ Lightning GUI pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Lightning GUI"
        return 1
    fi
}

# Display Lightning GUI information
display_lightning_gui_info() {
    local gui_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "Lightning GUI Information:"
    echo "   Namespace: $gui_namespace"
    echo "   Environment: $ENVIRONMENT"
    echo "   GUI Image: $ZETARIS_GUI_IMAGE"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo ""
    log_info "Lightning GUI Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$gui_namespace" -l app=lightning-gui --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name="lightning-gui-svc"
    # Check if service exists
    if ! kubectl get svc "$service_name" -n "$gui_namespace" &> /dev/null; then
        service_name="N/A"
    fi
    
    if [ "$service_name" != "N/A" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$gui_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$gui_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "N/A")
        local service_type
        service_type=$(kubectl get svc "$service_name" -n "$gui_namespace" -o jsonpath='{.spec.type}' 2>/dev/null || echo "N/A")
        local node_port
        node_port=$(kubectl get svc "$service_name" -n "$gui_namespace" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
        echo "   Service Name: $service_name"
        echo "   Service Type: $service_type"
        echo "   Service IP: $service_ip"
        echo "   Service Port: $service_port"
        if [ "$service_type" = "NodePort" ] && [ "$node_port" != "N/A" ]; then
            echo "   NodePort: $node_port"
        fi
    else
        echo "   Service Name: Not found"
        echo "   Service IP: N/A"
        echo "   Service Port: N/A"
    fi
    
    # Show ingress information
    local ingress_name
    ingress_name=$(kubectl get ingress -n "$gui_namespace" | grep "lightning-gui" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$ingress_name" != "N/A" ]; then
        echo "   Ingress Name: $ingress_name"
        local ingress_host
        ingress_host=$(kubectl get ingress "$ingress_name" -n "$gui_namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
        echo "   Ingress Host: $ingress_host"
    else
        echo "   Ingress Name: Not configured"
        echo "   Ingress Host: N/A"
    fi

    echo ""
    log_info "Lightning GUI URLs:"
    if [ "$service_name" != "N/A" ]; then
        echo "   Internal: $DNS_PROTOCOL://$service_name.$gui_namespace.svc.cluster.local:$service_port"
        
        # Show NodePort access if available
        if [ "$service_type" = "NodePort" ] && [ "$node_port" != "N/A" ]; then
            local node_ips
            node_ips=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
            if [ -n "$node_ips" ]; then
                echo "   NodePort Access:"
                for node_ip in $node_ips; do
                    echo "     $DNS_PROTOCOL://$node_ip:$node_port"
                done
            fi
        fi
    fi
    
    if [ "$ingress_name" != "N/A" ] && [ "$ingress_host" != "N/A" ]; then
        echo "   External: $DNS_PROTOCOL://$ingress_host"
        echo "   External GUI: $DNS_PROTOCOL://$ingress_host"
    fi
    
    echo ""
    log_info "To test Lightning GUI:"
    echo "   kubectl exec -it \$(kubectl get pods -n $gui_namespace -l app=lightning-gui -o jsonpath='{.items[0].metadata.name}') -n $gui_namespace -- ps aux | grep -E 'nginx|httpd|node'"
    echo ""
}

# Verify Lightning GUI functionality
verify_lightning_gui() {
    log_info "Verifying Lightning GUI functionality..."
    
    local gui_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$gui_namespace" &> /dev/null; then
        echo "❌ Lightning GUI namespace '$gui_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$gui_namespace" -l app=lightning-gui --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Lightning GUI pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Lightning GUI pod(s)"
    
    # Check if Lightning GUI service exists
    local service_name="lightning-gui-svc"
    if ! kubectl get svc "$service_name" -n "$gui_namespace" &> /dev/null; then
        service_name=""
    fi
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Lightning GUI service '$service_name' is available"
        
        # Get a Lightning GUI pod
        local gui_pod
        gui_pod=$(kubectl get pods -n "$gui_namespace" -l app=lightning-gui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$gui_pod" ]; then
            log_info "Lightning GUI pod '$gui_pod' is available"
            echo "✅ Lightning GUI is ready and accessible"
            return 0
        else
            echo "❌ No Lightning GUI pods found"
            return 1
        fi
    else
        echo "❌ Lightning GUI service not found"
        return 1
    fi
}

# Check Lightning GUI logs for any issues
check_lightning_gui_logs() {
    log_info "Checking Lightning GUI logs for issues..."
    
    local gui_namespace=${ZETARIS_NS:-zetaris}
    local gui_pods
    gui_pods=$(kubectl get pods -n "$gui_namespace" -l app=lightning-gui -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$gui_pods" ]; then
        echo "❌ No Lightning GUI pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Lightning GUI pod
    for pod in $gui_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$gui_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
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
        log_info "To view full logs: kubectl logs -l app=lightning-gui -n $gui_namespace"
        return 1
    else
        echo "✅ No errors found in Lightning GUI logs"
        return 0
    fi
}

# Test Lightning GUI basic functionality
test_lightning_gui() {
    log_info "Testing Lightning GUI basic functionality..."
    
    local gui_namespace=${ZETARIS_NS:-zetaris}
    local gui_pod
    gui_pod=$(kubectl get pods -n "$gui_namespace" -l app=lightning-gui -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$gui_pod" ]; then
        echo "❌ No Lightning GUI pods found"
        return 1
    fi
    
    # Check if web server process is running inside the pod (nginx, httpd, or node)
    log_info "Checking if Lightning GUI web server process is running..."
    if kubectl exec -n "$gui_namespace" "$gui_pod" -- pgrep -f "lightning-gui" &>/dev/null; then
        echo "✅ Lightning GUI web server process is running"
        
        # Check if typical web server ports are listening
        log_info "Checking if Lightning GUI ports are listening..."
        local gui_port
        gui_port=$(kubectl get svc lightning-gui-svc -n "$gui_namespace" -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null || echo "9001")
        
        # Ensure gui_port is a valid number
        if ! [[ "$gui_port" =~ ^[0-9]+$ ]]; then
            gui_port=9001
        fi
        
        # Use netstat to check if port is listening
        if kubectl exec -n "$gui_namespace" "$gui_pod" -- netstat -tunl 2>/dev/null | grep -q ":$gui_port "; then
            echo "✅ Lightning GUI is listening on port $gui_port"
            return 0
        else
            echo "⚠️  Lightning GUI port $gui_port is not listening yet"
            return 1
        fi
    else
        echo "⚠️  Lightning GUI web server process is not running"
        return 1
    fi
}

# Main function to setup Lightning GUI completely
setup_lightning_gui() {
    log_info "Setting up Lightning GUI for Zetaris..."
    
    # Install Lightning GUI
    if ! install_lightning_gui; then
        echo "❌ Failed to install Lightning GUI"
        return 1
    fi
    
    # Wait a moment for Lightning GUI to initialize
    log_info "Waiting for Lightning GUI to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_lightning_gui; then
        echo "❌ Lightning GUI verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_lightning_gui_logs; then
        echo "⚠️  Found issues in Lightning GUI logs, but continuing..."
    fi
    
    # Test Lightning GUI functionality
    if ! test_lightning_gui; then
        echo "⚠️  Lightning GUI functionality test failed, but continuing..."
    fi
    
    log_success "Lightning GUI setup completed successfully!"
    return 0
}

# Cleanup Lightning GUI installation
cleanup_lightning_gui() {
    log_info "Cleaning up Lightning GUI..."
    
    local gui_release="lightning-gui"
    local gui_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$gui_namespace" 2>/dev/null | grep -q "$gui_release"; then
        log_info "Uninstalling Lightning GUI Helm release..."
        helm uninstall "$gui_release" -n "$gui_namespace"
    else
        log_info "Lightning GUI release not found"
    fi
    
    # Clean up any remaining secrets
    log_info "Cleaning up Lightning GUI secrets..."
    kubectl delete secret -n "$gui_namespace" -l app=lightning-gui --ignore-not-found=true
    
    # Clean up any ingress
    log_info "Cleaning up Lightning GUI ingress..."
    kubectl delete ingress -n "$gui_namespace" -l app=lightning-gui --ignore-not-found=true
    
    echo "✅ Lightning GUI cleanup completed"
}