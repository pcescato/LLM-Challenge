# VPS Manager — Implementation Plan

## 1. Project Structure

```
vps-manager/
├── config/
│   └── vps-manager.conf          # Central configuration file (all constants)
├── scripts/
│   ├── bootstrap.sh               # Initial server setup
│   ├── site-create.sh             # Provision new site
│   ├── site-delete.sh             # Remove site + backup
│   ├── site-list.sh               # List all sites
│   ├── database-create.sh          # Add database to existing site
│   ├── backup.sh                  # Backup site(s)
│   ├── restore.sh                 # Restore from backup
│   ├── deploy-static.sh            # Rsync static files to webroot
│   ├── service-control.sh          # Start/stop/restart services
│   ├── service-status.sh           # Check service status
│   └── helpers/
│       ├── common.sh              # Logging, errors, utilities
│       ├── ssl.sh                 # Caddy SSL helpers
│       ├── php.sh                 # PHP-FPM helpers
│       ├── database.sh            # MariaDB/PostgreSQL helpers
│       ├── user.sh                # System user creation
│       └── validation.sh          # Input validation
├── api/
│   ├── main.py                    # FastAPI application
│   ├── auth.py                    # Bearer token auth
│   ├── routes/
│   │   ├── sites.py               # Site operations
│   │   ├── databases.py           # Database operations
│   │   ├── backups.py             # Backup operations
│   │   ├── services.py            # Service management
│   │   └── deploy.py              # Static deployment
│   ├── schemas.py                 # Pydantic models
│   ├── executor.py                # Script execution wrapper
│   └── requirements.txt
├── systemd/
│   └── vps-manager-api.service    # API daemon configuration
├── logs/
│   └── .gitkeep                   # Log directory
├── backups/
│   └── .gitkeep                   # Backup storage
├── docs/
│   ├── README.md
│   ├── API.md                     # API documentation
│   ├── QUICKSTART.md              # Getting started
│   └── TROUBLESHOOTING.md
├── tests/
│   ├── test_bootstrap.sh
│   ├── test_site_operations.sh
│   └── test_api.py
└── .env.example                   # Environment variables template
```

---

## 2. Central Configuration File (`config/vps-manager.conf`)

```bash
# Server basics
SERVER_HOSTNAME="vps.example.com"
ADMIN_EMAIL="admin@example.com"

# Paths
WEBROOT_BASE="/var/www"
BACKUP_DIR="/var/backups/vps-manager"
LOG_DIR="/var/log/vps-manager"
CONFIG_DIR="/etc/vps-manager"

# Backup retention
BACKUP_RETENTION_DAYS=30
BACKUP_COMPRESS=true

# PHP versions
PHP_PRIMARY_VERSION="8.3"
PHP_FALLBACK_VERSION="8.2"

# MariaDB
MARIADB_PORT=3306
MARIADB_SOCKET="/run/mysqld/mysqld.sock"

# PostgreSQL
POSTGRESQL_PORT=5432
POSTGRESQL_SOCKET="/run/postgresql"

# Valkey
VALKEY_PORT=6379
VALKEY_SOCKET="/run/valkey/valkey.sock"

# Caddy
CADDY_CONFIG_DIR="/etc/caddy"
CADDY_LOG_DIR="/var/log/caddy"

# API configuration
API_HOST="127.0.0.1"
API_PORT=8000
API_LOG_LEVEL="info"

# SFTP chroot base
SFTP_ROOT="/srv/sftp"

# Permissions
WEBROOT_USER="www-data"
WEBROOT_GROUP="www-data"
WEBROOT_MODE=0755

# Timeouts (seconds)
BACKUP_TIMEOUT=1800
DEPLOY_TIMEOUT=600
DATABASE_CREATE_TIMEOUT=60
```

---

## 3. Scripts with Responsibilities

### Core Infrastructure

**`bootstrap.sh`**
- Detect Ubuntu 24.04 release
- Update system packages
- Install Caddy (latest from official repo)
- Install PHP-FPM primary and fallback versions (latest from Ondrej PPA)
- Install MariaDB and PostgreSQL (latest from official repos)
- Install Valkey (latest from official repo)
- Configure basic Caddy (empty, ready for sites)
- Create webroot base directory and permissions
- Create backup and log directories
- Enable and start all services
- Create initial API auth token
- Generate and store server configuration summary

