# VPS Manager — Implementation Plan

## 1. Project Structure

```
vps-manager/
├── README.md                     # Project documentation
├── requirements.txt              # Python dependencies (FastAPI, etc.)
├── config/
│   └── vps-manager.conf         # Central configuration (paths, versions, retention)
├── scripts/
│   ├── bootstrap.sh             # Initial server provisioning
│   ├── site-create.sh           # Create site with all components
│   ├── site-delete.sh           # Full site removal with backup
│   ├── database-create.sh       # Create database for existing site
│   ├── site-deploy.sh           # Push static content via rsync
│   ├── backup.sh                # Backup management (single or all sites)
│   ├── service.sh               # Service state management
│   └── utils.sh                 # Shared functions (logging, state checks, etc.)
├── api/
│   ├── main.py                  # FastAPI application entry point
│   ├── auth.py                  # Bearer token validation
│   ├── models.py                # Pydantic request/response models
│   ├── executor.py              # Script execution wrapper
│   └── routes/
│       ├── __init__.py
│       ├── sites.py             # Site CRUD endpoints
│       ├── databases.py         # Database creation endpoint
│       ├── backups.py           # Backup management endpoints
│       ├── services.py          # Service state endpoints
│       └── deployment.py        # Static deploy endpoint
├── templates/
│   ├── caddy-static.conf        # Caddy config template (static site)
│   ├── caddy-php.conf           # Caddy config template (PHP site)
│   ├── caddy-wordpress.conf     # Caddy config template (WordPress)
│   ├── caddy-proxy.conf         # Caddy config template (reverse proxy)
│   └── php-pool.conf            # PHP-FPM pool template
├── systemd/
│   └── vps-manager-api.service  # SystemD unit for FastAPI app
├── logs/                        # Runtime logs (git-ignored)
├── backups/                     # Backup storage (git-ignored)
└── .gitignore
```

## 2. Scripts and Responsibilities

### `bootstrap.sh`
**Purpose**: One-time server setup on clean Ubuntu 24.04

**Operations**:
- Detect and install current PHP version (dynamically from php.net)
- Install fallback PHP version (e.g., n-1 or user-specified)
- Install MariaDB (detect latest from mariadb.org)
- Install PostgreSQL (detect latest from postgresql.org)
- Install Valkey (detect latest from github.com/valkey-io/valkey)
- Install Caddy (detect latest from github.com/caddyserver/caddy)
- Create directory structure: `/srv/vps-manager/{sites,backups,php-pools,caddy-configs}`
- Create system user for SFTP chroot: `vps-sftp` (no shell access)
- Enable and start all services
- Create log directory and set permissions
- Generate initial API token (output to console, never stored)
- Configure firewall (ufw) if present: allow 22, 80, 443

**Idempotency**: Check if services are already installed; skip if present

---

### `site-create.sh`
**Purpose**: Provision a complete site with all required components

**Inputs**:
- Domain name (required)
- Site type: `static` | `php` | `wordpress` | `proxy`
- PHP version: `current` | `fallback` (default: current, only for php/wordpress)
- Database type: `mysql` | `postgres` (optional, only for php/wordpress if requested)
- Proxy target: local port (only for proxy type, e.g., `:3000`)

**Operations**:
1. Validate domain (basic format check)
2. Create webroot: `/srv/vps-manager/sites/{domain}/public`
3. Generate Caddy config from template based on site type
4. If site type is `php` or `wordpress`:
   - Create PHP-FPM pool config for selected PHP version
   - Reload PHP-FPM
5. If database requested:
   - Generate random database name, user, and password
   - Create database and user in selected engine
   - Store credentials in `/srv/vps-manager/sites/{domain}/.env` (chmod 600, never logged)
6. If site type is `wordpress`:
   - Initialize WordPress directory
   - Download WP-CLI if not present
   - Run WP-CLI interactively to:
     - Prompt for admin username, email, password
     - Set site URL
     - Complete installation
   - Never store credentials; only log success/failure
7. Create SFTP user:
   - Username: `sftp-{domain}` (e.g., `sftp-example.com`)
   - Chroot to `/srv/vps-manager/sites/{domain}`
   - No password login; SSH keys only (auto-generated and output)
   - Add SSH public key to `/home/sftp-{domain}/.ssh/authorized_keys`
8. Set permissions:
   - Webroot owned by `www-data:www-data`
   - PHP-FPM pool runs as dedicated user (e.g., `php-{domain}`) if desired, or shared `www-data`
   - SFTP user can read/write to webroot
