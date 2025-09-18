#!/bin/bash

# Generic Service Monitor Installation Script
# Sets up the service monitor system and dependencies

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_MONITOR_ROOT="$SCRIPT_DIR"

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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log "WARN" "Running as root. This is not recommended for service monitor."
        log "WARN" "Consider running as a regular user with sudo access."
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Detect operating system
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="$VERSION_ID"
    elif [[ -f /etc/redhat-release ]]; then
        OS="rhel"
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"
    else
        OS="unknown"
    fi
    
    log "INFO" "Detected OS: $OS"
}

# Install system dependencies
install_system_dependencies() {
    log "INFO" "Installing system dependencies..."
    
    case "$OS" in
        "ubuntu"|"debian")
            log "INFO" "Installing packages for Ubuntu/Debian..."
            sudo apt-get update
            sudo apt-get install -y curl jq netstat-tools gzip
            ;;
        "rhel"|"centos"|"fedora")
            log "INFO" "Installing packages for RHEL/CentOS/Fedora..."
            if command -v dnf &> /dev/null; then
                sudo dnf install -y curl jq net-tools gzip
            else
                sudo yum install -y curl jq net-tools gzip
            fi
            ;;
        "arch")
            log "INFO" "Installing packages for Arch Linux..."
            sudo pacman -S --noconfirm curl jq net-tools gzip
            ;;
        *)
            log "WARN" "Unknown OS. Please install these packages manually:"
            log "WARN" "  - curl"
            log "WARN" "  - jq"
            log "WARN" "  - net-tools (for netstat)"
            log "WARN" "  - gzip"
            ;;
    esac
    
    log "SUCCESS" "System dependencies installed"
}

# Install Node.js if not present
install_nodejs() {
    if command -v node &> /dev/null; then
        local node_version=$(node --version)
        log "INFO" "Node.js already installed: $node_version"
        
        # Check if version is recent enough (v14+)
        local major_version=$(echo "$node_version" | sed 's/v\\([0-9]*\\).*/\\1/')
        if [[ $major_version -lt 14 ]]; then
            log "WARN" "Node.js version is too old. Please upgrade to v14 or newer."
            return 1
        fi
        
        return 0
    fi
    
    log "INFO" "Installing Node.js via NodeSource repository..."
    
    case "$OS" in
        "ubuntu"|"debian")
            curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
            sudo apt-get install -y nodejs
            ;;
        "rhel"|"centos"|"fedora")
            curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
            if command -v dnf &> /dev/null; then
                sudo dnf install -y nodejs npm
            else
                sudo yum install -y nodejs npm
            fi
            ;;
        *)
            log "ERROR" "Please install Node.js manually from https://nodejs.org/"
            return 1
            ;;
    esac
    
    log "SUCCESS" "Node.js installed successfully"
}

# Install PM2 globally
install_pm2() {
    if command -v pm2 &> /dev/null; then
        local pm2_version=$(pm2 --version)
        log "INFO" "PM2 already installed: $pm2_version"
        return 0
    fi
    
    log "INFO" "Installing PM2 globally..."
    
    if command -v npm &> /dev/null; then
        sudo npm install -g pm2
        log "SUCCESS" "PM2 installed successfully"
    else
        log "ERROR" "npm not found. Please install Node.js first."
        return 1
    fi
}

# Set up PM2 startup script
setup_pm2_startup() {
    log "INFO" "Setting up PM2 startup script..."
    
    if command -v pm2 &> /dev/null && command -v systemctl &> /dev/null; then
        # Generate startup script
        local startup_script=$(pm2 startup systemd -u "$(whoami)" --hp "$(eval echo ~$(whoami))" | tail -1)
        
        if [[ "$startup_script" =~ ^sudo ]]; then
            log "INFO" "Executing PM2 startup configuration..."
            eval "$startup_script"
            log "SUCCESS" "PM2 startup script configured"
        else
            log "WARN" "Could not configure PM2 startup script automatically"
        fi
    else
        log "WARN" "PM2 or systemctl not available, skipping startup script setup"
    fi
}

