#!/bin/bash

# Generic Service Monitor Startup Script
# Starts configured services and initiates monitoring

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
MONITOR_SCRIPT="$SCRIPT_DIR/monitor.sh"
DAEMON_LOG="$LOG_DIR/$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.logging.daemonLogFile);")"

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

# Check dependencies
check_dependencies() {
    log "INFO" "Checking dependencies..."
    
    local missing_deps=()
    
    # Check Node.js
    local node_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.nodeBinary);" 2>/dev/null || echo "node")
    if ! command -v "$node_binary" &> /dev/null; then
        missing_deps+=("Node.js ($node_binary)")
    fi
    
    # Check PM2
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);" 2>/dev/null || echo "pm2")
    if ! command -v "$pm2_binary" &> /dev/null; then
        missing_deps+=("PM2 ($pm2_binary)")
    fi
    
    # Check optional dependencies
    local jq_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.jqBinary);" 2>/dev/null || echo "jq")
    if ! command -v "$jq_binary" &> /dev/null; then
        log "WARN" "jq is not installed ($jq_binary). Some features may not work properly."
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi
    
    log "SUCCESS" "All dependencies are available"
    return 0
}

# Verify project structure
verify_project_structure() {
    log "INFO" "Verifying project structure..."
    
    local required_files=(
        "$CONFIG_FILE"
        "$SCRIPT_DIR/monitor.sh"
        "$SCRIPT_DIR/port-scanner.js"
    )
    
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        log "ERROR" "Missing required files: ${missing_files[*]}"
        return 1
    fi
    
    log "SUCCESS" "Project structure verified"
    return 0
}

# Create necessary directories
create_directories() {
    log "INFO" "Creating necessary directories..."
    
    mkdir -p "$LOG_DIR"
    mkdir -p "$(dirname "$ECOSYSTEM_CONFIG")"
    
    # Create log directory structure for services
    node -e "
        const config = require('$CONFIG_FILE').getCliConfig();
        const fs = require('fs');
        const path = require('path');
        
        config.services.forEach(service => {
            if (service.pm2Config.out_file) {
                const dir = path.dirname(service.pm2Config.out_file);
                if (!fs.existsSync(dir)) {
                    fs.mkdirSync(dir, { recursive: true });
                }
            }
            if (service.pm2Config.error_file) {
                const dir = path.dirname(service.pm2Config.error_file);
                if (!fs.existsSync(dir)) {
                    fs.mkdirSync(dir, { recursive: true });
                }
            }
            if (service.pm2Config.log_file) {
                const dir = path.dirname(service.pm2Config.log_file);
                if (!fs.existsSync(dir)) {
                    fs.mkdirSync(dir, { recursive: true });
                }
            }
        });
    "
    
    log "SUCCESS" "Directories created"
}

# Stop existing development processes
stop_dev_processes() {
    log "INFO" "Stopping existing development processes..."
    
    # Stop common development processes
    pkill -f "npm.*dev" 2>/dev/null || true
    pkill -f "yarn.*dev" 2>/dev/null || true
    pkill -f "vite" 2>/dev/null || true
    pkill -f "webpack-dev-server" 2>/dev/null || true
    pkill -f "next.*dev" 2>/dev/null || true
    
    # Wait a moment for processes to stop
    sleep 3
    
    log "SUCCESS" "Development processes stopped"
}

# Generate PM2 ecosystem configuration
generate_ecosystem_config() {
    log "INFO" "Generating PM2 ecosystem configuration..."
    
    "$SCRIPT_DIR/monitor.sh" generate-config
    
    if [[ ! -f "$ECOSYSTEM_CONFIG" ]]; then
        log "ERROR" "Failed to generate ecosystem configuration"
        return 1
    fi
    
    log "SUCCESS" "Ecosystem configuration generated: $ECOSYSTEM_CONFIG"
}

# Start PM2 ecosystem
start_pm2_ecosystem() {
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    
    log "INFO" "Starting PM2 ecosystem..."
    
    # Check if PM2 daemon is running
    if ! "$pm2_binary" status &> /dev/null; then
        log "INFO" "Starting PM2 daemon..."
    fi
    
    # Start the ecosystem
    "$pm2_binary" start "$ECOSYSTEM_CONFIG"
    
    log "SUCCESS" "PM2 ecosystem started"
    
    # Show status
    "$pm2_binary" status
}

# Wait for services to be ready
wait_for_services() {
    log "INFO" "Waiting for services to be ready..."
    
    local max_attempts=30
    local attempt=1
    local node_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.nodeBinary);")
    
    while [[ $attempt -le $max_attempts ]]; do
        log "INFO" "Waiting for services... (attempt $attempt/$max_attempts)"
        
        if "$node_binary" "$SCRIPT_DIR/port-scanner.js" --json &>/dev/null; then
            log "SUCCESS" "All services are ready"
            return 0
        fi
        
        sleep 2
        ((attempt++))
    done
    
    log "ERROR" "Services failed to start within expected time"
    return 1
}