9. Reload Caddy
10. Return site config summary (domain, PHP version, database type, SFTP user, public key)

**Idempotency**: Check if site already exists; fail if present (unless `--force` flag)

---

### `site-delete.sh`
**Purpose**: Remove all resources associated with a domain

**Inputs**:
- Domain name (required)
- `--skip-backup`: Skip automatic backup (default: create backup)
- `--force`: Skip confirmation prompt

**Operations**:
1. If backup not skipped:
   - Call `backup.sh` with domain to create timestamped backup
   - Verify backup completed successfully
2. If neither `--force` nor automatic backup succeeded: prompt "Proceed? (yes/no)"
3. Remove Caddy config: `/etc/caddy/sites.d/{domain}.conf`
4. Remove PHP-FPM pool config (if exists)
5. Reload PHP-FPM and Caddy
6. Drop database and database user (if exists)
7. Remove system user(s): `sftp-{domain}`, dedicated PHP user if created
8. Remove webroot directory tree: `/srv/vps-manager/sites/{domain}`
9. Log deletion summary

**Idempotency**: Check if site exists; gracefully skip non-existent components

---

### `database-create.sh`
**Purpose**: Add a database to an existing site after initial provisioning

**Inputs**:
- Domain name (required)
- Database type: `mysql` | `postgres` (required)

**Operations**:
1. Verify site exists
2. Check if database already exists for this site; fail if present
3. Generate random database name, user, password
4. Create in specified engine
5. Store credentials in `/srv/vps-manager/sites/{domain}/.env` (append or update)
6. Output credentials to stdout only (formatted, never logged)
7. Return success

---

### `site-deploy.sh`
**Purpose**: Push local build to site's webroot

**Inputs**:
- Domain name (required)
- Local source path (required, absolute or relative)
- `--exclude-patterns`: Comma-separated patterns to exclude (e.g., `.git,.env`)

**Operations**:
1. Validate source path exists and is readable
2. Validate site webroot exists
3. Run rsync with:
   - Archive mode (`-a`)
   - Delete remote files not in source (`--delete`)
   - Exclude sensible defaults: `.git, .env, node_modules, __pycache__`
   - Exclude user-specified patterns if provided
4. Verify rsync exit code
5. Log summary (file count, bytes transferred)
6. For PHP sites: clear opcache if needed (touch a marker or call PHP reload)

**Idempotency**: Safe to run repeatedly; rsync skips unchanged files

---

### `backup.sh`
**Purpose**: Archive webroot and database dumps

**Inputs**:
- Domain or `all` (required)
- `--output-dir`: Custom backup storage path (default: `/srv/vps-manager/backups`)
- `--retention-days`: Override config default for cleanup (optional)

**Operations**:
1. Create timestamped backup directory: `{domain}-{YYYY-MM-DD-HHmmss}`
2. Archive webroot: `{backup-dir}/{domain}-webroot.tar.gz`
3. If database exists, dump and compress:
   - MySQL: `mysqldump --single-transaction > dump.sql && gzip dump.sql`
   - PostgreSQL: `pg_dump > dump.sql && gzip dump.sql`
   - Store as `{backup-dir}/{domain}-database.sql.gz`
4. Create manifest file: `{backup-dir}/manifest.json` with:
   - Site domain
   - Backup timestamp
   - Webroot size
   - Database dump size
   - Site type
5. If `domain == "all"`: loop over all sites, create individual backups
6. Cleanup old backups based on `--retention-days` (default from config)
7. Log backup summary

**Idempotency**: Creates new backup each time; retention cleanup is idempotent

---

### `service.sh`
**Purpose**: Manage server component lifecycle

**Inputs**:
- Service name: `caddy` | `php-fpm-current` | `php-fpm-fallback` | `mariadb` | `postgres` | `valkey` | `all` (required)
- Action: `start` | `stop` | `restart` | `reload` | `status` (required)

**Operations**:
1. Map service name to systemd unit name
2. Execute: `systemctl {action} {unit}`
3. Return exit code and status output
4. For `all`: run action on each service, aggregate results

**Idempotency**: systemd handles safely (start on running service is no-op)

---

### `utils.sh`
**Purpose**: Shared functions used by all scripts