# Create directory structure
create_directories() {
    log "INFO" "Creating directory structure..."
    
    local dirs=(
        "$SERVICE_MONITOR_ROOT/logs"
        "$SERVICE_MONITOR_ROOT/config"
        "$SERVICE_MONITOR_ROOT/templates/systemd"
        "$SERVICE_MONITOR_ROOT/examples"
    )
    
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log "INFO" "Created directory: $dir"
        fi
    done
    
    log "SUCCESS" "Directory structure created"
}

# Set up executable permissions
set_permissions() {
    log "INFO" "Setting up executable permissions..."
    
    local executables=(
        "$SERVICE_MONITOR_ROOT/bin/monitor.sh"
        "$SERVICE_MONITOR_ROOT/bin/start.sh"
        "$SERVICE_MONITOR_ROOT/bin/stop.sh"
        "$SERVICE_MONITOR_ROOT/bin/logrotate.sh"
        "$SERVICE_MONITOR_ROOT/bin/port-scanner.js"
        "$SERVICE_MONITOR_ROOT/config/service-monitor.config.js"
    )
    
    for file in "${executables[@]}"; do
        if [[ -f "$file" ]]; then
            chmod +x "$file"
            log "INFO" "Made executable: $file"
        else
            log "WARN" "File not found: $file"
        fi
    done
    
    log "SUCCESS" "Permissions set"
}

# Create systemd service template
create_systemd_template() {
    log "INFO" "Creating systemd service template..."
    
    local template_file="$SERVICE_MONITOR_ROOT/templates/systemd/service-monitor.service"
    
    cat > "$template_file" << 'EOF'
[Unit]
Description=Generic Service Monitor
After=network.target

[Service]
Type=simple
User=USER_PLACEHOLDER
Group=GROUP_PLACEHOLDER
WorkingDirectory=WORKDIR_PLACEHOLDER
ExecStart=WORKDIR_PLACEHOLDER/bin/start.sh
ExecStop=WORKDIR_PLACEHOLDER/bin/stop.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Environment
Environment=NODE_ENV=production
Environment=SERVICE_MONITOR_CONFIG=WORKDIR_PLACEHOLDER/config/service-monitor.config.js

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=WORKDIR_PLACEHOLDER/logs

[Install]
WantedBy=multi-user.target
EOF
    
    log "SUCCESS" "Systemd service template created: $template_file"
}

