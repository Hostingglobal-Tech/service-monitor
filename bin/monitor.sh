#!/bin/bash

# Generic Process Monitoring and Auto-Restart Daemon
# Monitors configured services using service-monitor.config.js
# Automatically restarts failed services with PM2

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_MONITOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$SERVICE_MONITOR_ROOT/config/service-monitor.config.js"

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Get configuration values using Node.js
get_config() {
    local path="$1"
    node -e "
        const config = require('$CONFIG_FILE').getCliConfig();
        const value = path.split('.').reduce((obj, key) => obj && obj[key], config);
        console.log(value || '');
    " --path="$path"
}

# Configuration values
LOG_DIR=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.logDir);")
MONITOR_LOG="$LOG_DIR/$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.monitorLogFile);")"
PORT_SCANNER="$SCRIPT_DIR/port-scanner.js"
ECOSYSTEM_CONFIG=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.pm2.ecosystemFile);")

# Monitoring settings
MAX_RESTART_ATTEMPTS=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.monitoring.maxRestartAttempts);")
RESTART_DELAY=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(Math.floor(config.monitoring.restartDelay / 1000));")
HEALTH_CHECK_INTERVAL=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(Math.floor(config.monitoring.interval / 1000));")
CONSECUTIVE_FAILURES_THRESHOLD=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.monitoring.consecutiveFailureThreshold);")

# Get service names from configuration
get_service_names() {
    node -e "
        const config = require('$CONFIG_FILE').getCliConfig();
        const names = config.services.map(s => s.name);
        console.log(names.join(' '));
    "
}

SERVICE_NAMES=($(get_service_names))

# Counter files directory
COUNTER_DIR="$LOG_DIR/.counters"

# Ensure directories exist
mkdir -p "$LOG_DIR" "$COUNTER_DIR"

# Logging function with level support
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get configured log level
    local configured_level=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.level);")
    
    # Level hierarchy: DEBUG=0, INFO=1, WARN=2, ERROR=3
    local level_num
    case "$level" in
        "DEBUG") level_num=0 ;;
        "INFO") level_num=1 ;;
        "WARN") level_num=2 ;;
        "ERROR") level_num=3 ;;
        *) level_num=1 ;;
    esac
    
    local configured_level_num
    case "$configured_level" in
        "DEBUG") configured_level_num=0 ;;
        "INFO") configured_level_num=1 ;;
        "WARN") configured_level_num=2 ;;
        "ERROR") configured_level_num=3 ;;
        *) configured_level_num=1 ;;
    esac
    
    # Only log if level is at or above configured level
    if [[ $level_num -ge $configured_level_num ]]; then
        echo "[$timestamp] [$level] $message" | tee -a "$MONITOR_LOG"
    fi
}

# Initialize restart count files for all services
init_counters() {
    for service_name in "${SERVICE_NAMES[@]}"; do
        echo "0" > "$COUNTER_DIR/${service_name}_restart_count" 2>/dev/null || true
        echo "0" > "$COUNTER_DIR/${service_name}_failure_count" 2>/dev/null || true
    done
}