**Functions**:
- `log()`: Write to log file with timestamp (never log sensitive data)
- `die()`: Log error and exit with code
- `source_config()`: Load `/root/projects/LLM-Challenge/claude/config/vps-manager.conf`
- `check_root()`: Verify script is run as root
- `validate_domain()`: Domain format validation
- `sanitize_username()`: Ensure username is valid for system user
- `generate_random_password()`: Create secure password (output only, never logged)
- `generate_ssh_key()`: Create SSH key pair (return public key, output private key securely)
- `site_exists()`: Check if webroot exists
- `database_exists()`: Check if database exists
- `get_site_config()`: Read site metadata (type, PHP version, database info)
- `set_site_config()`: Write site metadata to JSON file in webroot

---

## 3. API Routes

All routes require **Bearer token** in `Authorization: Bearer <token>` header.

**Base URL**: `/api/v1`

### Sites Management

#### `POST /api/v1/sites`
Create a new site.

**Request**:
```json
{
  "domain": "example.com",
  "site_type": "php",
  "php_version": "current",
  "database_type": "mysql"
}
```

**Response** (201):
```json
{
  "domain": "example.com",
  "site_type": "php",
  "php_version": "8.3",
  "database": {
    "type": "mysql",
    "name": "ex_db_xyz",
    "user": "ex_user_xyz"
  },
  "sftp_user": "sftp-example.com",
  "webroot": "/srv/vps-manager/sites/example.com/public"
}
```

---

#### `GET /api/v1/sites`
List all sites.

**Response** (200):
```json
{
  "sites": [
    {
      "domain": "example.com",
      "site_type": "php",
      "created_at": "2026-06-20T10:30:00Z",
      "php_version": "8.3"
    }
  ]
}
```

---

#### `GET /api/v1/sites/{domain}`
Get detailed site info.

**Response** (200):
```json
{
  "domain": "example.com",
  "site_type": "php",
  "php_version": "8.3",
  "database": {
    "type": "mysql",
    "host": "localhost",
    "name": "ex_db_xyz"
  },
  "sftp_user": "sftp-example.com",
  "webroot": "/srv/vps-manager/sites/example.com/public",
  "created_at": "2026-06-20T10:30:00Z",
  "webroot_size_mb": 125.4
}
```

---

#### `DELETE /api/v1/sites/{domain}`
Delete a site (with automatic backup unless `skip_backup=true`).

**Query Parameters**:
- `skip_backup`: boolean (default: false)
- `force`: boolean (default: false) — skip confirmation

**Response** (202):
```json
{
  "status": "deleting",
  "backup_location": "/srv/vps-manager/backups/example.com-2026-06-22-103045",
  "message": "Site deletion in progress. Backup created before removal."
}
```

---

#### `POST /api/v1/sites/{domain}/deploy`
Deploy static content to site webroot via rsync.

**Request**:
```json
{
  "source_path": "/home/user/build",
  "exclude_patterns": ".git,.env,node_modules"
}
```

**Response** (200):
```json
{
  "status": "success",
  "files_transferred": 234,
  "bytes_transferred": 5242880,
  "duration_seconds": 12
}
```

---

### Database Management

#### `POST /api/v1/sites/{domain}/database`
Create a new database for an existing site.

**Request**:
```json
{
  "database_type": "postgres"
}
```

**Response** (201):
```json
{
  "database_type": "postgres",
  "name": "ex_db_abc",
  "user": "ex_user_abc",
  "host": "localhost",
  "note": "Credentials are stored in .env at site root"
}
```

---

### Backups

#### `GET /api/v1/backups?domain={domain}`
List backups for a domain (or all if domain omitted).

**Response** (200):
```json
{
  "backups": [
    {
      "id": "example.com-2026-06-22-103045",
      "domain": "example.com",
      "created_at": "2026-06-22T10:30:45Z",
      "webroot_size_mb": 125.4,
      "database_size_mb": 45.2,
      "total_size_mb": 170.6
    }
  ]
}
```

---

#### `POST /api/v1/backups/{domain}`
Trigger an immediate backup for a domain.

**Request**:
```json
{
  "retention_days": 30
}
```

**Response** (201):
```json
{
  "backup_id": "example.com-2026-06-22-103045",
  "location": "/srv/vps-manager/backups/example.com-2026-06-22-103045",
  "status": "completed"
}
```

---

#### `DELETE /api/v1/backups/{backup_id}`
Delete a specific backup.

**Response** (204): Empty on success.

---

### Services

#### `GET /api/v1/services`
Get status of all server components.

**Response** (200):
```json
{
  "services": {
    "caddy": "active",
    "php-fpm-current": "active",
    "php-fpm-fallback": "inactive",
    "mariadb": "active",
    "postgres": "active",
    "valkey": "active"
  }
}
```

