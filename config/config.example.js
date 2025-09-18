#!/usr/bin/env node

/**
 * Service Monitor Configuration Example
 * Generic monitoring system for Node.js/Python processes
 */

const path = require('path');
const os = require('os');

// Base directory for the service monitor
const SERVICE_MONITOR_ROOT = path.dirname(__dirname);

// Default configuration
const DEFAULT_CONFIG = {
  // Monitoring settings
  monitoring: {
    interval: 60000,                    // Check interval in milliseconds (60 seconds)
    consecutiveFailureThreshold: 3,     // Number of consecutive failures before restart
    maxRestartAttempts: 5,              // Maximum restart attempts per service
    restartDelay: 4000,                 // Delay between restarts in milliseconds
    healthCheckTimeout: 10000,          // HTTP health check timeout in milliseconds
    portCheckTimeout: 5000,             // Port connectivity timeout in milliseconds
  },

  // Logging configuration
  logging: {
    level: 'INFO',                      // DEBUG, INFO, WARN, ERROR
    logDir: path.join(SERVICE_MONITOR_ROOT, 'logs'),
    monitorLogFile: 'monitor.log',
    daemonLogFile: 'monitor-daemon.log',
    portMonitorLogFile: 'port-monitor.log',
    maxLogSizeMB: 50,                   // Max log file size before rotation
    retentionDays: 30,                  // Log retention period
    compressionEnabled: true,           // Enable log compression
  },

  // PM2 configuration
  pm2: {
    ecosystemFile: path.join(SERVICE_MONITOR_ROOT, 'config', 'ecosystem.config.js'),
    defaultMemoryLimit: '512M',
    defaultInstances: 1,
    defaultRestartDelay: 4000,
    defaultMaxRestarts: 5,
  },

  // System paths and dependencies
  system: {
    pm2Binary: 'pm2',                   // PM2 command path
    nodeBinary: 'node',                 // Node.js binary path
    pythonBinary: 'python3',            // Python binary path
    jqBinary: 'jq',                     // jq command for JSON parsing
    netstatBinary: 'netstat',           // netstat command for port checking
    gzipBinary: 'gzip',                 // gzip for log compression
  },

  // Service definitions - configure your services here
  services: [
    {
      name: 'my-web-app',
      type: 'nodejs',
      port: 3000,
      healthUrl: 'http://localhost:3000/health',
      pm2Config: {
        script: 'npm',
        args: 'start',
        cwd: '/path/to/your/web-app',
        instances: 1,
        exec_mode: 'fork',
        max_memory_restart: '512M',
        max_restarts: 5,
        restart_delay: 4000,
        env: {
          NODE_ENV: 'production',
          PORT: 3000,
        },
        out_file: '/path/to/logs/web-out.log',
        error_file: '/path/to/logs/web-error.log',
        log_file: '/path/to/logs/web-combined.log',
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
      type: 'python',
      port: 8000,
      healthUrl: 'http://localhost:8000/health',
      pm2Config: {
        script: 'python3',
        args: 'app.py',
        cwd: '/path/to/your/api',
        instances: 1,
        exec_mode: 'fork',
        max_memory_restart: '512M',
        max_restarts: 5,
        restart_delay: 4000,
        env: {
          PYTHONPATH: '/path/to/your/api',
          PORT: 8000,
        },
        out_file: '/path/to/logs/api-out.log',
        error_file: '/path/to/logs/api-error.log',
        log_file: '/path/to/logs/api-combined.log',
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
};

/**
 * Load configuration from file or use defaults
 */
function loadConfig(configPath = null) {
  let config = { ...DEFAULT_CONFIG };

  if (configPath && require('fs').existsSync(configPath)) {
    try {
      const userConfig = require(configPath);
      config = mergeDeep(config, userConfig);
    } catch (error) {
      console.error(`Error loading config from ${configPath}:`, error.message);
      process.exit(1);
    }
  }

  // Validate configuration
  validateConfig(config);

  return config;
}

/**
 * Deep merge two objects
 */
function mergeDeep(target, source) {
  const output = { ...target };

  if (isObject(target) && isObject(source)) {
    Object.keys(source).forEach(key => {
      if (isObject(source[key])) {
        if (!(key in target)) {
          Object.assign(output, { [key]: source[key] });
        } else {
          output[key] = mergeDeep(target[key], source[key]);
        }
      } else {
        Object.assign(output, { [key]: source[key] });
      }
    });
  }

  return output;
}

/**
 * Check if value is an object
 */
function isObject(item) {
  return item && typeof item === 'object' && !Array.isArray(item);
}

/**
 * Validate configuration
 */
function validateConfig(config) {
  const errors = [];

  // Validate services
  if (!config.services || !Array.isArray(config.services) || config.services.length === 0) {
    errors.push('At least one service must be configured');
  } else {
    const serviceNames = new Set();
    const servicePorts = new Set();

    config.services.forEach((service, index) => {
      const prefix = `services[${index}]`;

      // Check required fields
      if (!service.name) errors.push(`${prefix}.name is required`);
      if (!service.port || !Number.isInteger(service.port)) errors.push(`${prefix}.port must be a valid integer`);
      if (!service.type) errors.push(`${prefix}.type is required`);

      // Check for duplicates
      if (service.name && serviceNames.has(service.name)) {
        errors.push(`${prefix}.name '${service.name}' is duplicated`);
      } else if (service.name) {
        serviceNames.add(service.name);
      }

      if (service.port && servicePorts.has(service.port)) {
        errors.push(`${prefix}.port ${service.port} is duplicated`);
      } else if (service.port) {
        servicePorts.add(service.port);
      }

      // Validate port range
      if (service.port && (service.port < 1 || service.port > 65535)) {
        errors.push(`${prefix}.port must be between 1 and 65535`);
      }

      // Validate health URL
      if (service.healthUrl && !service.healthUrl.startsWith('http')) {
        errors.push(`${prefix}.healthUrl must start with http:// or https://`);
      }

      // Validate PM2 config
      if (!service.pm2Config || !service.pm2Config.script) {
        errors.push(`${prefix}.pm2Config.script is required`);
      }
    });
  }

  // Validate monitoring settings
  if (config.monitoring.interval < 1000) {
    errors.push('monitoring.interval must be at least 1000ms');
  }

  if (config.monitoring.consecutiveFailureThreshold < 1) {
    errors.push('monitoring.consecutiveFailureThreshold must be at least 1');
  }

  if (config.monitoring.maxRestartAttempts < 1) {
    errors.push('monitoring.maxRestartAttempts must be at least 1');
  }

  if (errors.length > 0) {
    console.error('Configuration validation errors:');
    errors.forEach(error => console.error(`  - ${error}`));
    process.exit(1);
  }
}

/**
 * Generate PM2 ecosystem configuration
 */
function generateEcosystemConfig(config) {
  const apps = config.services.map(service => ({
    name: service.name,
    ...service.pm2Config,
  }));

  return {
    apps,
  };
}

/**
 * Get configuration for CLI usage
 */
function getCliConfig() {
  const configPath = process.env.SERVICE_MONITOR_CONFIG ||
    path.join(SERVICE_MONITOR_ROOT, 'config', 'service-monitor.config.js');

  return loadConfig(configPath);
}

module.exports = {
  DEFAULT_CONFIG,
  loadConfig,
  validateConfig,
  generateEcosystemConfig,
  getCliConfig,
  SERVICE_MONITOR_ROOT,
};

// If run directly, output config as JSON
if (require.main === module) {
  const config = getCliConfig();
  console.log(JSON.stringify(config, null, 2));
}