#!/bin/bash

# Generic Service Monitor Stop Script
# Gracefully stops PM2 ecosystem and monitoring daemon

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

# Get configuration values
LOG_DIR=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.logDir);")
ECOSYSTEM_CONFIG=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.pm2.ecosystemFile);")

# Colors for output
RED='\\033[0;31m'
GREEN='\\033[0;32m'
YELLOW='\\033[1;33m'
BLUE='\\033[0;34m'
NC='\\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")
            echo -e "${BLUE}[$timestamp] [INFO]${NC} $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[$timestamp] [SUCCESS]${NC} $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[$timestamp] [WARN]${NC} $message"
            ;;
        "ERROR")
            echo -e "${RED}[$timestamp] [ERROR]${NC} $message"
            ;;
        *)
            echo -e "[$timestamp] [$level] $message"
            ;;
    esac
}

# Stop monitoring daemon
stop_monitoring() {
    log "INFO" "Stopping monitoring daemon..."
    
    local pid_file="$LOG_DIR/.monitor_daemon.pid"
    local stopped=false
    
    # Try to stop using PID file
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "INFO" "Stopping monitoring daemon (PID: $pid)..."
            kill -TERM "$pid" 2>/dev/null || true
            
            # Wait for graceful shutdown
            local wait_count=0
            while [[ $wait_count -lt 10 ]] && kill -0 "$pid" 2>/dev/null; do
                sleep 1
                ((wait_count++))
            done
            
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                log "WARN" "Forcing termination of monitoring daemon..."
                kill -KILL "$pid" 2>/dev/null || true
            fi
            
            stopped=true
        fi
        
        # Clean up PID file
        rm -f "$pid_file"
    fi
    
    # Find and stop any remaining monitor processes
    local monitor_pids
    monitor_pids=$(pgrep -f "monitor.sh.*monitor" 2>/dev/null || true)
    
    if [[ -n "$monitor_pids" ]]; then
        log "INFO" "Stopping additional monitoring processes..."
        echo "$monitor_pids" | while read -r pid; do
            if [[ -n "$pid" ]]; then
                kill -TERM "$pid" 2>/dev/null || true
                stopped=true
            fi
        done
        
        # Wait a moment then force kill if needed
        sleep 2
        monitor_pids=$(pgrep -f "monitor.sh.*monitor" 2>/dev/null || true)
        if [[ -n "$monitor_pids" ]]; then
            echo "$monitor_pids" | while read -r pid; do
                if [[ -n "$pid" ]]; then
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            done
        fi
    fi
    
    if [[ "$stopped" == true ]]; then
        log "SUCCESS" "Monitoring daemon stopped"
    else
        log "INFO" "No monitoring daemon was running"
    fi
}