# Get restart count for a service
get_restart_count() {
    local service="$1"
    local count_file="$COUNTER_DIR/${service}_restart_count"
    
    if [[ -f "$count_file" ]]; then
        cat "$count_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Increment restart count for a service
increment_restart_count() {
    local service="$1"
    local count_file="$COUNTER_DIR/${service}_restart_count"
    
    local current_count=$(get_restart_count "$service")
    local new_count=$((current_count + 1))
    echo "$new_count" > "$count_file"
    echo "$new_count"
}

# Get failure count for a service
get_failure_count() {
    local service="$1"
    local count_file="$COUNTER_DIR/${service}_failure_count"
    
    if [[ -f "$count_file" ]]; then
        cat "$count_file" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Increment failure count for a service
increment_failure_count() {
    local service="$1"
    local count_file="$COUNTER_DIR/${service}_failure_count"
    
    local current_count=$(get_failure_count "$service")
    local new_count=$((current_count + 1))
    echo "$new_count" > "$count_file"
    echo "$new_count"
}

# Reset failure count for a service
reset_failure_count() {
    local service="$1"
    local count_file="$COUNTER_DIR/${service}_failure_count"
    
    echo "0" > "$count_file"
}

# Check if PM2 is running
check_pm2_running() {
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    
    if ! command -v "$pm2_binary" &> /dev/null; then
        log "ERROR" "PM2 is not installed or not in PATH ($pm2_binary)"
        return 1
    fi
    
    if ! "$pm2_binary" status &> /dev/null; then
        log "WARN" "PM2 daemon is not running"
        return 1
    fi
    
    return 0
}

# Check service status using PM2
check_pm2_service() {
    local service_name="$1"
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    local jq_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.jqBinary);")
    
    if ! check_pm2_running; then
        return 1
    fi
    
    local status
    if command -v "$jq_binary" &> /dev/null; then
        status=$("$pm2_binary" jlist | "$jq_binary" -r ".[] | select(.name == \"$service_name\") | .pm2_env.status" 2>/dev/null || echo "")
    else
        # Fallback without jq
        status=$("$pm2_binary" status | grep -E "^│.*$service_name.*│" | awk -F '│' '{print $10}' | tr -d ' ' || echo "")
    fi
    
    if [[ "$status" == "online" ]]; then
        return 0
    else
        log "WARN" "PM2 service $service_name status: $status"
        return 1
    fi
}

# Restart service using PM2
restart_service() {
    local service_name="$1"
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    
    if ! check_pm2_running; then
        log "ERROR" "Cannot restart $service_name: PM2 is not running"
        return 1
    fi
    
    local restart_count=$(increment_restart_count "$service_name")
    
    if [[ $restart_count -gt $MAX_RESTART_ATTEMPTS ]]; then
        log "ERROR" "Maximum restart attempts ($MAX_RESTART_ATTEMPTS) exceeded for $service_name"
        return 1
    fi
    
    log "INFO" "Attempting to restart $service_name (attempt $restart_count/$MAX_RESTART_ATTEMPTS)"
    
    # Try to restart the service
    if "$pm2_binary" restart "$service_name" 2>/dev/null; then
        log "INFO" "Successfully restarted $service_name"
        
        # Wait for service to stabilize
        sleep "$RESTART_DELAY"
        
        # Verify restart was successful
        if check_pm2_service "$service_name"; then
            log "INFO" "$service_name is running after restart"
            reset_failure_count "$service_name"
            return 0
        else
            log "ERROR" "$service_name failed to start properly after restart"
            return 1
        fi
    else
        log "ERROR" "Failed to restart $service_name using PM2"
        return 1
    fi
}

# Generate ecosystem configuration and start services
start_services() {
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    
    # Generate ecosystem configuration
    generate_ecosystem_config
    
    if ! check_pm2_running; then
        log "INFO" "Starting PM2 ecosystem..."
        "$pm2_binary" start "$ECOSYSTEM_CONFIG" || {
            log "ERROR" "Failed to start PM2 ecosystem"
            return 1
        }
    fi
    
    # Check individual services
    for service_name in "${SERVICE_NAMES[@]}"; do
        if ! check_pm2_service "$service_name"; then
            log "INFO" "Starting $service_name..."
            "$pm2_binary" start "$ECOSYSTEM_CONFIG" --only "$service_name" || {
                log "ERROR" "Failed to start $service_name"
            }
        fi
    done
}

# Generate PM2 ecosystem configuration from service-monitor config
generate_ecosystem_config() {
    node -e "
        const { getCliConfig, generateEcosystemConfig } = require('$CONFIG_FILE');
        const config = getCliConfig();
        const ecosystemConfig = generateEcosystemConfig(config);
        const fs = require('fs');
        
        const content = 'module.exports = ' + JSON.stringify(ecosystemConfig, null, 2) + ';';
        fs.writeFileSync('$ECOSYSTEM_CONFIG', content);
    "
}

# Comprehensive health check
run_health_check() {
    log "DEBUG" "Running comprehensive health check..."
    
    if [[ -f "$PORT_SCANNER" ]]; then
        local health_result
        local node_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.nodeBinary);")
        
        if health_result=$("$node_binary" "$PORT_SCANNER" --json 2>/dev/null); then
            local jq_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.jqBinary);")
            
            if command -v "$jq_binary" &> /dev/null; then
                local healthy_count=$(echo "$health_result" | "$jq_binary" -r '.healthy // 0' 2>/dev/null || echo "0")
                local down_count=$(echo "$health_result" | "$jq_binary" -r '.down // 0' 2>/dev/null || echo "0")
                local unhealthy_count=$(echo "$health_result" | "$jq_binary" -r '.unhealthy // 0' 2>/dev/null || echo "0")
                
                log "DEBUG" "Health check results: $healthy_count healthy, $unhealthy_count unhealthy, $down_count down"
                
                # Check individual services and handle failures
                echo "$health_result" | "$jq_binary" -r '.services[] | "\(.name):\(.overall)"' 2>/dev/null | while IFS=: read -r service_name status; do
                    if [[ "$status" == "down" || "$status" == "unhealthy" ]]; then
                        local failure_count=$(increment_failure_count "$service_name")
                        log "WARN" "$service_name is $status (failure count: $failure_count)"
                        
                        if [[ $failure_count -ge $CONSECUTIVE_FAILURES_THRESHOLD ]]; then
                            log "ERROR" "$service_name has failed $failure_count consecutive times, attempting restart..."
                            restart_service "$service_name"
                        fi
                    else
                        # Service is healthy, reset failure count
                        reset_failure_count "$service_name"
                    fi
                done
                
                return $([[ $down_count -eq 0 && $unhealthy_count -eq 0 ]] && echo 0 || echo 1)
            else
                # Fallback without jq - parse JSON manually
                log "WARN" "jq not available, using basic health check"
                local exit_code
                "$node_binary" "$PORT_SCANNER" >/dev/null 2>&1
                exit_code=$?
                return $exit_code
            fi
        else
            log "ERROR" "Health check script failed"
            return 1
        fi
    else
        log "ERROR" "Port scanner script not found: $PORT_SCANNER"
        return 1
    fi
}

