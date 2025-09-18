#!/usr/bin/env node

/**
 * Generic Port and Health Monitor for Service Monitor
 * Monitors both port connectivity and application health endpoints
 * Uses configuration from service-monitor.config.js
 */

const net = require('net');
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

// Load configuration
const { getCliConfig } = require('../config/service-monitor.config.js');
const config = getCliConfig();

// Logging utility
function log(message, level = 'INFO') {
  const timestamp = new Date().toISOString();
  const logEntry = `[${timestamp}] [${level}] ${message}\n`;
  
  // Console output
  if (level !== 'DEBUG' || config.logging.level === 'DEBUG') {
    console.log(logEntry.trim());
  }
  
  // File logging
  const logFile = path.join(config.logging.logDir, config.logging.portMonitorLogFile);
  
  // Ensure logs directory exists
  if (!fs.existsSync(config.logging.logDir)) {
    fs.mkdirSync(config.logging.logDir, { recursive: true });
  }
  
  fs.appendFileSync(logFile, logEntry);
}

// Check if port is open
function checkPort(host, port, timeout = 3000) {
  return new Promise((resolve) => {
    const socket = new net.Socket();
    let resolved = false;
    
    const cleanup = () => {
      if (!resolved) {
        resolved = true;
        socket.destroy();
      }
    };
    
    socket.setTimeout(timeout);
    
    socket.on('connect', () => {
      cleanup();
      resolve({ success: true, error: null });
    });
    
    socket.on('timeout', () => {
      cleanup();
      resolve({ success: false, error: 'timeout' });
    });
    
    socket.on('error', (err) => {
      cleanup();
      resolve({ success: false, error: err.message });
    });
    
    socket.connect(port, host);
  });
}

// Check health endpoint
function checkHealth(url, method = 'GET', timeout = 5000, expectedStatus = 200) {
  return new Promise((resolve) => {
    const urlObj = new URL(url);
    const isHttps = urlObj.protocol === 'https:';
    const httpModule = isHttps ? https : http;
    
    const options = {
      hostname: urlObj.hostname,
      port: urlObj.port || (isHttps ? 443 : 80),
      path: urlObj.pathname + urlObj.search,
      method: method,
      timeout: timeout,
      headers: {
        'User-Agent': 'Service-Monitor/1.0',
        'Accept': 'application/json, text/plain, */*'
      }
    };
    
    // For HTTPS, ignore self-signed certificates in development
    if (isHttps) {
      options.rejectUnauthorized = false;
    }
    
    const req = httpModule.request(options, (res) => {
      let data = '';
      
      res.on('data', (chunk) => {
        data += chunk;
      });
      
      res.on('end', () => {
        let parsedData = null;
        let parseError = null;
        
        // Try to parse JSON response
        if (data.trim()) {
          try {
            parsedData = JSON.parse(data);
          } catch (e) {
            parseError = 'Invalid JSON response';
            parsedData = data; // Store raw data if JSON parsing fails
          }
        }
        
        const isSuccess = res.statusCode === expectedStatus;
        
        resolve({
          success: isSuccess,
          status: res.statusCode,
          data: parsedData,
          error: parseError,
          responseTime: Date.now() - startTime
        });
      });
    });
    
    const startTime = Date.now();
    
    req.on('timeout', () => {
      req.destroy();
      resolve({ 
        success: false, 
        status: null, 
        data: null, 
        error: 'timeout',
        responseTime: timeout
      });
    });
    
    req.on('error', (err) => {
      resolve({ 
        success: false, 
        status: null, 
        data: null, 
        error: err.message,
        responseTime: Date.now() - startTime
      });
    });
    
    req.end();
  });
}

