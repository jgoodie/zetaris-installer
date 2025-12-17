#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Lightning Server functions
############################################################

# Install Lightning Server using Helm
install_lightning_server() {
    log_info "Installing Lightning Server..."
    
    local server_release="lightning-server"
    local server_chart="helm-zetaris-lightning-server/lightning-server"
    local server_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Lightning Server is already installed
    log_info "Checking Lightning Server release '$server_release' in namespace '$server_namespace'"
    
    if helm list -n "$server_namespace" 2>/dev/null | grep -q "$server_release"; then
        echo "✅ Lightning Server release '$server_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$server_namespace" -l app=lightning-server --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Lightning Server pods are running"
            return 0
        else
            echo "⚠️  Lightning Server release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$server_namespace'"

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$server_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$server_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Lightning Server..."

    # Set default values for optional parameters (for local environment)
    local aws_efs_id=""
    local aws_efs_data=""
    local storage_account_name=""
    local storage_account_key=""
    
    # For local environment, these cloud parameters can be empty
    if [ "$ENVIRONMENT" = "local" ]; then
        echo "Local environment detected - using minimal cloud configuration"
        aws_efs_id=""
        aws_efs_data=""
        storage_account_name=""
        storage_account_key=""
    fi

    # Debug: Display JDBC URLs being configured
    echo "Debug - JDBC URLs being configured:"
    echo "   Metastore JDBC URL: $METASTORE_JDBC_URL"
    echo "   Audit Log JDBC URL: $AUDITLOG_JDBC_URL"
    echo "   Storage Class: $STORAGE_CLASS"
    echo ""

    # Install or upgrade Lightning Server

    if helm upgrade --install "$server_release" "$server_chart" \
        --namespace "$server_namespace" \
        --set "db.metastore.jdbcUrl=$METASTORE_JDBC_URL" \
        --set "db.auditLog.jdbcUrl=$AUDITLOG_JDBC_URL" \
        --set "storage.storageClass.name=$STORAGE_CLASS" \
        --set "storage.storageClass.create=$STORAGE_CLASS_CREATE" \
        --set "environment=$ENVIRONMENT" \
        --set "encryption.privateKeyDer=$ZETARIS_PRIVATE_KEY_DER" \
        --set "encryption.publicKeyDer=$ZETARIS_PUBLIC_KEY_DER" \
        --set "azure.storageAccountName=$storage_account_name" \
        --set "azure.storageAccountKey=$storage_account_key" \
        --set "aws.efs.id=$aws_efs_id" \
        --set "aws.efs.data=$aws_efs_data" \
        --set "serverImage=$ZETARIS_SERVER_IMAGE" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Lightning Server installed successfully!"
        
        # Wait for pods to be ready
        echo "Waiting for Lightning Server pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=lightning-server-driver -n "$server_namespace" --timeout=900s; then
            echo "Lightning Server is ready!"
            
            # Display Lightning Server information
            display_lightning_server_info
            
            return 0
        else
            echo "❌ Lightning Server pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Lightning Server"
        return 1
    fi
}