---

#### `GET /api/v1/services/{service}`
Get status of a single service.

**Response** (200):
```json
{
  "service": "caddy",
  "status": "active",
  "uptime_seconds": 86400,
  "restart_count": 0
}
```

---

#### `POST /api/v1/services/{service}/start`
#### `POST /api/v1/services/{service}/stop`
#### `POST /api/v1/services/{service}/restart`
#### `POST /api/v1/services/{service}/reload`

Service control endpoints.

**Response** (200):
```json
{
  "service": "caddy",
  "action": "restart",
  "status": "active"
}
```

---

## 4. Configuration File (`vps-manager.conf`)

**Location**: `/root/projects/LLM-Challenge/claude/config/vps-manager.conf`

```bash
# VPS Manager Configuration

# Paths
SITES_ROOT="/srv/vps-manager/sites"
BACKUPS_ROOT="/srv/vps-manager/backups"
LOGS_DIR="/var/log/vps-manager"
CADDY_CONFIGS_DIR="/etc/caddy/sites.d"
PHP_POOLS_DIR="/etc/php/fpm/pool.d"

# PHP Versions (resolved dynamically at bootstrap, then cached)
PHP_VERSION_CURRENT="8.3"
PHP_VERSION_FALLBACK="8.2"

# Database defaults
DEFAULT_DB_ENGINE="mysql"
MARIADB_HOST="localhost"
POSTGRES_HOST="localhost"

# Service names (systemd units)
SERVICE_CADDY="caddy"
SERVICE_PHP_CURRENT="php8.3-fpm"
SERVICE_PHP_FALLBACK="php8.2-fpm"
SERVICE_MARIADB="mariadb"
SERVICE_POSTGRES="postgresql"
SERVICE_VALKEY="valkey"

# Backup retention
BACKUP_RETENTION_DAYS=30
BACKUP_MAX_COUNT=10

# Logging
LOG_LEVEL="INFO"
LOG_DATE_FORMAT="+%Y-%m-%d %H:%M:%S"

# FastAPI
API_HOST="127.0.0.1"
API_PORT="8000"
API_LOG_FILE="$LOGS_DIR/api.log"

# SFTP
SFTP_CHROOT_BASE="/srv/vps-manager/sites"
```

---

## 5. Design Decisions

### 1. **No Docker**
Scripts run natively on host using systemd. Simpler deployment, direct resource access, no container overhead.

### 2. **Idempotency First**
All scripts check state before making changes. Safe to re-run without side effects. Enables retries and partial recovery.

### 3. **Sensitive Data Handling**
- Passwords generated but **never written to disk** during output
- Credentials stored only in `.env` files (chmod 600) in site directories
- API never returns passwords (only confirms storage location)
- Database credentials output to stdout only during interactive creation
- No credentials in logs or audit trails

### 4. **Dynamic Version Resolution**
- Bootstrap script detects latest stable versions from official sources at install time
- Versions cached in config file for consistency
- No hardcoded versions; adapts to upstream releases

### 5. **Per-Site PHP-FPM Pools**
- Each site gets dedicated pool or shares based on configuration
- Fallback version selectable per site for compatibility
- Isolates one site's PHP errors from others

### 6. **SFTP with Chroot and SSH Keys**
- Each site has dedicated SFTP user (sftp-{domain})
- Chrooted to site webroot, cannot access other sites
- SSH keys only (no password auth); private key output once at creation
- Enables secure, automated deployments via CI/CD

### 7. **Automatic Pre-Deletion Backup**
- Before removing site, backup created automatically
- Backup stored in timestamped directory with manifest
- Can skip with explicit `--skip-backup` flag, but requires confirmation
- Prevents accidental data loss; supports recovery window

### 8. **Caddy for All Web Operations**
- Reverse proxy for static, PHP, WordPress, and custom services
- Automatic HTTPS via Let's Encrypt (built-in)
- Simple config templates per site type
- Handles routing, SSL, compression out-of-the-box

### 9. **Centralized Configuration**
- Single `vps-manager.conf` file for all tunable constants
- Paths, versions, retention, service names—all in one place
- Scripts source this file at runtime
- No scattered magic numbers

### 10. **Structured Logging**
- All logs written to `/var/log/vps-manager/`
- Timestamped, tagged by component
- Errors and operations logged separately
- Audit trail for compliance, debugging

