#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# Lightning API functions
############################################################

# Install Lightning API using Helm
install_lightning_api() {
    log_info "Installing Lightning API..."
    
    local api_release="lightning-api"
    local api_chart="helm-zetaris-lightning-api/lightning-api"
    local api_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if Lightning API is already installed
    log_info "Checking to see if Lightning API release '$api_release' exists in namespace '$api_namespace'..."
    
    if helm list -n "$api_namespace" 2>/dev/null | grep -q "$api_release"; then
        echo "✅ Lightning API release '$api_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$api_namespace" -l app=lightning-api --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "Lightning API pods are running"
            return 0
        else
            echo "⚠️  Lightning API release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Verifying Service Account 'zetaris-sa' in namespace '$api_namespace'..."

    # Ensure service account exists
    if ! kubectl get serviceaccount zetaris-sa -n "$api_namespace" &> /dev/null; then
        echo "⚠️  Service account 'zetaris-sa' not found in namespace '$api_namespace'"
        log_info "Make sure to run setup_k8s_environment first"
        return 1
    fi

    log_info "Installing/upgrading Lightning API..."

    # Set default values for optional parameters (for local environment)
    local tls_cert_arn=""
    
    # For local environment, AWS TLS cert ARN can be empty
    if [ "$ENVIRONMENT" = "local" ]; then
        log_info "Local environment detected - using minimal AWS configuration"
        tls_cert_arn=""
    fi

    # Debug: Display configuration being used
    log_info "Debug - Lightning API configuration:"
    echo "   Environment: $ENVIRONMENT"
    echo "   API Image: $ZETARIS_API_IMAGE"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Metastore JDBC URL: $METASTORE_JDBC_URL"
    echo "   Audit Log JDBC URL: $AUDITLOG_JDBC_URL"
    echo "   Compute Spark Image: $ZETARIS_COMPUTE_SPARK_IMAGE"
    echo "   Compute Presto Image Repo: $ZETARIS_COMPUTE_PRESTO_IMAGE_REPO"
    echo "   Compute Presto Image Tag: $ZETARIS_COMPUTE_PRESTO_IMAGE_TAG"
    echo "   Private Key DER: ${ZETARIS_PRIVATE_KEY_DER:0:20}... (${#ZETARIS_PRIVATE_KEY_DER} chars)"
    echo "   Public Key DER: ${ZETARIS_PUBLIC_KEY_DER:0:20}... (${#ZETARIS_PUBLIC_KEY_DER} chars)"
    echo ""

    if helm upgrade --install "$api_release" "$api_chart" \
        --namespace "$api_namespace" \
        --set "environment=$ENVIRONMENT" \
        --set "apiImage=$ZETARIS_API_IMAGE" \
        --set "ingress.protocol=$DNS_PROTOCOL" \
        --set "aws.ingress.tls_cert_arn=$tls_cert_arn" \
        --set "ingress.baseDomain=$BASE_DNS_NAME" \
        --set "db.metastore.jdbcUrl=$METASTORE_JDBC_URL" \
        --set "db.auditLog.jdbcUrl=$AUDITLOG_JDBC_URL" \
        --set "compute.spark.image=$ZETARIS_COMPUTE_SPARK_IMAGE" \
        --set "compute.presto.imageRepo=$ZETARIS_COMPUTE_PRESTO_IMAGE_REPO" \
        --set "compute.presto.imageTag=$ZETARIS_COMPUTE_PRESTO_IMAGE_TAG" \
        --set "encryption.privateKeyDer=$ZETARIS_PRIVATE_KEY_DER" \
        --set "encryption.publicKeyDer=$ZETARIS_PUBLIC_KEY_DER" \
        --timeout=15m \
        --wait; then
        
        echo "✅ Lightning API installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for Lightning API pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=lightning-api -n "$api_namespace" --timeout=900s; then
            log_success "Lightning API is ready!"
            
            # Display Lightning API information
            display_lightning_api_info
            
            return 0
        else
            echo "❌ Lightning API pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install Lightning API"
        return 1
    fi
}