**`service-control.sh`**
```
Usage: ./service-control.sh {start|stop|restart|reload} {caddy|mariadb|postgresql|valkey|php-8.3|php-8.2|all}
```
- Wrapper around systemctl for all services
- Return exit code per action (0=success, 1=failure, 2=already in state)

**`service-status.sh`**
```
Usage: ./service-status.sh [service]  # Omit for all
```
- Output JSON with service states, uptime, resource usage
- Include version info for each component

### Site Operations

**`site-create.sh`**
```
Usage: ./site-create.sh <domain> <type> [--php-version=8.2] [--database=mysql|postgres] [--wordpress]
Types: static, php, wordpress, proxy
```
- Validate domain (DNS-safe)
- Create webroot directory at `$WEBROOT_BASE/$domain`
- Generate Caddy configuration block
- If type is `php` or `wordpress`: create PHP-FPM pool config
- If type is `proxy`: add proxy directive to Caddy config
- If database requested: create user + database (see `database-create.sh`)
- If WordPress: prompt for admin email, generate strong password (not logged), run WP-CLI installation
- Create dedicated SFTP user (chrooted to domain webroot)
- Generate and return credentials (SFTP user, DB password if applicable, WordPress admin URL)
- Reload Caddy
- Log operation with domain and type (no passwords)

**`site-delete.sh`**
```
Usage: ./site-delete.sh <domain> [--no-backup] [--force]
```
- Require confirmation unless `--force` is set
- Create full backup automatically (unless `--no-backup`)
- Warn if `--no-backup` without `--force`
- Remove Caddy configuration
- Remove PHP-FPM pool if exists
- Delete associated database user(s) if exists
- Delete SFTP user
- Delete webroot directory
- Remove Valkey cache entries for domain
- Reload Caddy
- Log operation (domain, backup location if created)

**`site-list.sh`**
- Enumerate domains from Caddy config and webroot directory
- Return JSON: domain, type, php_version, database (if any), created_date, size_bytes

**`deploy-static.sh`**
```
Usage: ./deploy-static.sh <domain> <local_path> [--delete-missing] [--exclude='*.log']
```
- Validate local_path exists
- Rsync to `$WEBROOT_BASE/$domain` with progress
- Preserve ownership and permissions
- Support exclude patterns
- Return summary: files changed, bytes transferred, duration

### Database Operations

**`database-create.sh`**
```
Usage: ./database-create.sh <site_domain> <engine> [--database-name=custom_name]
Engines: mysql, postgres
```
- Create database and dedicated user
- Generate strong password (not logged to stdout, only returned)
- Store credentials in `$WEBROOT_BASE/$domain/.env.local` (mode 0600, only readable by web server)
- Support custom database name (default: `domain_name` with sanitization)
- For WordPress: update `wp-config.php` if WP is detected in webroot
- Return credentials in structured format (for API to return)

### Backup & Restore

**`backup.sh`**
```
Usage: ./backup.sh [domain] [--compress] [--retention=30]
# If domain omitted, backup all sites
```
- Create timestamped backup directory: `$BACKUP_DIR/$domain-$(date +%Y%m%d-%H%M%S)/`
- Tar webroot: `webroot.tar[.gz]`
- Dump database (if associated): `database.sql[.gz]`
- Generate manifest: `manifest.json` (site type, php version, db engine, size)
- Prune backups older than `--retention` days
- Return JSON: backup path, files, sizes, duration

**`restore.sh`**
```
Usage: ./restore.sh <backup_path> [--domain=target_domain] [--skip-database]
```
- Validate backup integrity (check manifest, files present)
- Restore webroot (extract tar)
- Restore database if present and not `--skip-database`
- Update Caddy config if domain changed
- Reload services as needed
- Verify restored site accessibility

### Deployment

**`deploy-static.sh`** (detailed above in Site Operations)

---

## 4. Helper Scripts (in `scripts/helpers/`)

**`common.sh`**
- `log_info()`, `log_error()`, `log_warn()` — to `$LOG_DIR/<script>.log`
- `exit_error(code, msg)` — log error and exit with code
- `require_root()` — verify running as root
- `source_config()` — load `vps-manager.conf` with validation
- `generate_password()` — cryptographically strong 24-char random string
- `sanitize_domain()` — enforce DNS safety (lowercase, alphanumeric, hyphens)
- `sanitize_db_name()` — alphanumeric and underscores, max 64 chars
- `is_installed(tool)` — check if command exists

