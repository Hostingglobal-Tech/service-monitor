#!/usr/bin/env node

/**
 * Example Service Monitor Configuration for Web + API Setup
 * This is a complete example showing how to configure a typical
 * frontend + backend service setup.
 */

const path = require('path');

// Get the project root (adjust this path to your project)
const PROJECT_ROOT = process.cwd();
const SERVICE_MONITOR_ROOT = path.dirname(__dirname);

module.exports = {
  // Monitoring settings
  monitoring: {
    interval: 60000,                    // Check every 60 seconds
    consecutiveFailureThreshold: 3,     // Restart after 3 consecutive failures
    maxRestartAttempts: 5,              // Maximum restart attempts
    restartDelay: 4000,                 // 4 second delay between restarts
    healthCheckTimeout: 10000,          // 10 second timeout for health checks
    portCheckTimeout: 5000,             // 5 second timeout for port checks
  },

  // Logging configuration
  logging: {
    level: 'INFO',                      // DEBUG, INFO, WARN, ERROR
    logDir: path.join(PROJECT_ROOT, 'logs'),
    monitorLogFile: 'monitor.log',
    daemonLogFile: 'monitor-daemon.log',
    portMonitorLogFile: 'port-monitor.log',
    maxLogSizeMB: 50,
    retentionDays: 30,
    compressionEnabled: true,
  },

  // PM2 configuration
  pm2: {
    ecosystemFile: path.join(SERVICE_MONITOR_ROOT, 'config', 'ecosystem.config.js'),
    defaultMemoryLimit: '512M',
    defaultInstances: 1,
    defaultRestartDelay: 4000,
    defaultMaxRestarts: 5,
  },

  // System paths
  system: {
    pm2Binary: 'pm2',
    nodeBinary: 'node',
    pythonBinary: 'python3',
    jqBinary: 'jq',
    netstatBinary: 'netstat',
    gzipBinary: 'gzip',
  },

  // Service definitions
  services: [
    {
      name: 'my-web-app',
      type: 'nodejs',
      port: 3000,
      healthUrl: 'http://localhost:3000/health',
      
      pm2Config: {
        script: 'npm',
        args: 'start',
        cwd: './web',                   // Relative to PROJECT_ROOT
        instances: 1,
        exec_mode: 'cluster',
        max_memory_restart: '512M',
        max_restarts: 5,
        restart_delay: 4000,
        
        env: {
          NODE_ENV: 'production',
          PORT: 3000,
        },
        
        out_file: path.join(PROJECT_ROOT, 'logs', 'web-out.log'),
        error_file: path.join(PROJECT_ROOT, 'logs', 'web-error.log'),
        log_file: path.join(PROJECT_ROOT, 'logs', 'web-combined.log'),
        merge_logs: true,
        log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
      },
      
      healthCheck: {
        enabled: true,
        method: 'GET',
        timeout: 10000,
        expectedStatus: 200,
        retries: 3,
      },
      
      autoRestart: {
        enabled: true,
        onPortDown: true,
        onHealthCheckFail: true,
        onMemoryLimit: true,
        onCrash: true,
      },
    },
    
    {
      name: 'my-api-server',
      type: 'nodejs',
      port: 3001,
      healthUrl: 'http://localhost:3001/api/health',
      
      pm2Config: {
        script: 'server.js',
        args: '',
        cwd: './api',
        instances: 2,                   // Run 2 instances for load balancing
        exec_mode: 'cluster',
        max_memory_restart: '1G',
        max_restarts: 5,
        restart_delay: 4000,
        
        env: {
          NODE_ENV: 'production',
          PORT: 3001,
          DATABASE_URL: 'postgresql://localhost/myapp',
        },
        
        out_file: path.join(PROJECT_ROOT, 'logs', 'api-out.log'),
        error_file: path.join(PROJECT_ROOT, 'logs', 'api-error.log'),
        log_file: path.join(PROJECT_ROOT, 'logs', 'api-combined.log'),
        merge_logs: true,
        log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
      },
      
      healthCheck: {
        enabled: true,
        method: 'GET',
        timeout: 10000,
        expectedStatus: 200,
        retries: 3,
      },
      
      autoRestart: {
        enabled: true,
        onPortDown: true,
        onHealthCheckFail: true,
        onMemoryLimit: true,
        onCrash: true,
      },
    },
  ],

  // Notification settings (optional)
  notifications: {
    enabled: false,
    email: {
      enabled: false,
      smtp: {
        host: 'smtp.gmail.com',
        port: 587,
        secure: false,
        auth: {
          user: 'your-email@gmail.com',
          pass: 'your-app-password',
        },
      },
      to: ['admin@example.com'],
      from: 'service-monitor@example.com',
    },
    slack: {
      enabled: false,
      webhookUrl: 'https://hooks.slack.com/services/...',
      channel: '#alerts',
    },
  },
};