#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Airflow functions
############################################################

# Install Airflow using Helm
install_airflow() {
    echo "Installing Airflow..."
    
    local airflow_release="airflow-ing"
    local airflow_chart="helm-zetaris-airflow-ing/airflow-ing"
    local airflow_namespace="airflow"
    
    # Check if Airflow is already installed
    log_info "Checking to see if Airflow release '$airflow_release' exists in namespace '$airflow_namespace'..."
    
    if helm list -n "$airflow_namespace" 2>/dev/null | grep -q "$airflow_release"; then
        echo "✅ Airflow release '$airflow_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$airflow_namespace" -l app.kubernetes.io/name=airflow --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Airflow pods are running"
            return 0
        else
            echo "⚠️  Airflow release exists but no pods found. Upgrading..."
        fi
    fi

    # Ensure namespace exists
    log_info "Verifying namespace '$airflow_namespace'..."
    if ! kubectl get namespace "$airflow_namespace" &> /dev/null; then
        log_info "Creating namespace '$airflow_namespace'..."
        kubectl create namespace "$airflow_namespace"
    fi

    log_info "Installing/upgrading Airflow..."

    # Debug: Display configuration being used
    log_info "Debug - Airflow configuration:"
    echo "   Environment: $ENVIRONMENT"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   Deployment Name: $DEPLOYMENT_NAME"
    echo "   DNS Domain: $DNS_DOMAIN"
    echo ""

    if helm upgrade --install "$airflow_release" "$airflow_chart" \
        --namespace "$airflow_namespace" \
        --set "environment=$ENVIRONMENT" \
        --set "storage.storageClass.name=$STORAGE_CLASS" \
        --set "deploymentname=$DEPLOYMENT_NAME" \
        --set "dnsdomain=$DNS_DOMAIN" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Airflow installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Airflow pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=airflow -n "$airflow_namespace" --timeout=900s; then
            log_success "Airflow is ready!"
            
            # Display Airflow information
            display_airflow_info
            
            return 0
        else
            echo "❌ Airflow pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Airflow"
        return 1
    fi
}

# Display Airflow information
display_airflow_info() {
    local airflow_namespace="airflow"
    
    echo ""
    log_info "Airflow Information:"
    echo "   Namespace: $airflow_namespace"
    echo "   Environment: $ENVIRONMENT"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   Deployment Name: $DEPLOYMENT_NAME"
    echo "   DNS Domain: $DNS_DOMAIN"
    echo ""
    log_info "Airflow Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$airflow_namespace" -l app.kubernetes.io/name=airflow --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name
    service_name=$(kubectl get svc -n "$airflow_namespace" | grep "airflow" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$service_name" != "N/A" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$airflow_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$airflow_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "N/A")
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
    ingress_name=$(kubectl get ingress -n "$airflow_namespace" | grep "airflow" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$ingress_name" != "N/A" ]; then
        echo "   Ingress Name: $ingress_name"
        local ingress_host
        ingress_host=$(kubectl get ingress "$ingress_name" -n "$airflow_namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
        echo "   Ingress Host: $ingress_host"
    else
        echo "   Ingress Name: Not configured"
        echo "   Ingress Host: N/A"
    fi

    # Show PVC information
    echo "   Persistent Volume Claims:"
    kubectl get pvc -n "$airflow_namespace" --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null || echo "     - No PVCs found"

    echo ""
    log_info "Airflow URLs:"
    if [ "$service_name" != "N/A" ]; then
        echo "   Internal: http://$service_name.$airflow_namespace.svc.cluster.local:$service_port"
    fi
    
    if [ "$ingress_name" != "N/A" ] && [ "$ingress_host" != "N/A" ]; then
        echo "   External: http://$ingress_host"
        echo "   Airflow UI: http://$ingress_host"
    fi
    
    echo ""
    log_info "To access Airflow:"
    echo "   kubectl get pods -n $airflow_namespace"
    echo "   kubectl logs -f <airflow-pod-name> -n $airflow_namespace"
    echo ""
}

# Verify Airflow functionality
verify_airflow() {
    log_info "Verifying Airflow functionality..."
    
    local airflow_namespace="airflow"
    
    # Check if namespace exists
    if ! kubectl get namespace "$airflow_namespace" &> /dev/null; then
        echo "❌ Airflow namespace '$airflow_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$airflow_namespace" -l app.kubernetes.io/name=airflow --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Airflow pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Airflow pod(s)"
    
    # Check if Airflow service exists
    local service_name
    service_name=$(kubectl get svc -n "$airflow_namespace" | grep "airflow" | awk '{print $1}' | head -1 2>/dev/null || echo "")
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Airflow service '$service_name' is available"
        
        # Get an Airflow pod for health check
        local airflow_pod
        airflow_pod=$(kubectl get pods -n "$airflow_namespace" -l app.kubernetes.io/name=airflow -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        
        if [ -n "$airflow_pod" ]; then
            echo "✅ Found Airflow pod: $airflow_pod"
            
            # Basic connectivity test
            log_info "Testing Airflow pod connectivity..."
            if kubectl exec -n "$airflow_namespace" "$airflow_pod" -- echo "Connection test successful" &> /dev/null; then
                echo "✅ Airflow pod is responsive"
                return 0
            else
                echo "⚠️  Airflow pod connectivity test failed"
                return 1
            fi
        else
            echo "❌ Could not find Airflow pod for testing"
            return 1
        fi
    else
        echo "❌ Airflow service not found"
        return 1
    fi
}

# Main setup function for Airflow
setup_airflow() {
    log_success "Setting up Airflow..."
    
    # Install Airflow
    if ! install_airflow; then
        echo "❌ Failed to install Airflow"
        return 1
    fi
    
    # Verify installation
    if ! verify_airflow; then
        echo "⚠️  Airflow verification failed, but installation completed"
        log_info "You may need to check the Airflow logs manually"
        return 0  # Don't fail the entire process
    fi
    
    log_success "Airflow setup completed successfully!"
    return 0
}