**`ssl.sh`**
- `caddy_add_site()` — append domain block to Caddy config
- `caddy_remove_site()` — remove domain block
- `caddy_validate_config()` — syntax check
- `caddy_reload()` — `systemctl reload caddy`

**`php.sh`**
- `php_create_pool()` — generate FPM pool config
- `php_delete_pool()` — remove pool config
- `php_available_versions()` — list installed PHP versions
- `php_service_name()` — return systemd unit name for version

**`database.sh`**
- `mysql_create_user_db()` — create user + database in MariaDB
- `mysql_delete_user_db()` — drop user and database
- `postgres_create_user_db()` — create role + database in PostgreSQL
- `postgres_delete_user_db()` — drop role and database
- `dump_database()` — export to SQL
- `restore_database()` — import from SQL

**`user.sh`**
- `create_sftp_user()` — system user with chrooted SFTP access
- `delete_sftp_user()` — remove user and home
- `set_webroot_permissions()` — chown and chmod webroot

**`validation.sh`**
- `validate_domain()` — domain format
- `validate_email()` — email format
- `validate_db_engine()` — mysql or postgres
- `validate_site_type()` — static, php, wordpress, proxy

---

## 5. API Routes & Responses

All routes require `Authorization: Bearer <token>` header.

### Sites

**`POST /api/sites`** — Create site
```json
{
  "domain": "example.com",
  "type": "wordpress",
  "php_version": "8.3",
  "database_engine": "mysql",
  "database_name": "wp_example"
}
```
Response (201):
```json
{
  "status": "created",
  "domain": "example.com",
  "type": "wordpress",
  "sftp": {
    "username": "example_com_1",
    "password": "***",  // Only in first response, never logged
    "host": "vps.example.com",
    "root": "/var/www/example.com"
  },
  "database": {
    "engine": "mysql",
    "host": "127.0.0.1",
    "database": "wp_example",
    "username": "wp_example_user",
    "password": "***"  // Only in first response
  },
  "wordpress": {
    "admin_url": "https://example.com/wp-admin",
    "admin_username": "admin"
  }
}
```

**`GET /api/sites`** — List all sites
Response (200):
```json
{
  "sites": [
    {
      "domain": "example.com",
      "type": "wordpress",
      "php_version": "8.3",
      "database": {"engine": "mysql", "name": "wp_example"},
      "created": "2024-06-22T10:30:00Z",
      "size_bytes": 1048576,
      "webroot_url": "https://example.com"
    }
  ]
}
```

**`GET /api/sites/{domain}`** — Get site details
Response (200):
```json
{
  "domain": "example.com",
  "type": "wordpress",
  "php_version": "8.3",
  "sftp_user": "example_com_1",
  "database": {"engine": "mysql", "name": "wp_example"},
  "size_bytes": 1048576,
  "created": "2024-06-22T10:30:00Z"
}
```

**`DELETE /api/sites/{domain}`** — Delete site
```json
{"no_backup": false, "force": false}
```
Response (202):
```json
{
  "status": "deletion_started",
  "domain": "example.com",
  "backup": {
    "path": "/var/backups/vps-manager/example.com-20240622-103000/",
    "created": "2024-06-22T10:31:00Z"
  }
}
```

### Databases

**`POST /api/sites/{domain}/databases`** — Create database for existing site
```json
{
  "engine": "mysql",
  "database_name": "custom_db"
}
```
Response (201):
```json
{
  "status": "created",
  "domain": "example.com",
  "database": {
    "engine": "mysql",
    "host": "127.0.0.1",
    "database": "custom_db",
    "username": "custom_db_user",
    "password": "***"
  }
}
```

### Backups

**`POST /api/backups`** — Create backup
```json
{
  "domain": null,  // null = all sites
  "compress": true,
  "retention_days": 30
}
```
Response (202):
```json
{
  "status": "backup_started",
  "backup_id": "example.com-20240622-103000",
  "path": "/var/backups/vps-manager/example.com-20240622-103000/"
}
```

