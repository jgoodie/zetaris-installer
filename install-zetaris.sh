#!/usr/bin/env bash
set -euo pipefail  # Exit on errors, undefined vars, pipe failures

# Source configuration
source ./config/zetaris.conf

# Include function libraries
source ./lib/logging-functions.sh
source ./lib/k8s-functions.sh
source ./lib/helm-functions.sh
source ./lib/helm-opensearch-functions.sh
source ./lib/helm-cert-mgr-functions.sh
source ./lib/helm-spark-op-functions.sh
source ./lib/helm-postgresql.sh
source ./lib/helm-solr-functions.sh
source ./lib/helm-lightning-server-functions.sh
source ./lib/helm-lightning-api-functions.sh
source ./lib/helm-lightning-gui-functions.sh
source ./lib/helm-lightning-zeppelin-functions.sh
source ./lib/helm-private-ai-functions.sh
source ./lib/helm-digiavatar-functions.sh
source ./lib/helm-airflow-functions.sh
source ./lib/user-account-functions.sh
# source ./lib/validation.sh

# Main installation flow
main() {
    # Initialize logging
    init_logging
    
    local start_time=$(date +%s)
    log_info "Starting Zetaris deployment"
    
    # Ensure Helm is installed and ready
    start_deployment_step "Helm Setup"
    if ! ensure_helm; then
        log_error "Failed to setup Helm"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Helm Setup"

    # Setup Kubernetes environment
    start_deployment_step "Kubernetes Environment Setup"
    if ! setup_k8s_environment; then
        log_error "Failed to setup Kubernetes environment"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Kubernetes Environment Setup"

    # Later, when installing Helm charts that need the service account
    add_helm_metadata_to_serviceaccount "zetaris-sa" "zetaris" "lightning-server"
    label_namespace "cert-manager" "certmanager.k8s.io/disable-validation" "true"

    # Setup PostgreSQL
    start_deployment_step "PostgreSQL Setup"
    if ! setup_postgres; then
        log_error "Failed to setup PostgreSQL"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "PostgreSQL Setup"
    
    # Setup Spark Operator
    start_deployment_step "Spark Operator Setup"
    if ! setup_spark_operator; then
        log_error "Failed to setup Spark Operator"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Spark Operator Setup"

    # Setup cert-manager
    start_deployment_step "Certificate Manager Setup"
    if ! setup_cert_manager; then
        log_error "Failed to setup cert-manager"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Certificate Manager Setup"

    # Setup OpenSearch
    start_deployment_step "OpenSearch Setup"
    if ! setup_opensearch; then
        log_error "Failed to setup OpenSearch"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "OpenSearch Setup"
    
    # Setup Lightning Solr
    start_deployment_step "Lightning Solr Setup"
    if ! setup_lightning_solr; then
        log_error "Failed to setup Lightning Solr"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Lightning Solr Setup"

    # Setup Lightning Server
    start_deployment_step "Lightning Server Setup"
    if ! setup_lightning_server; then
        log_error "Failed to setup Lightning Server"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Lightning Server Setup"

    # Setup Lightning API
    start_deployment_step "Lightning API Setup"
    if ! setup_lightning_api; then
        log_error "Failed to setup Lightning API"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Lightning API Setup"

    # Setup Lightning GUI
    start_deployment_step "Lightning GUI Setup"
    if ! setup_lightning_gui; then
        log_error "Failed to setup Lightning GUI"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Lightning GUI Setup"

    # Setup Lightning Zeppelin
    start_deployment_step "Lightning Zeppelin Setup"
    if ! setup_lightning_zeppelin; then
        log_error "Failed to setup Lightning Zeppelin"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Lightning Zeppelin Setup"

    # Setup Private AI
    start_deployment_step "Private AI Setup"
    if ! setup_private_ai; then
        log_error "Failed to setup Private AI"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Private AI Setup"

    # Setup Digiavatar
    start_deployment_step "Digiavatar Setup"
    if ! setup_digiavatar; then
        log_error "Failed to setup Digiavatar"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "Digiavatar Setup"

    # # Airflow Deployment
    # if ! setup_airflow; then
    #     echo "❌ Failed to setup Airflow. Exiting."
    #     exit 1
    # fi

    # Create user account
    start_deployment_step "User Account Creation"
    if ! create_user_account "$LIGHTNING_INIT_EMAIL" "$LIGHTNING_INIT_PASSWORD" "$LIGHTNING_INIT_ORG"; then
        log_error "Failed to create initial Lightning user account"
        log_deployment_summary "FAILED" "$(( $(date +%s) - start_time )) seconds"
        exit 1
    fi
    complete_deployment_step "User Account Creation"

    # Complete deployment
    local end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    log_deployment_summary "SUCCESS" "${duration} seconds"
}

main "$@"