# Start monitoring daemon
start_monitoring_daemon() {
    log "INFO" "Starting monitoring daemon..."
    
    # Check if monitoring is already running
    if pgrep -f "monitor.sh.*monitor" &>/dev/null; then
        log "WARN" "Monitoring daemon is already running"
        return 0
    fi
    
    # Start monitoring in background
    nohup "$MONITOR_SCRIPT" monitor >> "$DAEMON_LOG" 2>&1 &
    local monitor_pid=$!
    
    # Wait a moment and check if it started successfully
    sleep 2
    
    if kill -0 "$monitor_pid" 2>/dev/null; then
        log "SUCCESS" "Monitoring daemon started (PID: $monitor_pid)"
        echo "$monitor_pid" > "$LOG_DIR/.monitor_daemon.pid"
        return 0
    else
        log "ERROR" "Failed to start monitoring daemon"
        return 1
    fi
}

# Show service information
show_service_info() {
    log "INFO" "Service Information:"
    echo ""
    
    # Show configured services
    node -e "
        const config = require('$CONFIG_FILE').getCliConfig();
        config.services.forEach(service => {
            console.log(\`Service: \${service.name}\`);
            console.log(\`  Port: \${service.port}\`);
            console.log(\`  Type: \${service.type}\`);
            if (service.healthUrl) {
                console.log(\`  Health: \${service.healthUrl}\`);
            }
            console.log('');
        });
    "
    
    echo "Management Commands:"
    echo "  $SCRIPT_DIR/monitor.sh status     - Check service health"
    echo "  $SCRIPT_DIR/monitor.sh restart    - Restart failed services"  
    echo "  $SCRIPT_DIR/monitor.sh check      - Run single health check"
    echo ""
    
    local pm2_binary=$(node -e "const config = require('$CONFIG_FILE').getCliConfig(); console.log(config.system.pm2Binary);")
    echo "PM2 Commands:"
    echo "  $pm2_binary status                 - Show service status"
    echo "  $pm2_binary logs                   - Show all logs"
    echo "  $pm2_binary restart all            - Restart all services"
    echo "  $pm2_binary reload all             - Zero-downtime reload"
    echo ""
    
    echo "Log Files:"
    echo "  $LOG_DIR/                          - All log files"
    echo "  $DAEMON_LOG                        - Monitor daemon logs"
    echo ""
    
    echo "Configuration:"
    echo "  $CONFIG_FILE                       - Service monitor configuration"
    echo "  $ECOSYSTEM_CONFIG                  - PM2 ecosystem configuration"
}

# Install startup service (systemd)
install_startup_service() {
    log "INFO" "Installing systemd service for auto-startup..."
    
    local service_name="service-monitor"
    local service_file="/etc/systemd/system/${service_name}.service"
    local service_content="[Unit]
Description=Generic Service Monitor
After=network.target

[Service]
Type=simple
User=$(whoami)
WorkingDirectory=$SERVICE_MONITOR_ROOT
ExecStart=$SCRIPT_DIR/start.sh
ExecStop=$SCRIPT_DIR/stop.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target"
    
    # Create service file (requires sudo)
    if command -v sudo &> /dev/null && [[ "$EUID" -ne 0 ]]; then
        echo "$service_content" | sudo tee "$service_file" > /dev/null
        sudo systemctl daemon-reload
        sudo systemctl enable "$service_name"
        log "SUCCESS" "Systemd service installed and enabled"
        log "INFO" "Service will start automatically on boot"
        log "INFO" "Manual control: sudo systemctl {start|stop|restart|status} $service_name"
    else
        log "WARN" "Cannot install systemd service (no sudo or running as root)"
    fi
}

# Main startup routine
main() {
    local install_startup=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --install-startup)
                install_startup=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                echo "Usage: $0 [--install-startup]"
                exit 1
                ;;
        esac
    done
    
    log "INFO" "Starting Generic Service Monitor..."
    
    # Run startup sequence
    check_dependencies || exit 1
    verify_project_structure || exit 1
    create_directories
    stop_dev_processes
    generate_ecosystem_config || exit 1
    start_pm2_ecosystem || exit 1
    wait_for_services || exit 1
    start_monitoring_daemon || exit 1
    
    # Install startup service if requested
    if [[ "$install_startup" == true ]]; then
        install_startup_service
    fi
    
    show_service_info
    
    log "SUCCESS" "Service Monitor startup completed successfully!"
}

# Validate configuration
if ! node -e "require('$CONFIG_FILE').getCliConfig();" &>/dev/null; then
    echo "ERROR: Invalid configuration file: $CONFIG_FILE"
    exit 1
fi

# Run main function
main "$@"