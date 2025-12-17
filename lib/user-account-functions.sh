#!/usr/bin/env bash
# User Account Functions for Zetaris Lightning

create_user_account() {
    local email="$1"
    local password="$2"
    local org="$3"
    
    log_info "Creating Lightning user account..."
    echo "   Email: $email"
    echo "   Organization: $org"
    
    # Validate required parameters
    if [[ -z "$email" || -z "$password" || -z "$org" ]]; then
        echo "❌ Error: Missing required parameters for user account creation"
        echo "   Usage: create_user_account <email> <password> <org>"
        return 1
    fi
    
    # Wait for lightning-server-driver pod to be ready
    log_info "Waiting for lightning-server-driver pod to be ready..."
    if ! kubectl wait --for=condition=ready pod -l app=lightning-server-driver -n "$ZETARIS_NS" --timeout=300s; then
        echo "❌ Lightning server driver pod is not ready after 5 minutes"
        return 1
    fi
    
    # Get the pod name
    local pod_name
    pod_name=$(kubectl get pods -n "$ZETARIS_NS" -l app=lightning-server-driver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$pod_name" ]]; then
        echo "❌ Could not find lightning-server-driver pod in namespace $ZETARIS_NS"
        return 1
    fi
    
    echo "✅ Found lightning-server-driver pod: $pod_name"
    
    # Check if the dev-account.sh script exists in the pod
    log_info "Checking if dev-account.sh script exists..."
    if ! kubectl exec -n "$ZETARIS_NS" "$pod_name" -- test -f /home/zetaris/lightning/bin/dev-account.sh; then
        echo "❌ dev-account.sh script not found in lightning-server-driver pod"
        echo "   Expected location: /home/zetaris/lightning/bin/dev-account.sh"
        return 1
    fi
    
    echo "✅ dev-account.sh script found"
    
    # Execute the user account creation script
    log_success "Creating Lightning user account..."
    if kubectl exec -it -n "$ZETARIS_NS" "$pod_name" -- bash -c "cd /home/zetaris/lightning/bin/ && ./dev-account.sh '$email' '$password' '$org'"; then
        echo "✅ Lightning user account created successfully"
        echo "   Email: $email"
        echo "   Organization: $org"
        echo ""
        log_success "You can now log in to Lightning with these credentials!"
        return 0
    else
        echo "❌ Failed to create Lightning user account"
        echo "   Check the pod logs for more details:"
        echo "   kubectl logs -n $ZETARIS_NS $pod_name"
        return 1
    fi
}

# Function to verify user account creation
verify_user_account() {
    local email="$1"
    
    log_info "Verifying user account creation for: $email"
    
    # Get the pod name
    local pod_name
    pod_name=$(kubectl get pods -n "$ZETARIS_NS" -l app=lightning-server-driver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -z "$pod_name" ]]; then
        echo "❌ Could not find lightning-server-driver pod"
        return 1
    fi
    
    # Check if we can query the user account (this may vary depending on available tools in the pod)
    log_info " To verify the account was created, you can:"
    echo "   1. Check the Lightning GUI at: $DNS_PROTOCOL://$BASE_DNS_NAME"
    echo "   2. Check the pod logs: kubectl logs -n $ZETARIS_NS $pod_name"
    echo "   3. Connect to the database and query the users table"
    
    return 0
}

# Function to list available Lightning pods for troubleshooting
list_lightning_pods() {
    log_info "Lightning pods in namespace $ZETARIS_NS:"
    kubectl get pods -n "$ZETARIS_NS" -l app.kubernetes.io/part-of=lightning --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,READY:.status.containerStatuses[*].ready
}

# Function to show Lightning server logs
show_lightning_logs() {
    local lines="${1:-50}"
    
    log_info "Lightning server logs (last $lines lines):"
    local pod_name
    pod_name=$(kubectl get pods -n "$ZETARIS_NS" -l app=lightning-server-driver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [[ -n "$pod_name" ]]; then
        kubectl logs -n "$ZETARIS_NS" "$pod_name" --tail="$lines"
    else
        echo "❌ Could not find lightning-server-driver pod"
        return 1
    fi
}