#!/bin/bash

# Generic Log Rotation and Management Script for Service Monitor
# Handles log rotation, compression, and cleanup based on configuration

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
MAX_LOG_SIZE_MB=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.maxLogSizeMB);")
RETENTION_DAYS=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.retentionDays);")
COMPRESSION_ENABLED=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.compressionEnabled);")
GZIP_BINARY=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.gzipBinary);")

BACKUP_EXTENSION=".old"

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

# Get file size in MB
get_file_size_mb() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local size_bytes=$(stat -c%s "$file" 2>/dev/null || echo "0")
        echo $((size_bytes / 1024 / 1024))
    else
        echo "0"
    fi
}

# Rotate a single log file
rotate_log_file() {
    local log_file="$1"
    local base_name="$(basename "$log_file")"
    local dir_name="$(dirname "$log_file")"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local rotated_name="${base_name}.${timestamp}"
    local rotated_path="$dir_name/$rotated_name"
    
    if [[ ! -f "$log_file" ]]; then
        log "WARN" "Log file not found: $log_file"
        return 1
    fi
    
    local file_size=$(get_file_size_mb "$log_file")
    
    if [[ $file_size -ge $MAX_LOG_SIZE_MB ]]; then
        log "INFO" "Rotating $base_name (${file_size}MB)"
        
        # Copy and truncate original file
        if cp "$log_file" "$rotated_path"; then
            # Truncate original file
            > "$log_file"
            
            # Compress if enabled and gzip is available
            if [[ "$COMPRESSION_ENABLED" == "true" ]]; then
                if command -v "$GZIP_BINARY" &> /dev/null; then
                    "$GZIP_BINARY" "$rotated_path"
                    rotated_path="${rotated_path}.gz"
                    log "INFO" "Compressed to $rotated_name.gz"
                else
                    log "WARN" "$GZIP_BINARY not available, skipping compression"
                fi
            fi
            
            log "SUCCESS" "Rotated $base_name"
            return 0
        else
            log "ERROR" "Failed to rotate $base_name"
            return 1
        fi
    else
        log "DEBUG" "$base_name is ${file_size}MB (< ${MAX_LOG_SIZE_MB}MB threshold)"
        return 0
    fi
}

# Clean up old log files
cleanup_old_logs() {
    log "INFO" "Cleaning up logs older than $RETENTION_DAYS days..."
    
    local cleaned_count=0
    
    # Find and remove old log files
    if [[ -d "$LOG_DIR" ]]; then
        while IFS= read -r -d '' file; do
            local file_age_days=$(( ($(date +%s) - $(stat -c %Y "$file")) / 86400 ))
            
            if [[ $file_age_days -gt $RETENTION_DAYS ]]; then
                log "INFO" "Removing old log: $(basename "$file") (${file_age_days} days old)"
                rm -f "$file"
                ((cleaned_count++))
            fi
        done < <(find "$LOG_DIR" -type f \\( -name "*.log.*" -o -name "*.log.gz" \\) -print0 2>/dev/null || true)
    fi
    
    if [[ $cleaned_count -gt 0 ]]; then
        log "SUCCESS" "Cleaned up $cleaned_count old log files"
    else
        log "INFO" "No old log files to clean up"
    fi
}

# Get all log files from configuration and filesystem
get_all_log_files() {
    local log_files=()
    
    # Add standard monitor log files
    log_files+=("$LOG_DIR/$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.monitorLogFile);")")
    log_files+=("$LOG_DIR/$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.daemonLogFile);")")
    log_files+=("$LOG_DIR/$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.portMonitorLogFile);")")
    
    # Add service-specific log files from configuration
    node -e "
        const config = require('$CONFIG_FILE').getCliConfig();
        config.services.forEach(service => {
            if (service.pm2Config.out_file) console.log(service.pm2Config.out_file);
            if (service.pm2Config.error_file) console.log(service.pm2Config.error_file);
            if (service.pm2Config.log_file) console.log(service.pm2Config.log_file);
        });
    " | while read -r log_file; do
        if [[ -n "$log_file" ]]; then
            log_files+=("$log_file")
        fi
    done
    
    # Add any additional .log files found in log directory
    if [[ -d "$LOG_DIR" ]]; then
        while IFS= read -r -d '' file; do
            log_files+=("$file")
        done < <(find "$LOG_DIR" -name "*.log" -type f -print0 2>/dev/null || true)
    fi
    
    # Remove duplicates and print
    printf '%s\\n' "${log_files[@]}" | sort -u
}