# Install systemd service
install_systemd_service() {
    log "INFO" "Installing systemd service..."
    
    local template_file="$SERVICE_MONITOR_ROOT/templates/systemd/service-monitor.service"
    local service_file="/etc/systemd/system/service-monitor.service"
    
    if [[ ! -f "$template_file" ]]; then
        log "ERROR" "Template file not found: $template_file"
        return 1
    fi
    
    # Replace placeholders
    local service_content
    service_content=$(cat "$template_file")
    service_content=${service_content//USER_PLACEHOLDER/$(whoami)}
    service_content=${service_content//GROUP_PLACEHOLDER/$(id -gn)}
    service_content=${service_content//WORKDIR_PLACEHOLDER/$SERVICE_MONITOR_ROOT}
    
    # Install service file
    echo "$service_content" | sudo tee "$service_file" > /dev/null
    
    # Reload systemd
    sudo systemctl daemon-reload
    
    log "SUCCESS" "Systemd service installed: $service_file"
    log "INFO" "To enable auto-start: sudo systemctl enable service-monitor"
    log "INFO" "To start service: sudo systemctl start service-monitor"
}

# Create sample configuration
create_sample_config() {
    log "INFO" "Creating sample configuration..."
    
    local config_file="$SERVICE_MONITOR_ROOT/config/service-monitor.config.js"
    
    if [[ -f "$config_file" ]]; then
        log "INFO" "Configuration already exists: $config_file"
        return 0
    fi
    
    # Copy example configuration
    if [[ -f "$SERVICE_MONITOR_ROOT/examples/example-web-api.config.js" ]]; then
        cp "$SERVICE_MONITOR_ROOT/examples/example-web-api.config.js" "$config_file"
        log "SUCCESS" "Sample configuration created: $config_file"
        log "INFO" "Please edit this file to configure your services"
    else
        log "WARN" "Example configuration not found"
    fi
}

# Test installation
test_installation() {
    log "INFO" "Testing installation..."
    
    local errors=()
    
    # Test Node.js
    if ! command -v node &> /dev/null; then
        errors+=("Node.js not found")
    fi
    
    # Test PM2
    if ! command -v pm2 &> /dev/null; then
        errors+=("PM2 not found")
    fi
    
    # Test jq
    if ! command -v jq &> /dev/null; then
        errors+=("jq not found")
    fi
    
    # Test configuration
    local config_file="$SERVICE_MONITOR_ROOT/config/service-monitor.config.js"
    if [[ -f "$config_file" ]]; then
        if ! node -e "require('$config_file').getCliConfig();" &>/dev/null; then
            errors+=("Configuration file is invalid")
        fi
    else
        errors+=("Configuration file not found")
    fi
    
    # Test scripts
    local scripts=(
        "$SERVICE_MONITOR_ROOT/bin/monitor.sh"
        "$SERVICE_MONITOR_ROOT/bin/port-scanner.js"
    )
    
    for script in "${scripts[@]}"; do
        if [[ ! -x "$script" ]]; then
            errors+=("Script not executable: $script")
        fi
    done
    
    if [[ ${#errors[@]} -eq 0 ]]; then
        log "SUCCESS" "Installation test passed"
        return 0
    else
        log "ERROR" "Installation test failed:"
        for error in "${errors[@]}"; do
            log "ERROR" "  - $error"
        done
        return 1
    fi
}

# Show usage information
show_usage() {
    echo "Generic Service Monitor Installation"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help              Show this help message"
    echo "  --skip-deps         Skip system dependency installation"
    echo "  --skip-nodejs       Skip Node.js installation"
    echo "  --skip-pm2          Skip PM2 installation"
    echo "  --skip-systemd      Skip systemd service installation"
    echo "  --config-only       Only create sample configuration"
    echo ""
    echo "Examples:"
    echo "  $0                  Full installation"
    echo "  $0 --skip-deps      Install without system dependencies"
    echo "  $0 --config-only    Create sample configuration only"
}

# Main installation routine
main() {
    local skip_deps=false
    local skip_nodejs=false
    local skip_pm2=false
    local skip_systemd=false
    local config_only=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help)
                show_usage
                exit 0
                ;;
            --skip-deps)
                skip_deps=true
                shift
                ;;
            --skip-nodejs)
                skip_nodejs=true
                shift
                ;;
            --skip-pm2)
                skip_pm2=true
                shift
                ;;
            --skip-systemd)
                skip_systemd=true
                shift
                ;;
            --config-only)
                config_only=true
                shift
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    log "INFO" "Starting Generic Service Monitor installation..."
    log "INFO" "Installation directory: $SERVICE_MONITOR_ROOT"
    
    # Configuration-only mode
    if [[ "$config_only" == true ]]; then
        create_directories
        create_sample_config
        log "SUCCESS" "Configuration setup completed!"
        exit 0
    fi
    
    # Full installation
    check_root
    detect_os
    
    if [[ "$skip_deps" != true ]]; then
        install_system_dependencies || log "WARN" "System dependency installation failed"
    fi
    
    if [[ "$skip_nodejs" != true ]]; then
        install_nodejs || { log "ERROR" "Node.js installation failed"; exit 1; }
    fi
    
    if [[ "$skip_pm2" != true ]]; then
        install_pm2 || { log "ERROR" "PM2 installation failed"; exit 1; }
        setup_pm2_startup || log "WARN" "PM2 startup setup failed"
    fi
    
    create_directories
    set_permissions
    create_systemd_template
    
    if [[ "$skip_systemd" != true ]] && command -v systemctl &> /dev/null; then
        install_systemd_service || log "WARN" "Systemd service installation failed"
    fi
    
    create_sample_config
    
    # Test installation
    if test_installation; then
        log "SUCCESS" "Installation completed successfully!"
        echo ""
        echo "Next steps:"
        echo "1. Edit the configuration file: $SERVICE_MONITOR_ROOT/config/service-monitor.config.js"
        echo "2. Test the configuration: $SERVICE_MONITOR_ROOT/bin/monitor.sh check"
        echo "3. Start the service monitor: $SERVICE_MONITOR_ROOT/bin/start.sh"
        echo ""
        echo "For systemd integration:"
        echo "  sudo systemctl enable service-monitor"
        echo "  sudo systemctl start service-monitor"
    else
        log "ERROR" "Installation completed with errors. Please check the issues above."
        exit 1
    fi
}

# Run main function
main "$@"