# Monitor services continuously
monitor_services() {
    log "INFO" "Starting generic service monitoring daemon..."
    log "INFO" "Monitoring ${#SERVICE_NAMES[@]} services: ${SERVICE_NAMES[*]}"
    log "INFO" "Monitoring interval: ${HEALTH_CHECK_INTERVAL}s"
    log "INFO" "Max restart attempts: $MAX_RESTART_ATTEMPTS"
    log "INFO" "Consecutive failure threshold: $CONSECUTIVE_FAILURES_THRESHOLD"
    
    # Initialize counters
    init_counters
    
    # Ensure services are started
    start_services
    
    # Main monitoring loop
    while true; do
        if run_health_check; then
            log "DEBUG" "All services are healthy"
        else
            log "WARN" "One or more services have issues"
        fi
        
        # Wait for next check
        sleep "$HEALTH_CHECK_INTERVAL"
    done
}

# Show current status of all services
show_status() {
    echo "=== Service Monitor Status ==="
    echo "Configuration: $CONFIG_FILE"
    echo "Services: ${SERVICE_NAMES[*]}"
    echo "Log directory: $LOG_DIR"
    echo ""
    
    # Show restart and failure counts
    echo "=== Service Counters ==="
    for service_name in "${SERVICE_NAMES[@]}"; do
        local restart_count=$(get_restart_count "$service_name")
        local failure_count=$(get_failure_count "$service_name")
        printf "%-20s Restarts: %2d  Failures: %2d\n" "$service_name" "$restart_count" "$failure_count"
    done
    echo ""
    
    # Run health check
    echo "=== Current Health Status ==="
    local node_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.nodeBinary);")
    "$node_binary" "$PORT_SCANNER"
}

# Handle signals for graceful shutdown
cleanup() {
    log "INFO" "Received termination signal, shutting down monitor..."
    exit 0
}

trap cleanup SIGTERM SIGINT

# Main execution
main() {
    case "${1:-monitor}" in
        "monitor")
            monitor_services
            ;;
        "check")
            run_health_check
            ;;
        "start")
            start_services
            ;;
        "restart")
            local service="${2:-all}"
            if [[ "$service" == "all" ]]; then
                for service_name in "${SERVICE_NAMES[@]}"; do
                    restart_service "$service_name"
                done
            else
                restart_service "$service"
            fi
            ;;
        "status")
            show_status
            ;;
        "reset")
            init_counters
            log "INFO" "Reset all restart and failure counters for services: ${SERVICE_NAMES[*]}"
            ;;
        "generate-config")
            generate_ecosystem_config
            log "INFO" "Generated PM2 ecosystem configuration at $ECOSYSTEM_CONFIG"
            ;;
        *)
            echo "Generic Service Monitor - Configuration-driven process monitoring"
            echo ""
            echo "Usage: $0 {monitor|check|start|restart [service]|status|reset|generate-config}"
            echo ""
            echo "Commands:"
            echo "  monitor         - Start continuous monitoring (default)"
            echo "  check           - Run single health check"
            echo "  start           - Start all configured services"
            echo "  restart [name]  - Restart services (all or specific service name)"
            echo "  status          - Show current service status and counters"
            echo "  reset           - Reset restart and failure counters"
            echo "  generate-config - Generate PM2 ecosystem configuration"
            echo ""
            echo "Configuration file: $CONFIG_FILE"
            echo "Configured services: ${SERVICE_NAMES[*]}"
            exit 1
            ;;
    esac
}

# Check dependencies
check_dependencies() {
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);" 2>/dev/null || echo "pm2")
    local node_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.nodeBinary);" 2>/dev/null || echo "node")
    local jq_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.jqBinary);" 2>/dev/null || echo "jq")
    
    if ! command -v "$node_binary" &> /dev/null; then
        log "ERROR" "Node.js is required but not found ($node_binary)"
        exit 1
    fi
    
    if ! command -v "$pm2_binary" &> /dev/null; then
        log "ERROR" "PM2 is required but not installed. Run: npm install -g pm2"
        exit 1
    fi

    if ! command -v "$jq_binary" &> /dev/null; then
        log "WARN" "jq is not installed ($jq_binary). Some features may not work properly. Install with: sudo apt install jq"
    fi
}

# Validate configuration
if ! node -e "require('$CONFIG_FILE').getCliConfig();" &>/dev/null; then
    echo "ERROR: Invalid configuration file: $CONFIG_FILE"
    exit 1
fi

# Check dependencies
check_dependencies

# Run main function
main "$@"