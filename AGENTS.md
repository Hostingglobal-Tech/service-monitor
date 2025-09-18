# Repository Guidelines

## Project Structure & Module Organization
- `bin/` — operational scripts: `start.sh`, `stop.sh`, `monitor.sh`, `logrotate.sh`, `port-scanner.js`.
- `config/` — main config `service-monitor.config.js` (generates `config/ecosystem.config.js`).
- `examples/` — ready-to-copy configs for Node/Python stacks.
- `logs/` — created at runtime; contains monitor and service logs.
- `install.sh` — one-time setup for deps, PM2, systemd template.
- `README.md` — feature overview and usage.

## Build, Test, and Development Commands
- Install/setup: `chmod +x install.sh && ./install.sh [--config-only]`
- Run locally: `./bin/start.sh` (add `--install-startup` to register systemd)
- Monitor actions: `./bin/monitor.sh {monitor|check|status|restart [name]|reset|generate-config}`
- Stop/cleanup: `./bin/stop.sh [--cleanup|--kill-daemon]`
- Logs/utilities: `./bin/logrotate.sh {status|rotate|install-cron}`; live logs: `pm2 logs`
- Config validate/print: `node config/service-monitor.config.js`

## Coding Style & Naming Conventions
- JavaScript (Node 14+): CommonJS modules, `const`/`let`, single quotes, semicolons, lowerCamelCase functions. Keep files kebab-case (e.g., `port-scanner.js`).
- Bash: use bash with `set -euo pipefail`; lower_snake_case functions; 2-space indentation.
- Config objects: prefer explicit keys, avoid magic defaults; keep service names unique and ports valid.

## Testing Guidelines
- No formal test suite; validate via runtime checks:
  - Config parse: `node -e "require('./config/service-monitor.config.js').getCliConfig();"`
  - Health check: `./bin/monitor.sh check` or `node ./bin/port-scanner.js --json`
  - Process state: `pm2 status`
- Example configs live in `examples/*.config.js`; mirror naming `my-thing.config.js` for new samples.

## Commit & Pull Request Guidelines
- Commits: concise subject (≤72 chars), imperative mood, include scope when helpful; emojis are acceptable; English or Korean OK. Provide a brief body with rationale and user impact.
- PRs: include summary, linked issues, commands run (start/stop/monitor/logrotate), relevant logs/screenshots, and config snippets (before/after). Note risks, rollback steps, and system info (OS, Node, PM2).

## Security & Configuration Tips
- Do not commit secrets; use environment variables. `SERVICE_MONITOR_CONFIG` can override the config path.
- Verify required tools are installed (Node, PM2, jq optional). Avoid adding sudo in scripts unless necessary.
- Keep logs under `logs/`; use `./bin/logrotate.sh install-cron` for rotation. Ensure file/dir permissions are appropriate for the run user.