# Stop PM2 services
stop_pm2_services() {
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    
    log "INFO" "Stopping PM2 services..."
    
    if ! command -v "$pm2_binary" &> /dev/null; then
        log "WARN" "PM2 not found, skipping PM2 shutdown"
        return 0
    fi
    
    # Check if PM2 daemon is running
    if ! "$pm2_binary" status &> /dev/null; then
        log "INFO" "PM2 daemon is not running"
        return 0
    fi
    
    # Get service names from configuration
    local service_names
    service_names=$(node -e "
        const config = require('$CONFIG_FILE').getCliConfig();
        const names = config.services.map(s => s.name);
        console.log(names.join(' '));
    ")
    
    # Stop services gracefully
    log "INFO" "Stopping configured services: $service_names"
    for service_name in $service_names; do
        log "INFO" "Stopping $service_name..."
        "$pm2_binary" stop "$service_name" 2>/dev/null || log "WARN" "Failed to stop $service_name (may not be running)"
    done
    
    # Delete services from PM2
    for service_name in $service_names; do
        log "INFO" "Deleting $service_name from PM2..."
        "$pm2_binary" delete "$service_name" 2>/dev/null || log "WARN" "Failed to delete $service_name"
    done
    
    log "SUCCESS" "PM2 services stopped"
}

# Stop PM2 daemon
stop_pm2_daemon() {
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    local kill_daemon="${1:-false}"
    
    if ! command -v "$pm2_binary" &> /dev/null; then
        return 0
    fi
    
    if "$pm2_binary" status &> /dev/null; then
        if [[ "$kill_daemon" == true ]]; then
            log "INFO" "Stopping PM2 daemon..."
            "$pm2_binary" kill || log "WARN" "Failed to stop PM2 daemon"
            log "SUCCESS" "PM2 daemon stopped"
        else
            log "INFO" "PM2 daemon left running (use --cleanup to stop daemon)"
        fi
    else
        log "INFO" "PM2 daemon is not running"
    fi
}

# Clean up log files (optional)
cleanup_logs() {
    log "INFO" "Cleaning up log files..."
    
    # Rotate logs before cleanup
    if [[ -f "$SCRIPT_DIR/logrotate.sh" ]]; then
        "$SCRIPT_DIR/logrotate.sh" rotate || log "WARN" "Log rotation failed"
    fi
    
    # Clean up PID files and temporary files
    find "$LOG_DIR" -name ".*.pid" -delete 2>/dev/null || true
    find "$LOG_DIR" -name ".counters" -type d -exec rm -rf {} + 2>/dev/null || true
    
    log "SUCCESS" "Log cleanup completed"
}

# Show final status
show_final_status() {
    log "INFO" "Final status check..."
    
    # Check if any services are still running
    local node_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.nodeBinary);")
    
    if [[ -f "$SCRIPT_DIR/port-scanner.js" ]]; then
        if "$node_binary" "$SCRIPT_DIR/port-scanner.js" --json &>/dev/null; then
            log "WARN" "Some services may still be running"
            "$node_binary" "$SCRIPT_DIR/port-scanner.js"
        else
            log "SUCCESS" "All monitored services stopped"
        fi
    fi
    
    # Check PM2 status
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    if command -v "$pm2_binary" &> /dev/null && "$pm2_binary" status &> /dev/null; then
        local running_count=$("$pm2_binary" jlist 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
        if [[ "$running_count" -gt 0 ]]; then
            log "INFO" "PM2 daemon still running with $running_count processes"
        fi
    fi
}

# Main stop routine
main() {
    local cleanup_logs_flag=false
    local stop_daemon=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cleanup)
                cleanup_logs_flag=true
                stop_daemon=true
                shift
                ;;
            --kill-daemon)
                stop_daemon=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                echo "Usage: $0 [--cleanup] [--kill-daemon]"
                echo ""
                echo "Options:"
                echo "  --cleanup      Clean up logs and stop PM2 daemon"
                echo "  --kill-daemon  Stop PM2 daemon (keeps it running by default)"
                exit 1
                ;;
        esac
    done
    
    log "INFO" "Stopping Generic Service Monitor..."
    
    # Run shutdown sequence
    stop_monitoring
    stop_pm2_services
    stop_pm2_daemon "$stop_daemon"
    
    if [[ "$cleanup_logs_flag" == true ]]; then
        cleanup_logs
    fi
    
    show_final_status
    
    log "SUCCESS" "Service Monitor shutdown completed!"
}

# Handle emergency cleanup (when run with SIGTERM)
emergency_cleanup() {
    log "WARN" "Emergency shutdown initiated..."
    
    # Force stop everything
    pkill -f "monitor.sh.*monitor" 2>/dev/null || true
    
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);" 2>/dev/null || echo "pm2")
    if command -v "$pm2_binary" &> /dev/null; then
        "$pm2_binary" kill 2>/dev/null || true
    fi
    
    # Clean up PID files
    find "$LOG_DIR" -name ".*.pid" -delete 2>/dev/null || true
    
    log "SUCCESS" "Emergency cleanup completed"
    exit 0
}

# Set up signal handlers
trap emergency_cleanup SIGTERM SIGINT

# Validate configuration
if ! node -e "require('$CONFIG_FILE').getCliConfig();" &>/dev/null; then
    echo "ERROR: Invalid configuration file: $CONFIG_FILE"
    exit 1
fi

# Run main function
main "$@"