# Display Lightning API information
display_lightning_api_info() {
    local api_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "Lightning API Information:"
    echo "   Namespace: $api_namespace"
    echo "   Environment: $ENVIRONMENT"
    echo "   API Image: $ZETARIS_API_IMAGE"
    echo "   DNS Protocol: $DNS_PROTOCOL"
    echo "   Base DNS Name: $BASE_DNS_NAME"
    echo "   Metastore DB: $META_DB"
    echo "   Audit Log DB: $AUDIT_DB"
    echo ""
    log_info "Lightning API Status:"
    
    # Show running pods
    local pod_count
    pod_count=$(kubectl get pods -n "$api_namespace" -l app=lightning-api --no-headers 2>/dev/null | wc -l || echo "0")
    echo "   Running Pods: $pod_count"
    
    # Show service information
    local service_name
    service_name=$(kubectl get svc -n "$api_namespace" | grep "lightning-api" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$service_name" != "N/A" ]; then
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$api_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "N/A")
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$api_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "N/A")
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
    ingress_name=$(kubectl get ingress -n "$api_namespace" | grep "lightning-api" | awk '{print $1}' | head -1 2>/dev/null || echo "N/A")
    
    if [ "$ingress_name" != "N/A" ]; then
        echo "   Ingress Name: $ingress_name"
        local ingress_host
        ingress_host=$(kubectl get ingress "$ingress_name" -n "$api_namespace" -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "N/A")
        echo "   Ingress Host: $ingress_host"
    else
        echo "   Ingress Name: Not configured"
        echo "   Ingress Host: N/A"
    fi

    echo ""
    log_info "Lightning API URLs:"
    if [ "$service_name" != "N/A" ]; then
        echo "   Internal: $DNS_PROTOCOL://$service_name.$api_namespace.svc.cluster.local:$service_port"
        echo "   Health Check: $DNS_PROTOCOL://$service_name.$api_namespace.svc.cluster.local:$service_port/health"
    fi
    
    if [ "$ingress_name" != "N/A" ] && [ "$ingress_host" != "N/A" ]; then
        echo "   External: $DNS_PROTOCOL://$ingress_host"
        echo "   External Health: $DNS_PROTOCOL://$ingress_host/health"
    fi
    
    echo ""
    log_info "To test Lightning API:"
    echo "   kubectl exec -it \$(kubectl get pods -n $api_namespace -l app=lightning-api -o jsonpath='{.items[0].metadata.name}') -n $api_namespace -- ps aux | grep java"
    echo ""
}