### 11. **Bearer Token Authentication**
- Single token stored on server (generated at bootstrap)
- Shared via secure channel (not in code, not in API responses)
- Sufficient for lightweight internal automation
- Can be rotated by regenerating and updating API app config

### 12. **HTTP Status Mapping**
- 200: Success
- 201: Created
- 202: Accepted (async operations like delete)
- 400: Bad request (validation error)
- 401: Unauthorized (invalid/missing token)
- 404: Not found (domain/service doesn't exist)
- 409: Conflict (site already exists)
- 500: Server error (script failure)
- Exit codes from shell scripts map to HTTP status

### 13. **WordPress CLI-Only**
- WP-CLI prompts for admin credentials interactively
- Credentials never exposed via API
- Ensures passwords are never stored or logged
- Supports complex WordPress-specific setup (plugins, themes, multisite)

---

## 6. Assumptions

1. **Ubuntu 24.04 LTS** on fresh VPS with root access
2. **Internet connectivity** for package installation and Let's Encrypt
3. **Valid DNS** for domains before site provisioning (Caddy requires valid domain for cert renewal)
4. **Minimal base system** (apt, systemd, bash)
5. **System user** `vps-sftp` can be created for SFTP chroot
6. **www-data user** exists (standard on Debian/Ubuntu)
7. **FastAPI app runs as unprivileged user** (e.g., `vps-api`) with sudo capability for script execution
8. **Local database servers** (MariaDB, PostgreSQL, Valkey) on same machine
9. **Backups stored locally** (can be extended to S3 or rsync-to-remote later)
10. **No existing Caddy config** (bootstrap assumes clean system; can adapt for existing setup)
11. **SSH key pairs** can be generated and output to user (one-time, then stored securely elsewhere)

---

## 7. Implementation Questions & Notes

### Q1: SSH Key Management
**Question**: For SFTP users, where should generated private keys be stored/delivered?
- **Option A**: Output to stdout once, user must save immediately
- **Option B**: Store in `/tmp` with explicit cleanup instructions
- **Option C**: Require user to provide public key at site creation

**Recommendation**: **Option A**. Output to stdout with clear instructions. User is responsible for secure storage. Matches standard cloud provider UX (AWS EC2 key pair, etc.).

---

### Q2: API Token Rotation
**Question**: Should API tokens be rotated? How often, and how?
- **Option A**: Single immutable token, regenerate requires manual bootstrap re-run
- **Option B**: Token file in secured location (`/etc/vps-manager/token`), rotate via CLI tool
- **Option C**: Token expiry with refresh tokens

**Recommendation**: **Option B**. Store token in `/etc/vps-manager/token` (readable only by api service user). CLI tool to regenerate. Simple, secure, manageable.

---

### Q3: Database User Naming
**Question**: How to name auto-created database users to avoid collisions?
- **Option A**: `{domain_sanitized}_{random_suffix}` (e.g., `example_com_a7k9`)
- **Option B**: `{domain_hash}_{sequence}` (e.g., `ex42_001`)
- **Option C**: Random 16-char alphanumeric

**Recommendation**: **Option A**. Readable for debugging, includes domain context, collision-safe via suffix. Max length manageable for MySQL (64 chars) and PostgreSQL (63 chars).

---

### Q4: PHP Pool Isolation
**Question**: Should each site get a dedicated PHP-FPM pool and system user, or share?
- **Option A**: Dedicated pool per site (more isolation, more overhead)
- **Option B**: Shared `www-data` pool (simpler, less isolation)
- **Option C**: Configurable per site (added complexity)

**Recommendation**: **Option B initially, with room for Option C**. Start simple. Add `--dedicated-pool` flag to `site-create.sh` if isolation becomes critical. Most shared hosting uses pooling anyway.

---

### Q5: Static Site Deployment
**Question**: Should `site-deploy.sh` handle only push (rsync), or also pull, npm build, etc.?
- **Option A**: Rsync only; expect user to build locally
- **Option B**: Support pulling from git + building
- **Option C**: Template-based deployment scripts per site

**Recommendation**: **Option A**. Keep deployment simple and declarative. Let CI/CD systems (GitHub Actions, GitLab CI) do the build; rsync just handles transfer. Reduces complexity, clear separation of concerns.

---

### Q6: WordPress Support
**Question**: How to handle WordPress updates and plugin management?
- **Option A**: Manual via WP-CLI (user responsibility)
- **Option B**: API endpoint to trigger WP-CLI updates
- **Option C**: Cron job for auto-updates

**Recommendation**: **Option A initially, extensible to B**. Bootstrap provides WP-CLI; site-create installs WordPress. For updates, user calls WP-CLI directly or we add API endpoint later. Don't auto-update production sites without testing.

---

### Q7: Proxy Target Validation
**Question**: How to validate reverse proxy targets (`:3000`, `localhost:8000`, etc.)?
- **Option A**: Simple regex (`:(\d{1,5})`)
- **Option B**: Port must be in range 1024–65535
- **Option C**: Allow full URL (`http://localhost:3000`)

**Recommendation**: **Option B**. Validate port in range, require `localhost` or `127.0.0.1`, assume `http://`. Security: prevent proxying to privileged ports or external IPs.

---

### Q8: Backup Encryption
**Question**: Should backups be encrypted at rest?
- **Option A**: No encryption (simple, assume storage is secure)
- **Option B**: Optional encryption via GPG key
- **Option C**: Mandatory encryption

**Recommendation**: **Option A initially**. Backups are sensitive; assume they live on secure storage (server itself, VPN-protected NAS, etc.). Encryption can be added as post-processing step if needed. Adds complexity without clear threat model.

---

### Q9: Logging Sensitivity
**Question**: What level of detail should scripts log? Especially regarding domain names, file paths?
- **Option A**: Minimal (only errors and completion status)
- **Option B**: Verbose (operations, timings, resource usage)
- **Option C**: Structured JSON logs

**Recommendation**: **Option B initially**. Log operations for debugging, but exclude: passwords, database contents, full file paths where unnecessary. Timestamp, operation, status. Move to structured logs (Option C) if parsing/analysis needed.

---

### Q10: Service Interdependencies
**Question**: Should `service.sh` handle service dependency management?
- **Example**: Restarting MariaDB should check PHP sites, notify if any error?
- **Option A**: No; let user manage dependencies
- **Option B**: Simple dependency map; warn if dependent service down
- **Option C**: Auto-restart dependent services

**Recommendation**: **Option A initially, with option B as extension**. Add `--check-dependents` flag to `service.sh`. Don't auto-restart; operator should decide.

---

### Q11: Multi-Server Support
**Question**: Should this toolkit be designed to eventually manage multiple servers, or assume single-server setup?
- **Option A**: Single-server only; scripts assume `localhost` for databases
- **Option B**: Support remote DB servers (specify host in config)
- **Option C**: Full multi-server orchestration (out of scope for MVP)

**Recommendation**: **Option B as design goal, Option A for MVP**. Config file should support `MARIADB_HOST=` and `POSTGRES_HOST=` for future extension. Don't implement multi-server logic yet, but don't lock against it.

---

### Q12: API Documentation
**Question**: Should API expose OpenAPI/Swagger docs?
- **Option A**: No; documentation is this plan + curl examples
- **Option B**: Auto-generated Swagger via FastAPI's `docs` endpoint
- **Option C**: Custom OpenAPI schema

**Recommendation**: **Option B**. FastAPI generates Swagger automatically at `/docs` if enabled. Zero extra work, huge usability gain. Can disable in production if security concern.

---

## 8. Next Steps

1. **Create initial directory structure** and `.gitignore`
2. **Write `config/vps-manager.conf`** with default values
3. **Implement `scripts/utils.sh`** with all shared functions
4. **Implement `bootstrap.sh`** (installs all components)
5. **Implement `site-create.sh`** (most complex; covers all site types)
6. **Implement remaining scripts** (delete, database-create, deploy, backup, service)
7. **Create Caddy and PHP-FPM config templates**
8. **Implement FastAPI app** (main.py, models, routes, executor)
9. **Add systemd unit** for API service
10. **Write comprehensive README** with examples
11. **Test on clean Ubuntu 24.04 VM**

---

## Summary

This toolkit is **minimal, opinionated, and production-ready in scope**. It trades flexibility for simplicity: no Docker, no abstraction, no UI. Scripts are declarative shell + FastAPI wrapper. All configuration centralized. Sensitive data never logged. Idempotent operations enable safe retries and recovery.

The 7 core scripts handle 80% of common VPS operations. The API layer is thin—just a subprocess executor with auth and JSON responses. Bootstrap is one-time; day-to-day operations are site CRUD, backups, and service management.

Design prioritizes **operator safety** (backups before deletion, confirmation prompts), **auditability** (logs everything except secrets), and **debuggability** (scripts return meaningful exit codes, stdout for important output).