# Rotate all log files
rotate_all_logs() {
    log "INFO" "Rotating all log files..."
    
    local rotated_count=0
    local log_files
    
    # Get all log files
    readarray -t log_files < <(get_all_log_files)
    
    for log_file in "${log_files[@]}"; do
        if [[ -f "$log_file" ]] && rotate_log_file "$log_file"; then
            ((rotated_count++))
        fi
    done
    
    # Flush PM2 logs to ensure clean start
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);" 2>/dev/null || echo "pm2")
    if command -v "$pm2_binary" &> /dev/null && "$pm2_binary" status &> /dev/null; then
        "$pm2_binary" flush > /dev/null 2>&1 || true
        log "INFO" "PM2 logs flushed"
    fi
    
    log "SUCCESS" "Log rotation completed ($rotated_count files rotated)"
}

# Generate log rotation report
generate_report() {
    log "INFO" "Generating log rotation report..."
    
    local report_file="$LOG_DIR/logrotate-report.txt"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "Service Monitor Log Rotation Report - $timestamp"
        echo "=================================================="
        echo ""
        echo "Configuration:"
        echo "  Max log size: ${MAX_LOG_SIZE_MB}MB"
        echo "  Retention: $RETENTION_DAYS days"
        echo "  Compression: $COMPRESSION_ENABLED"
        echo "  Log directory: $LOG_DIR"
        echo ""
        echo "Configured services:"
        
        node -e "
            const config = require('$CONFIG_FILE').getCliConfig();
            config.services.forEach((service, index) => {
                console.log(\`  \${index + 1}. \${service.name} (port \${service.port})\`);
            });
        "
        
        echo ""
        echo "Current log files:"
        
        if [[ -d "$LOG_DIR" ]]; then
            find "$LOG_DIR" -name "*.log" -type f -exec ls -lh {} \\; | while read -r line; do
                echo "  $line"
            done
            
            echo ""
            echo "Archived log files:"
            find "$LOG_DIR" -name "*.log.*" -type f -exec ls -lh {} \\; | while read -r line; do
                echo "  $line"
            done
        fi
        
        echo ""
        echo "Disk usage:"
        du -sh "$LOG_DIR" 2>/dev/null | awk '{print "  Log directory: " $1}' || echo "  Log directory: N/A"
        
    } > "$report_file"
    
    log "SUCCESS" "Report generated: $report_file"
}

# Show current log status
show_log_status() {
    log "INFO" "Current log file status:"
    echo ""
    
    if [[ -d "$LOG_DIR" ]]; then
        # Show current active logs
        echo "Active log files:"
        local log_files
        readarray -t log_files < <(get_all_log_files)
        
        for log_file in "${log_files[@]}"; do
            if [[ -f "$log_file" ]]; then
                local size_mb=$(get_file_size_mb "$log_file")
                local base_name=$(basename "$log_file")
                printf "  %-30s %3dMB" "$base_name" "$size_mb"
                
                if [[ $size_mb -ge $MAX_LOG_SIZE_MB ]]; then
                    echo " (needs rotation)"
                else
                    echo ""
                fi
            fi
        done
        
        echo ""
        echo "Archived log files:"
        local archived_count=$(find "$LOG_DIR" -name "*.log.*" -type f | wc -l)
        echo "  Count: $archived_count"
        
        if [[ $archived_count -gt 0 ]]; then
            local total_size=$(du -sh "$LOG_DIR" 2>/dev/null | awk '{print $1}')
            echo "  Total size: $total_size"
        fi
    else
        echo "Log directory not found: $LOG_DIR"
    fi
    
    echo ""
}

# Install cron job for automatic log rotation
install_cron_job() {
    log "INFO" "Installing cron job for automatic log rotation..."
    
    local cron_entry="0 2 * * * $SCRIPT_DIR/logrotate.sh rotate >/dev/null 2>&1"
    local temp_cron=$(mktemp)
    
    # Get current crontab
    crontab -l 2>/dev/null > "$temp_cron" || true
    
    # Remove existing entry if present
    grep -v "$SCRIPT_DIR/logrotate.sh" "$temp_cron" > "${temp_cron}.new" || true
    mv "${temp_cron}.new" "$temp_cron"
    
    # Add new entry
    echo "$cron_entry" >> "$temp_cron"
    
    # Install new crontab
    if crontab "$temp_cron"; then
        log "SUCCESS" "Cron job installed (runs daily at 2 AM)"
    else
        log "ERROR" "Failed to install cron job"
    fi
    
    rm -f "$temp_cron"
}

# Remove cron job
remove_cron_job() {
    log "INFO" "Removing cron job for automatic log rotation..."
    
    local temp_cron=$(mktemp)
    
    # Get current crontab and remove our entry
    if crontab -l 2>/dev/null | grep -v "$SCRIPT_DIR/logrotate.sh" > "$temp_cron"; then
        crontab "$temp_cron"
        log "SUCCESS" "Cron job removed"
    else
        log "INFO" "No cron job found to remove"
    fi
    
    rm -f "$temp_cron"
}

# Main execution
main() {
    case "${1:-status}" in
        "rotate")
            log "INFO" "Starting log rotation..."
            rotate_all_logs
            cleanup_old_logs
            generate_report
            log "SUCCESS" "Log rotation completed successfully"
            ;;
        "cleanup")
            cleanup_old_logs
            ;;
        "status")
            show_log_status
            ;;
        "report")
            generate_report
            cat "$LOG_DIR/logrotate-report.txt" 2>/dev/null || log "ERROR" "Report file not found"
            ;;
        "install-cron")
            install_cron_job
            ;;
        "remove-cron")
            remove_cron_job
            ;;
        "force-rotate")
            log "INFO" "Force rotating all log files..."
            # Temporarily set max size to 0 to force rotation
            MAX_LOG_SIZE_MB=0
            rotate_all_logs
            log "SUCCESS" "Force rotation completed"
            ;;
        *)
            echo "Generic Service Monitor - Log Rotation Management"
            echo ""
            echo "Usage: $0 {rotate|cleanup|status|report|install-cron|remove-cron|force-rotate}"
            echo ""
            echo "Commands:"
            echo "  rotate       - Rotate logs based on size and clean up old files"
            echo "  cleanup      - Clean up old log files only"
            echo "  status       - Show current log file status (default)"
            echo "  report       - Generate and display log rotation report"
            echo "  install-cron - Install daily cron job for automatic rotation"
            echo "  remove-cron  - Remove automatic rotation cron job"
            echo "  force-rotate - Force rotate all log files regardless of size"
            echo ""
            echo "Configuration:"
            echo "  Max log size: ${MAX_LOG_SIZE_MB}MB"
            echo "  Retention: $RETENTION_DAYS days"
            echo "  Compression: $COMPRESSION_ENABLED"
            echo "  Log directory: $LOG_DIR"
            echo ""
            echo "Configuration file: $CONFIG_FILE"
            exit 1
            ;;
    esac
}

# Ensure log directory exists
mkdir -p "$LOG_DIR"

# Validate configuration
if ! node -e "require('$CONFIG_FILE').getCliConfig();" &>/dev/null; then
    echo "ERROR: Invalid configuration file: $CONFIG_FILE"
    exit 1
fi

# Run main function
main "$@"