#!/usr/bin/env bash

############################################################
# Professional Logging Functions for Zetaris Deployment
############################################################

# Initialize logging with timestamped log file
init_logging() {
    local timestamp=$(date +"%Y%m%d.%H%M%S")
    export ZETARIS_LOG_FILE="zetaris-deployment-${timestamp}.log"
    export ZETARIS_LOG_LEVEL=${ZETARIS_LOG_LEVEL:-INFO}
    
    # Create logs directory if it doesn't exist
    mkdir -p logs
    export ZETARIS_LOG_FILE="logs/${ZETARIS_LOG_FILE}"
    
    # Initialize log file with header
    {
        echo "========================================================"
        echo "Zetaris Deployment Log"
        echo "Started: $(date)"
        echo "Log Level: $ZETARIS_LOG_LEVEL"
        echo "========================================================"
        echo ""
    } > "$ZETARIS_LOG_FILE"
    
    echo "[INFO] Logging initialized: $ZETARIS_LOG_FILE"
}

# Professional logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Format: [TIMESTAMP] [LEVEL] MESSAGE
    local formatted_message="[$timestamp] [$level] $message"
    
    # Write to log file if initialized
    if [[ -n "${ZETARIS_LOG_FILE:-}" ]]; then
        echo "$formatted_message" >> "$ZETARIS_LOG_FILE"
    fi
    
    # Output to console with appropriate formatting
    case "$level" in
        "ERROR")
            echo "❌ $message" ;;
        "WARN"|"WARNING")
            echo "⚠️ $message" ;;
        "SUCCESS")
            echo "✅ $message" ;;
        "INFO")
            echo "[INFO] $message" ;;
        "DEBUG")
            if [[ "${ZETARIS_LOG_LEVEL}" == "DEBUG" ]]; then
                echo "[DEBUG] $message"
            fi ;;
        *)
            echo "[$level] $message" ;;
    esac
}

# Convenience functions for different log levels
log_info() {
    log_message "INFO" "$1"
}

log_success() {
    log_message "SUCCESS" "$1"
}

log_warn() {
    log_message "WARNING" "$1"
}

log_error() {
    log_message "ERROR" "$1"
}

log_debug() {
    log_message "DEBUG" "$1"
}

# Function to log command execution
log_command() {
    local cmd="$1"
    local description="${2:-Executing command}"
    
    log_debug "$description: $cmd"
    
    if eval "$cmd" >> "$ZETARIS_LOG_FILE" 2>&1; then
        log_debug "Command completed successfully"
        return 0
    else
        local exit_code=$?
        log_error "Command failed with exit code $exit_code: $cmd"
        return $exit_code
    fi
}

# Function to start a deployment step
start_deployment_step() {
    local step_name="$1"
    echo ""
    echo "=========================================="
    echo "Starting: $step_name"
    echo "=========================================="
    log_message "INFO" "Starting deployment step: $step_name"
}

# Function to complete a deployment step
complete_deployment_step() {
    local step_name="$1"
    local success="${2:-true}"
    
    if [[ "$success" == "true" ]]; then
        log_success "Completed deployment step: $step_name"
        echo "==========================================]"
        echo ""
    else
        log_error "Failed deployment step: $step_name"
        echo "=========================================="
        echo ""
        return 1
    fi
}

# Function to log deployment summary
log_deployment_summary() {
    local status="$1"
    local duration="$2"
    
    {
        echo ""
        echo "========================================================"
        echo "Deployment Summary"
        echo "Status: $status"
        echo "Duration: ${duration:-Unknown}"
        echo "Completed: $(date)"
        echo "========================================================"
    } >> "$ZETARIS_LOG_FILE"
    
    if [[ "$status" == "SUCCESS" ]]; then
        log_success "Zetaris deployment completed successfully"
        log_info "Full deployment log available at: $ZETARIS_LOG_FILE"
    else
        log_error "Zetaris deployment failed"
        log_info "Check deployment log for details: $ZETARIS_LOG_FILE"
    fi
}