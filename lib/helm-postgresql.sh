#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Source logging functions if not already loaded
if ! declare -f log_info >/dev/null 2>&1; then
    source ./lib/logging-functions.sh
fi

############################################################
# PostgreSQL functions
############################################################

# Install PostgreSQL using Helm
install_postgres() {
    echo "Installing PostgreSQL..."
    
    local postgres_release="postgres"
    local postgres_chart="helm-postgres/postgres"
    local postgres_namespace=${ZETARIS_NS:-zetaris}
    
    # Check if PostgreSQL is already installed
    if helm list -n "$postgres_namespace" | grep -q "$postgres_release"; then
        echo "✅ PostgreSQL release '$postgres_release' already exists"
        
        # Check if pods are running
        local pod_count
        pod_count=$(kubectl get pods -n "$postgres_namespace" -l app=postgres --no-headers 2>/dev/null | wc -l || echo "0")
        if [ "$pod_count" -gt 0 ]; then
            log_success "PostgreSQL pods are running"
            return 0
        else
            echo "⚠️  PostgreSQL release exists but no pods found. Upgrading..."
        fi
    fi
    
    log_info "Installing/upgrading PostgreSQL..."
    
    # Install or upgrade PostgreSQL
    if helm upgrade --install "$postgres_release" "$postgres_chart" \
        --namespace "$postgres_namespace" \
        --set "storageClassName=$STORAGE_CLASS" \
        --set "environment=$ENVIRONMENT" \
        --timeout=10m \
        --wait; then
        
        echo "✅ PostgreSQL installed successfully!"
        
        # Wait for pods to be ready
        log_info "Waiting for PostgreSQL pods to be ready..."
        if kubectl wait --for=condition=ready pod -l app=postgres -n "$postgres_namespace" --timeout=300s; then
            log_success "PostgreSQL is ready!"
            
            # Display connection information
            display_postgres_info
            
            return 0
        else
            echo "❌ PostgreSQL pods failed to become ready within timeout"
            return 1
        fi
    else
        echo "❌ Failed to install PostgreSQL"
        return 1
    fi
}

# Display PostgreSQL connection information
display_postgres_info() {

    local postgres_namespace=${ZETARIS_NS:-zetaris}
    
    echo ""
    log_info "PostgreSQL Connection Information:"
    echo "   Namespace: $postgres_namespace"
    echo "   Service: postgres"
    echo "   Port: 5432"
    echo "   Username: $DB_USER"
    echo "   Password: $DB_PASSWORD"
    echo ""
    log_info "JDBC URLs:"
    echo "   Metastore: $METASTORE_JDBC_URL"
    echo "   Audit Log: $AUDITLOG_JDBC_URL"
    echo ""
    log_info "To connect to PostgreSQL:"
    echo "   kubectl exec -it \$(kubectl get pods -n $postgres_namespace -l app=postgres -o jsonpath='{.items[0].metadata.name}') -n $postgres_namespace -- psql -h postgres -U $DB_USER postgres"
    echo ""
}

# Create required databases in PostgreSQL
create_postgres_databases() {
    echo "Creating PostgreSQL databases..."
    
    local postgres_namespace=${ZETARIS_NS:-zetaris}
    local databases=("$META_DB" "$AUDIT_DB" "$AIRFLOW_DB")
    
    # Get PostgreSQL pod name
    local postgres_pod
    postgres_pod=$(kubectl get pods -n "$postgres_namespace" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$postgres_pod" ]; then
        echo "❌ No PostgreSQL pods found"
        return 1
    fi
    
    log_info "Using PostgreSQL pod: $postgres_pod"
    
    # Create databases
    for db in "${databases[@]}"; do
        echo "Creating database: $db"
        
        if kubectl exec -n "$postgres_namespace" "$postgres_pod" -- \
            psql "postgresql://$DB_USER:$DB_PASSWORD@postgres:5432/postgres" -c "CREATE DATABASE $db;" 2>/dev/null; then
            echo "✅ Database '$db' created successfully"
        else
            # Check if database already exists
            if kubectl exec -n "$postgres_namespace" "$postgres_pod" -- \
                psql "postgresql://$DB_USER:$DB_PASSWORD@postgres:5432/postgres" -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$db"; then
                echo "✅ Database '$db' already exists"
            else
                echo "❌ Failed to create database '$db'"
                return 1
            fi
        fi
    done
    
    log_success "All PostgreSQL databases created successfully!"
    return 0
}

# Verify PostgreSQL connectivity
verify_postgres_connectivity() {
    log_info "Verifying PostgreSQL connectivity..."
    
    local postgres_namespace=${ZETARIS_NS:-zetaris}
    local postgres_pod
    postgres_pod=$(kubectl get pods -n "$postgres_namespace" -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$postgres_pod" ]; then
        echo "❌ No PostgreSQL pods found"
        return 1
    fi
    
    # Test connection
    log_info "Testing PostgreSQL connectivity..."
    if kubectl exec -n "$postgres_namespace" "$postgres_pod" -- \
        psql "postgresql://$DB_USER:$DB_PASSWORD@postgres:5432/postgres" -c "SELECT version();" &>/dev/null; then
        echo "✅ PostgreSQL connectivity verified"
        
        # List databases
        log_info "Listing PostgreSQL databases..."
        log_info "Available databases:"
        kubectl exec -n "$postgres_namespace" "$postgres_pod" -- \
            psql "postgresql://$DB_USER:$DB_PASSWORD@postgres:5432/postgres" -lqt 2>/dev/null | cut -d \| -f 1 | grep -v "^$" | sed 's/^ */   - /'
        
        return 0
    else
        echo "❌ Cannot connect to PostgreSQL"
        return 1
    fi
}

# Main function to setup PostgreSQL completely
setup_postgres() {
    log_success "Setting up PostgreSQL for Zetaris..."
    
    # Install PostgreSQL
    if ! install_postgres; then
        echo "❌ Failed to install PostgreSQL"
        return 1
    fi
    
    # Wait a moment for PostgreSQL to fully initialize
    log_info "Waiting for PostgreSQL to initialize..."
    sleep 10
    
    # Verify connectivity
    if ! verify_postgres_connectivity; then
        echo "❌ PostgreSQL connectivity check failed"
        return 1
    fi
    
    # Create required databases
    if ! create_postgres_databases; then
        echo "❌ Failed to create PostgreSQL databases"
        return 1
    fi
    
    # Final verification
    verify_postgres_connectivity
    
    log_success "PostgreSQL setup completed successfully!"
    return 0
}

# Cleanup PostgreSQL installation
cleanup_postgres() {
    log_info "Cleaning up PostgreSQL..."
    
    local postgres_release="postgres"
    local postgres_namespace=${ZETARIS_NS:-zetaris}
    
    if helm list -n "$postgres_namespace" | grep -q "$postgres_release"; then
        log_info " Uninstalling PostgreSQL Helm release..."
        helm uninstall "$postgres_release" -n "$postgres_namespace"
    else
        log_info " PostgreSQL release not found"
    fi
    
    # Clean up any remaining PVCs
    log_info "Cleaning up PostgreSQL PVCs..."
    kubectl delete pvc -n "$postgres_namespace" -l app=postgres --ignore-not-found=true
    
    echo "✅ PostgreSQL cleanup completed"
}
