# Service Monitor

A lightweight, configuration-driven service monitoring and auto-restart system for Node.js and Python applications using PM2.

## ✨ Features

- **Multi-Service Monitoring**: Monitor Node.js, Python, and custom applications
- **Health Checks**: Port connectivity + HTTP endpoint monitoring
- **Auto-Restart**: Intelligent failure detection and automatic recovery
- **PM2 Integration**: Leverages PM2 for robust process management
- **Configurable**: JSON-based configuration with validation
- **Logging**: Structured logging with rotation

## 🚀 Quick Start

### 1. Prerequisites

- Node.js (v14+)
- PM2 (`npm install -g pm2`)
- System tools: `jq`, `netstat`, `gzip`

### 2. Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/service-monitor.git
cd service-monitor

# Run installation
chmod +x install.sh
./install.sh
```

### 3. Configuration

Copy the example config:
```bash
cp config/config.example.js config/service-monitor.config.js
```

Edit `config/service-monitor.config.js` to configure your services:

```javascript
services: [
  {
    name: 'my-web-app',
    type: 'nodejs',
    port: 3000,
    healthUrl: 'http://localhost:3000/health',
    pm2Config: {
      script: 'npm',
      args: 'start',
      cwd: '/path/to/your/app',
      instances: 1,
      max_memory_restart: '512M',
    },
    healthCheck: {
      enabled: true,
      timeout: 10000,
      expectedStatus: 200,
    },
    autoRestart: {
      enabled: true,
      onPortDown: true,
      onHealthCheckFail: true,
    },
  }
]
```

### 4. Start Monitoring

```bash
# Start all services and monitoring
./bin/start.sh

# Check status
./bin/monitor.sh status

# View logs
pm2 logs
```

## 📋 Commands

```bash
# Service management
./bin/start.sh              # Start all services and monitoring
./bin/stop.sh               # Stop all services
./bin/monitor.sh status     # Check service health
./bin/monitor.sh check      # Run single health check
./bin/monitor.sh restart    # Restart services

# Log management
./bin/logrotate.sh status   # Check log status
./bin/logrotate.sh rotate   # Rotate logs
```

## ⚙️ Configuration Options

### Service Types
- `nodejs` - Node.js applications
- `python` - Python applications
- `custom` - Custom executables

### Health Check Options
```javascript
healthCheck: {
  enabled: true,
  method: 'GET',           // HTTP method
  timeout: 10000,          // Request timeout (ms)
  expectedStatus: 200,     // Expected HTTP status
  retries: 3,              // Number of retries
}
```

### Auto-Restart Settings
```javascript
autoRestart: {
  enabled: true,
  onPortDown: true,        // Restart if port unreachable
  onHealthCheckFail: true, // Restart if health check fails
  onMemoryLimit: true,     // Restart if memory limit exceeded
  onCrash: true,           // Restart if process crashes
}
```

### Monitoring Settings
```javascript
monitoring: {
  interval: 60000,                   // Check interval (ms)
  consecutiveFailureThreshold: 3,    // Failures before restart
  maxRestartAttempts: 5,             // Max restart attempts
  restartDelay: 4000,                // Delay between restarts (ms)
}
```

## 📁 Project Structure

```
service_monitor/
├── bin/                    # Executable scripts
│   ├── monitor.sh         # Main monitoring daemon
│   ├── start.sh           # Service startup
│   ├── stop.sh            # Service shutdown
│   └── logrotate.sh       # Log management
├── config/                # Configuration files
│   ├── config.example.js  # Example configuration
│   └── *.config.js        # Your configurations
├── examples/              # Example configurations
├── templates/             # Template files
└── logs/                  # Log files (created at runtime)
```

## 🔧 Systemd Integration

Install as a system service:

```bash
# Copy service file
sudo cp templates/systemd/service-monitor.service /etc/systemd/system/

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable service-monitor
sudo systemctl start service-monitor

# Check status
sudo systemctl status service-monitor
```

## 🐛 Troubleshooting

### Services not starting
```bash
pm2 status                    # Check PM2 status
pm2 logs service-name         # Check service logs
node config/config.example.js # Validate configuration
```

### Health checks failing
```bash
curl -v http://localhost:3000/health  # Test endpoint manually
telnet localhost 3000                 # Test port connectivity
./bin/monitor.sh check                # Run manual health check
```

### Monitoring not working
```bash
ps aux | grep monitor.sh      # Check monitor process
tail -f logs/monitor.log      # Check monitor logs
./bin/stop.sh && ./bin/start.sh # Restart monitoring
```

## 📊 Log Files

- `logs/monitor.log` - Main monitoring activity
- `logs/monitor-daemon.log` - Background daemon
- `logs/port-monitor.log` - Health check details
- `logs/[service]-*.log` - Service-specific logs

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

MIT License - see LICENSE file for details.

---

**Note**: This service monitor is designed to be lightweight and reliable for production environments.