**`GET /api/backups`** — List backups
Response (200):
```json
{
  "backups": [
    {
      "id": "example.com-20240622-103000",
      "domain": "example.com",
      "path": "/var/backups/vps-manager/example.com-20240622-103000/",
      "created": "2024-06-22T10:30:00Z",
      "size_bytes": 1048576,
      "manifest": {
        "type": "wordpress",
        "php_version": "8.3",
        "database_engine": "mysql"
      }
    }
  ]
}
```

**`POST /api/backups/{backup_id}/restore`** — Restore from backup
```json
{
  "target_domain": "example.com",
  "skip_database": false
}
```
Response (202):
```json
{
  "status": "restore_started",
  "backup_id": "example.com-20240622-103000"
}
```

### Deployment

**`POST /api/sites/{domain}/deploy`** — Deploy static files
```json
{
  "source_url": "https://github.com/user/repo/releases/download/v1.0/build.tar.gz",
  "delete_missing": true,
  "exclude_patterns": ["*.log", ".env"]
}
```
OR (local file via multipart):
```
POST /api/sites/{domain}/deploy
multipart/form-data:
  file: <tar/zip archive>
  delete_missing: true
  exclude_patterns: *.log
```
Response (202):
```json
{
  "status": "deploy_started",
  "domain": "example.com"
}
```

### Services

**`GET /api/services`** — Get all service statuses
Response (200):
```json
{
  "services": [
    {
      "name": "caddy",
      "status": "active",
      "uptime_seconds": 86400,
      "version": "v2.7.4",
      "memory_mb": 45.2
    },
    {
      "name": "php-8.3",
      "status": "active",
      "uptime_seconds": 86400,
      "version": "8.3.7",
      "memory_mb": 123.4
    }
  ]
}
```

**`POST /api/services/{name}/control`** — Control service
```json
{"action": "restart"}  // start, stop, restart, reload
```
Response (200):
```json
{
  "status": "success",
  "service": "caddy",
  "action": "restart",
  "new_state": "active"
}
```

### System

**`GET /api/system/info`** — Server info
Response (200):
```json
{
  "hostname": "vps.example.com",
  "ubuntu_version": "24.04",
  "uptime_seconds": 604800,
  "disk_usage": {"total_gb": 100, "used_gb": 45, "percent": 45},
  "memory": {"total_mb": 16384, "available_mb": 8192},
  "components": {
    "caddy": "v2.7.4",
    "php_primary": "8.3.7",
    "php_fallback": "8.2.10",
    "mariadb": "11.4.0",
    "postgresql": "16.0",
    "valkey": "7.2.0"
  }
}
```

**`POST /api/bootstrap`** — Run server bootstrap (first-time setup)
```json
{
  "hostname": "vps.example.com",
  "admin_email": "admin@example.com"
}
```
Response (202):
```json
{
  "status": "bootstrap_started"
}
```

---

## 6. Key Design Decisions & Assumptions

### Security
- **No secrets on disk**: Passwords generated on-the-fly, returned only to API caller once, stored only in `.env.local` (mode 0600) or `.htpasswd` for WordPress
- **Bearer token auth**: Single token stored in secure file (`/etc/vps-manager/.api-token`), mode 0600, root-only read
- **No API logging of passwords**: Script stdout/stderr returned to API, but secrets scrubbed from logs
- **SFTP chroot**: Each site has a dedicated chrooted user, cannot escape to other sites
- **WordPress credentials**: Prompted on CLI only, never exposed via API

### Idempotency
- `site-create.sh` aborts if domain already exists (with clear error message)
- `database-create.sh` checks if database user already exists, skips if so
- `service-control.sh` returns 0 even if service already in target state
- `bootstrap.sh` checks if components installed before installing

### Configuration
- Single `vps-manager.conf` sourced by all scripts
- All PHP, database, cache versions resolved at bootstrap time from official repos (no hardcoded versions)
- Paths, retention, timeouts all configurable
- Config file location: `/etc/vps-manager/vps-manager.conf`

### Backup Strategy
- Backups are full (webroot + database), not incremental
- Naming: `{domain}-{YYYYMMDD}-{HHMMSS}/`
- Manifest: `manifest.json` includes site type, PHP version, database engine for restore compatibility
- Retention policy: configurable per backup call, default 30 days
- Compression: optional, gzip by default