# Verify Lightning API functionality
verify_lightning_api() {
    log_info "Verifying Lightning API functionality..."
    
    local api_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if namespace exists
    if ! kubectl get namespace "$api_namespace" &> /dev/null; then
        echo "❌ Lightning API namespace '$api_namespace' not found"
        return 1
    fi
    
    # Check if pods are running
    local running_pods
    running_pods=$(kubectl get pods -n "$api_namespace" -l app=lightning-api --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l || echo "0")
    if [ "$running_pods" -eq 0 ]; then
        echo "❌ No running Lightning API pods found"
        return 1
    fi
    
    echo "✅ Found $running_pods running Lightning API pod(s)"
    
    # Get the service name dynamically
    local service_name
    service_name=$(kubectl get svc -n "$api_namespace" | grep "lightning-api" | awk '{print $1}' | head -1 2>/dev/null)
    
    if [ -n "$service_name" ] && [ "$service_name" != "" ]; then
        echo "✅ Lightning API service '$service_name' is available"
        
        # Get a Lightning API pod
        local api_pod
        api_pod=$(kubectl get pods -n "$api_namespace" -l app=lightning-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        if [ -n "$api_pod" ]; then
            log_info "Lightning API pod '$api_pod' is available"
            echo "✅ Lightning API is ready and accessible"
            return 0
        else
            echo "❌ No Lightning API pods found"
            return 1
        fi
    else
        echo "❌ Lightning API service not found"
        return 1
    fi
}

# Check Lightning API logs for any issues
check_lightning_api_logs() {
    log_info "Checking Lightning API logs for issues..."
    
    local api_namespace=${ZETARIS_NS:-zetaris}
    local api_pods
    api_pods=$(kubectl get pods -n "$api_namespace" -l app=lightning-api -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    if [ -z "$api_pods" ]; then
        echo "❌ No Lightning API pods found"
        return 1
    fi
    
    local has_errors=false
    
    # Check each Lightning API pod
    for pod in $api_pods; do
        log_info "Checking logs for pod: $pod"
        
        # Check for errors in recent logs
        local error_count
        error_count=$(kubectl logs "$pod" -n "$api_namespace" --tail=50 2>/dev/null | grep -i -c "error\|exception\|failed" 2>/dev/null | tail -1 || echo "0")
        
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
        log_info "To view full logs: kubectl logs -l app=lightning-api -n $api_namespace"
        return 1
    else
        echo "✅ No errors found in Lightning API logs"
        return 0
    fi
}

# Test Lightning API basic functionality
test_lightning_api() {
    log_info "Testing Lightning API basic functionality..."
    
    local api_namespace=${ZETARIS_NS:-zetaris}
    local api_pod
    api_pod=$(kubectl get pods -n "$api_namespace" -l app=lightning-api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$api_pod" ]; then
        echo "❌ No Lightning API pods found"
        return 1
    fi
    
    # Check if Java process is running inside the pod
    log_info "Checking if Lightning API Java process is running..."
    if kubectl exec -n "$api_namespace" "$api_pod" -- pgrep -f java &>/dev/null; then
        echo "✅ Lightning API Java process is running"
        
        # Get the Lightning API service details
        log_info "Testing Lightning API service connectivity..."
        local service_name="lightning-api-svc"
        local service_ip
        service_ip=$(kubectl get svc "$service_name" -n "$api_namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
        local service_port
        service_port=$(kubectl get svc "$service_name" -n "$api_namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8888")
        
        # Ensure service_port is a valid number
        if ! [[ "$service_port" =~ ^[0-9]+$ ]]; then
            service_port=8888
        fi
        
        if [ -n "$service_ip" ]; then
            log_info "Testing Lightning API endpoint: $service_ip:$service_port"
            
            # Try to connect to the API health endpoint using curl from within a pod
            # Use a lightweight curl test that should get a response (even if it's an error about missing headers)
            local test_result
            test_result=$(kubectl run test-lightning-api-connection --image=curlimages/curl:latest --rm -i --restart=Never -n "$api_namespace" -- \
                curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 \
                "http://$service_ip:$service_port/api/v1.0/auth/refresh" 2>/dev/null | head -1 || echo "000")
            
            # Clean up the result to ensure we only have the HTTP status code
            test_result=$(echo "$test_result" | grep -o '^[0-9]\{3\}' || echo "000")
            
            log_info "Lightning API connection test result: HTTP $test_result"

            # Check if we got any valid HTTP response code (2xx, 3xx, 4xx, 5xx are all good - means API is responding)
            # Only 000 indicates connection failure or timeout
            if [[ "$test_result" =~ ^[0-9]{3}$ ]] && [ "$test_result" -ne 000 ] && [ "$test_result" -ge 200 ]; then
                echo "✅ Lightning API is responding (HTTP $test_result)"
                return 0
            else
                echo "⚠️  Lightning API connection test failed (HTTP $test_result)"
                
                # Fallback: try netcat test from a busybox pod
                log_info "Trying netcat connection test as fallback..."
                if kubectl run test-lightning-api-nc --image=busybox:latest --rm -i --restart=Never -n "$api_namespace" -- \
                   nc -z -w5 "$service_ip" "$service_port" &>/dev/null; then
                    echo "✅ Lightning API port $service_port is accessible via netcat"
                    return 0
                else
                    echo "⚠️  Lightning API port $service_port is not accessible"
                    return 1
                fi
            fi
        else
            echo "❌ Could not get Lightning API service IP"
            return 1
        fi
    else
        echo "⚠️  Lightning API Java process is not running"
        return 1
    fi
}

# Main function to setup Lightning API completely
setup_lightning_api() {
    log_success "Setting up Lightning API for Zetaris..."
    
    # Install Lightning API
    if ! install_lightning_api; then
        echo "❌ Failed to install Lightning API"
        return 1
    fi
    
    # Wait a moment for Lightning API to initialize
    log_info "Waiting for Lightning API to initialize..."
    sleep 30
    
    # Verify functionality
    if ! verify_lightning_api; then
        echo "❌ Lightning API verification failed"
        return 1
    fi
    
    # Check logs for any issues
    if ! check_lightning_api_logs; then
        echo "⚠️  Found issues in Lightning API logs, but continuing..."
    fi
    
    # Test Lightning API functionality
    if ! test_lightning_api; then
        echo "⚠️  Lightning API functionality test failed, but continuing..."
    fi
    
    log_success "Lightning API setup completed successfully!"
    return 0
}

# Cleanup Lightning API installation
cleanup_lightning_api() {
    log_info "Cleaning up Lightning API..."
    
    local api_release="lightning-api"
    local api_namespace=${ZETARIS_NS:-zetaris}
    
    # Uninstall Helm release
    if helm list -n "$api_namespace" 2>/dev/null | grep -q "$api_release"; then
        log_info " Uninstalling Lightning API Helm release..."
        helm uninstall "$api_release" -n "$api_namespace"
    else
        log_info " Lightning API release not found"
    fi
    
    # Clean up any remaining secrets
    log_info "Cleaning up Lightning API secrets..."
    kubectl delete secret -n "$api_namespace" -l app=lightning-api --ignore-not-found=true
    
    # Clean up any ingress
    log_info "Cleaning up Lightning API ingress..."
    kubectl delete ingress -n "$api_namespace" -l app=lightning-api --ignore-not-found=true
    
    echo "✅ Lightning API cleanup completed"
}