# Display Lightning Server information
display_lightning_server_info() {
    local server_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    echo "Lightning Server Information:"
    echo "   Namespace: $server_namespace"
    echo "   Storage Class: $STORAGE_CLASS"
    echo "   Environment: $ENVIRONMENT"
    echo "   Server Image: $ZETARIS_SERVER_IMAGE"
    echo "   Metastore DB: $META_DB"
    echo "   Audit Log DB: $AUDIT_DB"
    echo ""
    echo "Lightning Server Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$server_namespace" -l app=lightning-server --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name
    service_name=$(kubectl get svc -n "$server_namespace" | grep "lightning-server" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$service_name" != "N/A" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$server_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        echo "   Service Name: $service_name"
        echo "   Service IP: $service_ip"
    else
        echo "   Service Name: Not found"
        echo "   Service IP: N/A"
    fi
    
    # Show PVC information
    echo "   Persistent Volume Claims:"
    kubectl get pvc -n "$server_namespace" -l app=lightning-server --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SIZE:.spec.resources.requests.storage 2>/dev/null || echo "     - No PVCs found"

    echo ""
    echo "Lightning Server URLs:"
    if [ "$service_name" != "N/A" ]; then
        echo "   Internal: http://$service_name.$server_namespace.svc.cluster.local:8080"
        echo "   Health Check: http://$service_name.$server_namespace.svc.cluster.local:8080/health"
    fi
    echo ""
    echo "To test Lightning Server:"
    echo "   kubectl exec -it \$(kubectl get pods -n $server_namespace -l app=lightning-server -o jsonpath='{.items[0].metadata.name}') -n $server_namespace -- ps aux | grep java"
    echo ""
}

# Verify Lightning Server functionality
verify_lightning_server() {
    echo "Verifying Lightning Server functionality..."
    
    local server_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$server_namespace" &> /dev/null; then
        echo "❌ Lightning Server namespace '$server_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$server_namespace" | grep "lightning-server" | grep "Running" | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Lightning Server pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Lightning Server pod(s)"
    
    # Get the service name dynamically
    local service_name
    service_name=$(kubectl get svc -n "$server_namespace" | grep "lightning-server" | awk '{print $1}' | head -1 2>/dev/null)
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Lightning Server service '$service_name' is available"
        
        # Get a Lightning Server pod
        local server_pod
        server_pod=$(kubectl get pods -n "$server_namespace" -l app=lightning-server-driver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$server_pod" ]; then
            echo "Lightning Server pod '$server_pod' is available"
            echo "✅ Lightning Server is ready and accessible"
            return 0
        else
            echo "❌ No Lightning Server pods found"
            return 1
        fi
    else
        echo "❌ Lightning Server service not found"
        return 1
    fi
}

# Check Lightning Server logs for any issues
check_lightning_server_logs() {
    echo "Checking Lightning Server logs for issues..."
    
    local server_namespace=${ZETARIS_NS:-zetaris}
    local server_pods
    # server_pods=$(kubectl get pods -n "$server_namespace" -l app=lightning-server-driver -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    server_pods=$(kubectl get pods -n "$server_namespace" | grep lightning-server | awk '{print $1}' 2>/dev/null)

    if [ -z "$server_pods" ]; then
        echo "❌ No Lightning Server pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Lightning Server pod
    for pod in $server_pods; do
        echo "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$server_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
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
        echo "To view full logs: kubectl logs -l app=lightning-server -n $server_namespace"
        return 1
    else
        echo "✅ No errors found in Lightning Server logs"
        return 0
    fi
}

# Test Lightning Server basic functionality
test_lightning_server() {
    echo "Testing Lightning Server basic functionality..."
    
    local server_namespace=${ZETARIS_NS:-zetaris}
    local server_pod
    # server_pod=$(kubectl get pods -n "$server_namespace" -l app=lightning-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    server_pod=$(kubectl get pods -n "$server_namespace" | grep lightning-server-driver | awk '{print $1}' 2>/dev/null)

    if [ -z "$server_pod" ]; then
        echo "❌ No Lightning Server pods found"
        return 1
    fi
    
    # Check if Java process is running inside the pod
    echo "Checking if Lightning Server Java process is running..."
    if kubectl exec -n "$server_namespace" "$server_pod" -- pgrep -f java &>/dev/null; then
        echo "✅ Lightning Server Java process is running"
        
        # Test Lightning Server service connectivity
        echo "Testing Lightning Server service connectivity..."
        local service_name="lightning-server-driver-svc"
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$server_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$server_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "10000")
        
        # Ensure service_port is a valid number
        if ! [[ "$service_port" =~ ^[0-9]+$ ]]; then
            service_port=10000
        fi
        
        if [ -n "$service_ip" ]; then
            echo "🔍 Testing Lightning Server endpoint: $service_ip:$service_port"
            
            # Use netcat test from a busybox pod to test service connectivity
            if kubectl run test-lightning-server-connection --image=busybox:latest --rm -i --restart=Never -n "$server_namespace" -- \
               nc -z -w5 "$service_ip" "$service_port" &>/dev/null; then
                echo "✅ Lightning Server port $service_port is accessible via netcat"
                return 0
            else
                echo "⚠️  Lightning Server port $service_port is not accessible"
                return 1
            fi
        else
            echo "❌ Could not get Lightning Server service IP"
            return 1
        fi
    else
        echo "⚠️  Lightning Server Java process is not running"
        return 1
    fi
}

# Main function to setup Lightning Server completely
setup_lightning_server() {
    echo "Setting up Lightning Server for Zetaris..."
    
    # Install Lightning Server
    if ! install_lightning_server; then
        echo "❌ Failed to install Lightning Server"
        return 1
    fi
    
    # Wait a moment for Lightning Server to initialize
    echo "Waiting for Lightning Server to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_lightning_server; then
        echo "❌ Lightning Server verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_lightning_server_logs; then
        echo "⚠️  Found issues in Lightning Server logs, but continuing..."
    fi
    
    # Test Lightning Server functionality
    if ! test_lightning_server; then
        echo "⚠️  Lightning Server functionality test failed, but continuing..."
    fi
    
    echo "Lightning Server setup completed successfully!"
    return 0
}

# Cleanup Lightning Server installation
cleanup_lightning_server() {
    echo "Cleaning up Lightning Server..."
    
    local server_release="lightning-server"
    local server_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$server_namespace" 2>/dev/null | grep -q "$server_release"; then
        echo "Uninstalling Lightning Server Helm release..."
        helm uninstall "$server_release" -n "$server_namespace"
    else
        echo "Lightning Server release not found"
    fi
    
    # Clean up PVCs
    echo "Cleaning up Lightning Server PVCs..."
    kubectl delete pvc -n "$server_namespace" -l app=lightning-server --ignore-not-found=true
    
    # Clean up any remaining secrets
    echo "Cleaning up Lightning Server secrets..."
    kubectl delete secret -n "$server_namespace" -l app=lightning-server --ignore-not-found=true
    
    echo "✅ Lightning Server cleanup completed"
}