### Site Types
- **static**: Caddy reverse proxy only, no PHP, no database
- **php**: PHP-FPM pool + Caddy, optional database
- **wordpress**: PHP-FPM + WP-CLI installation + forced database
- **proxy**: Caddy reverse proxy to local port, no PHP/database

### PHP-FPM
- Primary (8.3) and fallback (8.2) installed on bootstrap
- Each site gets a dedicated pool config: `/etc/php/{version}/fpm/pool.d/{domain}.conf`
- PHP services started/stopped per version via systemd
- Fallback version selectable at site creation

### Database Access
- MariaDB and PostgreSQL both installed on bootstrap
- User can choose at site creation time
- Dedicated database + user per site (isolation)
- Credentials stored in `.env.local` (mode 0600)
- No access from outside (localhost only)

### Caddy Configuration
- All site configs appended to main Caddy config as separate blocks
- Reload (not restart) on each site change for zero downtime
- HTTPS automatic via Let's Encrypt
- Caddy handles all TLS termination

### Logging
- All scripts log to `/var/log/vps-manager/{script}.log`
- Log format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
- Sensitive values never logged (passwords, tokens)
- API logs separate: `/var/log/vps-manager/api.log`

### API Execution
- Script execution via `subprocess.Popen()` with output capture
- Timeout per operation (configurable)
- Exit code mapped to HTTP status: 0→success, 1→client error (400), 2→server error (500)
- Async operations return 202 Accepted with job ID for polling

### Systemd
- API runs as service: `vps-manager-api.service`
- Restart policy: always
- Standard output/error logged to journalctl

---

## 7. Questions Before Starting

1. **API Token Storage**: Should the initial token be generated during bootstrap and printed once, or should there be a separate token rotation mechanism? Is a single shared token acceptable, or should we support multiple named tokens (API keys)?

2. **Domain Validation**: Should we validate domain DNS resolution? Should we auto-detect if domain already points to this server's IP?

3. **WordPress Credentials Handling**: For `site-create.sh` via CLI, should we prompt interactively or accept flags? Should we generate a default username (`admin`) or allow custom?

4. **Reverse Proxy**: For `proxy` type sites, should we auto-detect health/uptime of the backend, or just trust the user's configuration?

5. **Database Backup Timing**: Should backups be incremental with periodic full backups, or always full? Should there be point-in-time recovery support?

6. **Concurrent Operations**: Should the API queue requests or run them in parallel? Any limits on concurrent deployments/backups?

7. **Monitoring**: Should the toolkit include basic health checks (disk space, service status alerts) that can trigger alerts?

8. **Multi-tenancy**: Is this a single-admin tool (one person manages all sites), or should we support role-based access (per-site permissions)?

9. **Rollback**: Should failed operations (site creation, deployment) auto-rollback, or leave things in partially-created state for inspection?

10. **CLI vs API Parity**: Should all operations be available via both CLI and API, or are some CLI-only (like interactive WordPress setup)?

---

## 8. Implementation Phases

### Phase 1: Core Infrastructure
- [ ] Project structure & config file
- [ ] Helper scripts (common.sh, validation.sh)
- [ ] `bootstrap.sh`
- [ ] `service-control.sh` and `service-status.sh`

### Phase 2: Site Management
- [ ] `site-create.sh` (all types)
- [ ] `site-delete.sh` with backup
- [ ] `site-list.sh`
- [ ] `database-create.sh`

### Phase 3: Backup & Restore
- [ ] `backup.sh`
- [ ] `restore.sh`
- [ ] Backup retention policy

### Phase 4: Deployment
- [ ] `deploy-static.sh`
- [ ] Rsync integration

### Phase 5: FastAPI
- [ ] Authentication & token validation
- [ ] Route handlers
- [ ] Script execution wrapper
- [ ] Error handling & response mapping

### Phase 6: Testing & Documentation
- [ ] Bash script tests
- [ ] API integration tests
- [ ] README, quickstart, API docs
- [ ] Troubleshooting guide

---

## Notes

- All scripts should have a `--help` option with usage examples
- All operations should be logged with sufficient detail for debugging
- Error messages should be actionable (not "Command failed" but "Failed to create database user: already exists")
- The API should support webhooks for long-running operations (optional for v1)
- Consider a simple web UI dashboard (optional for v1, can be static HTML calling API)