// Check individual service
async function checkService(service) {
  const result = {
    name: service.name,
    port: service.port,
    timestamp: new Date().toISOString(),
    portCheck: null,
    healthCheck: null,
    overall: 'unknown',
    details: {}
  };
  
  // Check port connectivity
  log(`Checking port ${service.port} for ${service.name}...`);
  const portTimeout = service.healthCheck?.timeout || config.monitoring.portCheckTimeout;
  result.portCheck = await checkPort('localhost', service.port, portTimeout);
  
  if (result.portCheck.success) {
    log(`✓ Port ${service.port} is open for ${service.name}`);
    
    // Check health endpoint if configured
    if (service.healthCheck?.enabled && service.healthUrl) {
      log(`Checking health endpoint for ${service.name}...`);
      
      const healthTimeout = service.healthCheck.timeout || config.monitoring.healthCheckTimeout;
      const method = service.healthCheck.method || 'GET';
      const expectedStatus = service.healthCheck.expectedStatus || 200;
      
      result.healthCheck = await checkHealth(service.healthUrl, method, healthTimeout, expectedStatus);
      
      if (result.healthCheck.success) {
        log(`✓ Health check passed for ${service.name} (${result.healthCheck.responseTime}ms)`);
        result.overall = 'healthy';
        
        // Extract useful information from health data
        if (result.healthCheck.data && typeof result.healthCheck.data === 'object') {
          const healthData = result.healthCheck.data;
          
          // Memory information
          if (healthData.memory) {
            result.details.memory = {
              used: healthData.memory.used || healthData.memory.usage,
              total: healthData.memory.total,
              percent: healthData.memory.percent || healthData.memory.percentage
            };
          }
          
          // System information
          if (healthData.system) {
            result.details.system = {
              cpu: healthData.system.cpu_percent || healthData.system.cpu,
              memory: healthData.system.memory_used_percent || healthData.system.memory_percent,
              disk: healthData.system.disk_used_percent || healthData.system.disk_percent,
              uptime: healthData.system.uptime
            };
          }
          
          // Application status
          if (healthData.status) {
            result.details.status = healthData.status;
          }
          
          // Version information
          if (healthData.version) {
            result.details.version = healthData.version;
          }
        }
      } else {
        log(`✗ Health check failed for ${service.name}: ${result.healthCheck.error} (status: ${result.healthCheck.status})`, 'WARN');
        result.overall = 'unhealthy';
      }
    } else {
      // No health check configured, consider healthy if port is open
      log(`Port check only for ${service.name} (no health endpoint configured)`);
      result.overall = 'healthy';
    }
  } else {
    log(`✗ Port ${service.port} is not accessible for ${service.name}: ${result.portCheck.error}`, 'ERROR');
    result.overall = 'down';
  }
  
  return result;
}

// Check all services
async function checkAllServices() {
  log('Starting comprehensive service check...');
  
  const results = [];
  
  // Check services in parallel for better performance
  const serviceChecks = config.services.map(service => checkService(service));
  const serviceResults = await Promise.all(serviceChecks);
  
  results.push(...serviceResults);
  
  return results;
}

// Generate summary report
function generateReport(results) {
  const summary = {
    timestamp: new Date().toISOString(),
    total: results.length,
    healthy: results.filter(r => r.overall === 'healthy').length,
    unhealthy: results.filter(r => r.overall === 'unhealthy').length,
    down: results.filter(r => r.overall === 'down').length,
    services: results
  };
  
  log(`\n=== SERVICE HEALTH SUMMARY ===`);
  log(`Total Services: ${summary.total}`);
  log(`Healthy: ${summary.healthy}`);
  log(`Unhealthy: ${summary.unhealthy}`);
  log(`Down: ${summary.down}`);
  log(`================================`);
  
  // Log individual service status
  results.forEach(result => {
    const status = result.overall.toUpperCase();
    const statusIcon = result.overall === 'healthy' ? '✓' : '✗';
    log(`${statusIcon} ${result.name} (port ${result.port}): ${status}`);
    
    // Log additional details if available
    if (result.details.memory) {
      const mem = result.details.memory;
      const memStr = mem.percent ? `${mem.percent}%` : 
                    (mem.used && mem.total) ? `${mem.used}MB/${mem.total}MB` :
                    mem.used ? `${mem.used}MB` : 'N/A';
      log(`  Memory: ${memStr}`);
    }
    
    if (result.details.system) {
      const sys = result.details.system;
      const sysInfo = [];
      if (sys.memory) sysInfo.push(`${sys.memory}% memory`);
      if (sys.cpu) sysInfo.push(`${sys.cpu}% CPU`);
      if (sys.disk) sysInfo.push(`${sys.disk}% disk`);
      if (sysInfo.length > 0) {
        log(`  System: ${sysInfo.join(', ')}`);
      }
    }
    
    if (result.healthCheck && result.healthCheck.responseTime) {
      log(`  Response time: ${result.healthCheck.responseTime}ms`);
    }
  });
  
  return summary;
}

// Main execution
async function main() {
  try {
    log(`Service Monitor Health Check - Monitoring ${config.services.length} services`);
    
    const results = await checkAllServices();
    const summary = generateReport(results);
    
    // Output JSON for programmatic use
    if (process.argv.includes('--json')) {
      console.log(JSON.stringify(summary, null, 2));
    }
    
    // Exit with appropriate code
    const hasDown = summary.down > 0;
    const hasUnhealthy = summary.unhealthy > 0;
    
    if (hasDown) {
      log('Services are DOWN - exiting with code 2', 'ERROR');
      process.exit(2);
    } else if (hasUnhealthy) {
      log('Services are UNHEALTHY - exiting with code 1', 'WARN');
      process.exit(1);
    } else {
      log('All services are HEALTHY - exiting with code 0');
      process.exit(0);
    }
    
  } catch (error) {
    log(`FATAL ERROR: ${error.message}`, 'ERROR');
    console.error(error.stack);
    process.exit(3);
  }
}

// Export functions for use as module
module.exports = { 
  checkService, 
  checkAllServices, 
  checkPort, 
  checkHealth,
  generateReport,
  log
};

// Handle command line execution
if (require.main === module) {
  main();
}