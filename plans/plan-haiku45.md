# VPS Manager - Implementation Plan

## Executive Summary

This plan proposes a minimal, script-driven VPS management toolkit that provides programmatic control over a multi-tenant web hosting environment. The architecture separates operational scripts from the API layer, ensures all operations are idempotent, and maintains strict security boundaries around sensitive data.

---

## 1. Project Structure

```
vps-manager/
├── README.md
├── config/
│   └── config.sh                      # Centralized configuration (sourced by all scripts)
├── scripts/
│   ├── bootstrap.sh                   # Initial server setup
│   ├── site-create.sh                 # Provision a new site
│   ├── site-delete.sh                 # Delete a site (with backup)
│   ├── site-backup.sh                 # Backup individual site or all sites
│   ├── site-deploy.sh                 # Deploy static assets via rsync
│   ├── database-create.sh              # Create database for existing site
│   ├── service-manage.sh               # Start/stop/restart/status for services
│   └── utils/
│       ├── common.sh                  # Shared functions (logging, errors, locks)
│       ├── version-resolver.sh        # Fetch latest versions from upstream
│       └── validators.sh              # Domain, username, port validation
├── api/
│   ├── main.py                        # FastAPI app entry point
│   ├── config.py                      # API-specific configuration
│   ├── auth.py                        # Bearer token middleware
│   ├── routes/
│   │   ├── __init__.py
│   │   ├── sites.py                   # /api/sites/* endpoints
│   │   ├── databases.py               # /api/databases/* endpoints
│   │   ├── services.py                # /api/services/* endpoints
│   │   ├── backups.py                 # /api/backups/* endpoints
│   │   └── bootstrap.py               # /api/bootstrap endpoint
│   ├── models.py                      # Pydantic request/response schemas
│   ├── runners.py                     # Script invocation layer
│   └── utils.py                       # Helper functions (path resolution, etc.)
├── docs/
│   ├── api-reference.md               # Full API documentation
│   ├── architecture.md                # Technical design decisions
│   ├── deployment.md                  # Deployment guide
│   └── troubleshooting.md             # Common issues and solutions
├── logs/                              # Runtime logs directory
├── backups/                           # Site backups directory
├── sites/                             # Virtual host root directory
└── requirements.txt                   # Python dependencies
```

---

## 2. Core Architecture

### 2.1 Configuration Management

**File**: `config/config.sh`

All constants centralized here, sourced by every script. Examples:

```bash
# Component versions (resolved dynamically at bootstrap)
PHP_VERSION_PRIMARY="${PHP_VERSION_PRIMARY:-}"
PHP_VERSION_FALLBACK="${PHP_VERSION_FALLBACK:-}"
CADDY_VERSION="${CADDY_VERSION:-}"

# Paths
SITES_ROOT="/var/www"
BACKUPS_ROOT="/var/backups/vps-manager"
LOGS_DIR="/var/log/vps-manager"

# PHP-FPM configuration
PHP_FPM_SOCKET_PATH="/run/php"
PHP_FPM_USER="www-data"
PHP_FPM_GROUP="www-data"

# Database credentials (populated at bootstrap, stored securely)
DB_ADMIN_USER="root"
# DB_ADMIN_PASS never stored; passed via environment

# Tunable parameters
BACKUP_RETENTION_DAYS=30
SFTP_CHROOT_ENABLED=true
LOG_RETENTION_DAYS=90
MAX_SITE_BACKUPS=5
```

### 2.2 Logging & Error Handling

**File**: `scripts/utils/common.sh`

All scripts inherit:
- **Unified logging**: All operations logged to `${LOGS_DIR}/vps-manager.log` with timestamps and severity levels
- **Error tracing**: Failed commands captured with context (script name, line number, exit code)
- **Locks**: File-based locks prevent concurrent modifications to the same site
- **Atomicity markers**: Mark operation phases so recovery/rollback is possible

Functions provided:
- `log_info()`, `log_warn()`, `log_error()` — structured logging
- `acquire_lock()`, `release_lock()` — mutual exclusion per site
- `die()` — fatal error with cleanup
- `run_with_timeout()` — command execution with timeout

### 2.3 Sensitive Data Handling

**Policy**: No passwords or tokens ever written to disk or logs.

- Database passwords passed via environment variables (`DB_PASS`, `WORDPRESS_DB_PASS`)
- Generated secrets (e.g., for WordPress) passed through stdin/stdout only
- Log files sanitized to remove patterns matching `password`, `token`, `key` values
- SFTP user passwords generated and returned only once (user must change on first login)
- API requests logging strips Authorization headers

---

## 3. Scripts & Responsibilities

### 3.1 Bootstrap

**Script**: `scripts/bootstrap.sh`

**Purpose**: One-shot server initialization

**Operations**:
1. Detect Ubuntu 24.04 (fail if not)
2. Update system packages
3. Resolve and install latest versions:
   - Caddy (web server)
   - PHP-FPM primary + fallback versions
   - MariaDB
   - PostgreSQL
   - Valkey
4. Configure each component:
   - Caddy: Enable auto-HTTPS, set up config template
   - PHP-FPM: Create default pools (primary + fallback), tune pools
   - MariaDB: Secure installation, set root password (passed via env)
   - PostgreSQL: Initialize user and authentication
   - Valkey: Start and enable service
5. Create directory structure:
   - `${SITES_ROOT}` (ownership: www-data)
   - `${BACKUPS_ROOT}` (ownership: root)
   - `${LOGS_DIR}` (ownership: root, perms: 0750)
6. Generate initial API token (returned, never logged)
7. Enable all services at boot
8. Write bootstrap marker file (to detect re-runs)

**Idempotency**: Re-running checks for marker file; if present, skips installation and validates only.

**Exit codes**:
- 0: Success
- 1: Non-Ubuntu 24.04 system
- 2: Missing prerequisites
- 3: Installation failure
- 4: Configuration failure

**Environment inputs**: `DB_ROOT_PASS`, `API_TOKEN_SECRET` (optional; generated if not provided)

### 3.2 Site Creation

**Script**: `scripts/site-create.sh`

**Purpose**: Provision a complete site environment

**Inputs**:
```bash
# Required
-d DOMAIN              # Fully qualified domain (e.g., example.com)
-t TYPE                # static | php | wordpress | proxy
-r OWNER_EMAIL         # For Let's Encrypt registration

# Type-specific
-p PHP_VERSION         # For php/wordpress: primary|fallback (default: primary)
-b DB_ENGINE           # For php/wordpress: mariadb|postgresql|none
-u DB_USER             # Database username (auto-generated if omitted)
-w DB_NAME             # Database name (defaults to sanitized domain)

# Proxy-specific
-x PROXY_URL           # Target URL (e.g., http://localhost:3000)

# SFTP
-s SFTP_USER           # SFTP username (defaults to <domain>_sftp)
```

**Operations per type**:

#### Static
1. Create webroot: `${SITES_ROOT}/example.com/www`
2. Create Caddy config: serve root directory
3. Create SFTP user (chrooted to `${SITES_ROOT}/example.com`)
4. Enable site in Caddy
5. Create site metadata file: `${SITES_ROOT}/example.com/.site.json`

#### PHP
1. Create webroot: `${SITES_ROOT}/example.com/www`
2. If database requested:
   - Create DB on selected engine
   - Generate strong password (not logged)
   - Create DB user with limited privileges
   - Write connection details to `${SITES_ROOT}/example.com/.db.env` (mode 0600)
3. Create PHP-FPM pool configuration (selected version)
   - Pool name: `example.com`
   - User/group: `www-data`
   - Separate socket: `/run/php/example.com.sock`
4. Create Caddy config: route to PHP-FPM socket
5. Create SFTP user
6. Reload PHP-FPM (selected version only)
7. Enable site in Caddy
8. Create site metadata

#### WordPress
1. Same as PHP, but:
2. Download WordPress core via WP-CLI (if not present)
3. **Interactive prompt**: Admin username, admin email, admin password
   - Passwords read securely from TTY (not via CLI args)
   - **API constraint**: Cannot be called from API (CLI-only)
4. Run WP-CLI installation:
   ```bash
   wp core install \
     --url=example.com \
     --title="Site Title" \
     --admin_user=... \
     --admin_email=... \
     --admin_password=... \
     --db_host=... \
     --db_name=... \
     --db_user=... \
     --db_password=... \
     --allow-root
   ```
5. Set WordPress security headers via Caddy plugin (if available)
6. Create site metadata

#### Reverse Proxy
1. Create webroot: `${SITES_ROOT}/example.com/www` (empty placeholder)
2. Create Caddy config: reverse_proxy directive
3. Create SFTP user (optional, can serve static files)
4. Create site metadata

**Site metadata** (`.site.json`):
```json
{
  "domain": "example.com",
  "type": "php",
  "created_at": "2026-06-22T10:30:00Z",
  "php_version": "8.3",
  "db_engine": "mariadb",
  "db_name": "example_db",
  "sftp_user": "example.com_sftp",
  "ssl_status": "active",
  "last_backup": "2026-06-22T09:00:00Z"
}
```

**Idempotency**: Check if domain exists; if so, report already exists and exit (1).

**Exit codes**:
- 0: Success
- 1: Site exists
- 2: Invalid domain/type
- 3: Database creation failed
- 4: PHP-FPM pool creation failed
- 5: Caddy config failed
- 6: SFTP user creation failed

### 3.3 Site Deletion

**Script**: `scripts/site-delete.sh`

**Purpose**: Remove all resources tied to a domain

**Inputs**:
```bash
-d DOMAIN              # Domain to delete
-f, --force            # Skip backup (requires confirmation)
```

**Operations**:
1. Acquire lock on domain
2. If not `--force`:
   - Create full backup (see Site Backup)
   - Archive stored in `${BACKUPS_ROOT}/example.com-$(date +%s).tar.gz`
3. If `--force`:
   - Prompt: "Delete example.com without backup? Type domain to confirm:"
   - Proceed only if user types exact domain
4. Remove resources:
   - Caddy config: `${SITES_ROOT}/example.com/Caddyfile`
   - Webroot: `${SITES_ROOT}/example.com`
   - PHP-FPM pool: `/etc/php/<version>/fpm/pool.d/example.com.conf`
   - Reload PHP-FPM if pool removed
   - SFTP user: `deluser --remove-home example.com_sftp`
   - Database (if exists): Drop database + user
5. Remove from Caddy
6. Reload Caddy
7. Remove site metadata
8. Release lock

**Retention**: Backups kept for `${BACKUP_RETENTION_DAYS}` (configurable); older backups deleted automatically.

**Exit codes**:
- 0: Success
- 1: Site not found
- 2: Lock acquisition failed
- 3: Backup creation failed
- 4: Force-delete confirmation failed
- 5: Resource removal failed

### 3.4 Site Backup

**Script**: `scripts/site-backup.sh`

**Purpose**: Archive webroot and databases

**Inputs**:
```bash
-d DOMAIN              # Specific domain (omit for all sites)
-o OUTPUT_DIR          # Output directory (default: ${BACKUPS_ROOT})
```

**Operations for single site**:
1. Create temp directory: `/tmp/vps-backup-DOMAIN-TIMESTAMP`
2. Archive webroot:
   ```bash
   tar --exclude=.cache \
       --exclude=node_modules \
       --exclude=.git \
       -czf /tmp/vps-backup-.../webroot.tar.gz \
       ${SITES_ROOT}/DOMAIN/www
   ```
3. If database exists:
   - MariaDB: `mysqldump --all-databases > db.sql`
   - PostgreSQL: `pg_dump --all > db.sql`
4. Package into final archive: `DOMAIN-$(date +%Y%m%d-%H%M%S).tar.gz`
5. Move to `${BACKUPS_ROOT}`
6. Enforce retention: Delete backups older than `${BACKUP_RETENTION_DAYS}`

**Operations for all sites**:
1. Iterate over `${SITES_ROOT}/*/.site.json`
2. Back up each site independently
3. Create index file: `backups.json` with manifest

**Archive contents**:
```
DOMAIN-20260622-103000.tar.gz
├── webroot.tar.gz
├── mariadb.sql (if applicable)
├── postgresql.sql (if applicable)
└── metadata.json
```

**Exit codes**:
- 0: Success
- 1: Site not found
- 2: Backup creation failed
- 3: Retention cleanup failed

### 3.5 Static Deployment

**Script**: `scripts/site-deploy.sh`

**Purpose**: Push local build to webroot via rsync

**Inputs**:
```bash
-d DOMAIN              # Target domain
-s SOURCE_DIR          # Local source directory (with trailing slash)
--delete               # Delete files on remote not in source
```

**Operations**:
1. Validate source directory exists
2. Validate domain exists
3. Determine SFTP user: `${DOMAIN}_sftp`
4. Rsync with ownership preservation:
   ```bash
   rsync -avz --chown=www-data:www-data \
     ${SOURCE_DIR} \
     ${DOMAIN}_sftp@localhost:${SITES_ROOT}/${DOMAIN}/www/
   ```
5. Log summary (files added, modified, deleted)

**Exit codes**:
- 0: Success
- 1: Source or domain not found
- 2: Rsync failed

### 3.6 Database Creation

**Script**: `scripts/database-create.sh`

**Purpose**: Add database to existing site

**Inputs**:
```bash
-d DOMAIN              # Existing site domain
-e ENGINE              # mariadb | postgresql
-u DB_USER             # Database username (auto-generate if omitted)
-n DB_NAME             # Database name (auto-generate if omitted)
```

**Operations**:
1. Verify site exists
2. Check if database already exists for site (error if so)
3. Generate strong password (not logged)
4. Create database on selected engine
5. Create user with limited privileges (SELECT, INSERT, UPDATE, DELETE only)
6. Write connection details to `${SITES_ROOT}/DOMAIN/.db.env` (mode 0600)
7. Return connection string (secret to stdout only)

**Exit codes**:
- 0: Success
- 1: Site not found
- 2: Database already exists for site
- 3: Database creation failed

### 3.7 Service Management

**Script**: `scripts/service-manage.sh`

**Purpose**: Unified control over all components

**Inputs**:
```bash
-a ACTION              # start | stop | restart | reload | status | list
-s SERVICE             # caddy | php-fpm-primary | php-fpm-fallback | mariadb | postgresql | valkey | all
```

**Operations**:
- **start**: `systemctl start SERVICE`
- **stop**: `systemctl stop SERVICE`
- **restart**: `systemctl restart SERVICE`
- **reload**: `systemctl reload SERVICE` (if supported)
- **status**: `systemctl status SERVICE` (output JSON)
- **list**: Show all managed services and their status

**JSON status output**:
```json
{
  "service": "caddy",
  "status": "active",
  "enabled": true,
  "uptime_seconds": 86400,
  "memory_mb": 25.5
}
```

**Exit codes**:
- 0: Success
- 1: Unknown action or service
- 2: Service operation failed

---

## 4. Utility Modules

### 4.1 Version Resolver

**File**: `scripts/utils/version-resolver.sh`

**Purpose**: Dynamically fetch latest component versions

**Functions**:
- `resolve_caddy_version()` → Latest from GitHub releases
- `resolve_php_versions()` → Two stable versions (current + previous minor)
- `resolve_mariadb_version()` → Latest stable
- `resolve_postgresql_version()` → Latest stable
- `resolve_valkey_version()` → Latest from GitHub releases

**Strategy**: Prefer official JSON APIs (GitHub Releases, package repos) over web scraping. Cache versions for 24 hours to avoid rate limits.

### 4.2 Validators

**File**: `scripts/utils/validators.sh`

**Functions**:
- `validate_domain(DOMAIN)` → Regex for FQDN
- `validate_username(USERNAME)` → No spaces, special chars, 1-32 chars
- `validate_email(EMAIL)` → Basic regex
- `validate_port(PORT)` → 1-65535
- `validate_php_version(VERSION)` → Must be installed
- `validate_db_engine(ENGINE)` → mariadb|postgresql
- `validate_site_type(TYPE)` → static|php|wordpress|proxy

---

## 5. API Design

### 5.1 Authentication

**Bearer token** in Authorization header:
```
Authorization: Bearer <token>
```

Token stored in `${LOGS_DIR}/.api.token` (mode 0600, generated at bootstrap).

Middleware in `api/auth.py` validates on every request except health check.

### 5.2 Response Schema

All endpoints return:

```json
{
  "success": true|false,
  "code": "OPERATION_COMPLETE" | "SITE_NOT_FOUND" | etc.,
  "message": "User-friendly description",
  "data": {/* operation-specific */},
  "stdout": "Command output (on success or failure)",
  "stderr": "Command errors (if any)",
  "duration_ms": 1234
}
```

### 5.3 Route Map

#### Bootstrap (One-time initialization)
- `POST /api/bootstrap` → Run bootstrap, return initial API token
  - Payload: `{"db_root_password": "..."}`
  - Response: `{"token": "..."}`
  - Status: 201 Created

#### Sites

- `POST /api/sites` → Create site
  - Payload: Full site-create options
  - Response: Site metadata + database credentials (if applicable)
  - Status: 201 Created

- `GET /api/sites` → List all sites
  - Response: Array of site metadata
  - Status: 200 OK

- `GET /api/sites/:domain` → Get site details
  - Response: Site metadata + current status
  - Status: 200 OK

- `DELETE /api/sites/:domain` → Delete site
  - Payload: `{"force": false}`
  - Response: Backup location (if backup created)
  - Status: 200 OK or 204 No Content
  - Note: No confirmation prompt (unlike CLI)

- `PATCH /api/sites/:domain/php-version` → Switch PHP version
  - Payload: `{"php_version": "8.3"|"fallback"}`
  - Response: Updated site metadata
  - Status: 200 OK

#### Databases

- `POST /api/sites/:domain/databases` → Create database for site
  - Payload: `{"engine": "mariadb"|"postgresql", "db_user": "...", "db_name": "..."}`
  - Response: Connection string (no password logged)
  - Status: 201 Created

- `GET /api/sites/:domain/databases` → List site's databases
  - Response: Array of database names
  - Status: 200 OK

#### Deployments

- `POST /api/sites/:domain/deploy` → Deploy static assets
  - Payload: `{"source_url": "s3://bucket/path", "delete": false}`
  - Note: Source is remote URL, not local; deployment script fetches
  - Response: Summary of changes
  - Status: 200 OK

#### Backups

- `POST /api/backups` → Create backup(s)
  - Payload: `{"domains": ["example.com"] or null for all}`
  - Response: Array of backup paths
  - Status: 201 Created

- `GET /api/backups` → List all backups
  - Query: `?domain=example.com` (optional filter)
  - Response: Array of backup metadata
  - Status: 200 OK

#### Services

- `GET /api/services` → Get status of all services
  - Response: Array of service statuses
  - Status: 200 OK

- `POST /api/services/:service/:action` → Control service
  - Payload: Action in URL
  - Response: Operation result + service status
  - Status: 200 OK

- `GET /api/health` → Health check (no auth required)
  - Response: `{"status": "ok", "version": "..."}`
  - Status: 200 OK

---

## 6. Design Decisions & Assumptions

### 6.1 Why Shell Scripts?

- **Rationale**: Direct OS integration without abstraction; every operation is explicit and auditible. Shell scripts can be manually run for debugging and maintenance.
- **Trade-off**: More verbose error handling; mitigated by centralized `common.sh` utilities.

### 6.2 PHP-FPM Pool Per Site

- **Rationale**: Fine-grained resource isolation and per-site configuration (memory limits, timeout, etc.).
- **Trade-off**: More processes; tuned via `pm.max_children` and dynamic pool mode.

### 6.3 SFTP Chroot Per Site

- **Rationale**: Prevents users from accessing other sites' files.
- **Implementation**: `sftp-server` with chroot jail, user home set to `${SITES_ROOT}/DOMAIN`.
- **Note**: Users can upload to webroot and non-webroot directories (e.g., backups, private files).

### 6.4 No Docker

- **Rationale**: Simplified deployment, direct resource access, and explicit system state.
- **Assumption**: All services (Caddy, PHP, MariaDB, PostgreSQL, Valkey) are native Ubuntu packages or downloaded binaries.

### 6.5 Caddy for Web Server

- **Rationale**: Automatic HTTPS, simple config, no manual certificate renewal.
- **Config approach**: Generate per-domain Caddyfile fragments, include in main config.

### 6.6 Database Password Handling

- **Design**: Passwords never written to scripts or config files; passed via environment.
- **During provisioning**: Generated securely, passed to DB engine, stored in encrypted `.db.env` file (readable only by www-data and root).
- **API constraint**: Secrets returned once; caller must store.

### 6.7 WordPress Interactive Prompts

- **Design**: Admin credentials prompted on CLI only, never exposed through API.
- **Rationale**: Prevents accidental exposure in API logs and audit trails.
- **API workaround**: Future enhancement could pre-register WordPress sites and return credentials to caller once.

### 6.8 Idempotency Strategy

- **Goal**: Scripts can be re-run without data loss or duplication.
- **Approach**:
  - Check for existing resources before creation (error if found)
  - Configuration files include checksums/markers to detect manual edits
  - Database user/password not re-generated if database exists
  - Service reloads (not restarts) to preserve connections

### 6.9 Backup Retention

- **Strategy**: Automatic cleanup of backups older than `${BACKUP_RETENTION_DAYS}`.
- **Frequency**: Triggered during site deletion and manual backup operations.
- **Assumption**: User retains important backups manually (copies to external storage).

### 6.10 Logging

- **Approach**: Unified log file with structured format (timestamp, severity, message).
- **Retention**: Logs rotated by systemd-journald or logrotate (configured separately).
- **Sensitive data**: Sanitized before logging (passwords, tokens masked).

---

## 7. Security Considerations

### 7.1 Privilege Separation

- **www-data**: Owns webroot and PHP-FPM processes; can read/write site files
- **sftp user**: Chrooted to site directory; can only upload/download files
- **root**: Owns bootstrap, service management, database access
- **API runs as**: Dedicated non-root user (`vps-api`), with sudo rules for specific scripts

### 7.2 API Token Security

- Generated at bootstrap, stored in `${LOGS_DIR}/.api.token` (mode 0600)
- Consider using short-lived JWT tokens for future enhancement
- Token rotatable via CLI command (not exposed in API)

### 7.3 SFTP User Passwords

- Generated with `openssl rand -base64 32`
- Returned to caller once during site creation
- User must change on first login (enforced by OpenSSH)

### 7.4 Database Credentials

- Never logged or printed to console
- Stored in encrypted `.db.env` file (readable only by www-data)
- Database user has minimal privileges (SELECT, INSERT, UPDATE, DELETE only)

### 7.5 API Rate Limiting & DDoS

- Not included in initial scope; can add nginx/Caddy middleware later
- Recommendation: Deploy behind reverse proxy with rate limiting

---

## 8. Implementation Phases

### Phase 1: Core Infrastructure (Week 1)
- [ ] Project structure setup
- [ ] Configuration system (config.sh)
- [ ] Common utilities (logging, error handling, locks)
- [ ] Version resolver

### Phase 2: Bootstrap & Basics (Week 2)
- [ ] bootstrap.sh (all components)
- [ ] Service management script
- [ ] Basic API structure (FastAPI, auth middleware)

### Phase 3: Site Provisioning (Week 3)
- [ ] site-create.sh (all types: static, PHP, WordPress, proxy)
- [ ] site-delete.sh
- [ ] site metadata format
- [ ] API routes for sites

### Phase 4: Databases & Backups (Week 4)
- [ ] database-create.sh
- [ ] site-backup.sh
- [ ] Backup retention logic
- [ ] API routes for databases and backups

### Phase 5: Deployment & Polish (Week 5)
- [ ] site-deploy.sh
- [ ] API deployment route
- [ ] Testing & validation
- [ ] Documentation

---

## 9. Key Questions & Clarifications

### Q1: Domain Validation Scope
Should we support:
- Wildcard domains (*.example.com)?
- Subdomains without explicit registration (e.g., api.example.com as separate site)?
- International domains (IDN)?

**Current assumption**: Only FQDN (including subdomains as top-level sites). Wildcard DNS managed outside VPS Manager.

### Q2: Multi-Server Support
Should the toolkit support managing multiple servers, or is it single-server per instance?

**Current assumption**: Single-server per instance. Multi-server would require distributed state and API federation.

### Q3: SSL/TLS Certificate Management
Caddy handles automatic HTTPS. Should we expose certificate renewal or expiry alerts via API?

**Current assumption**: Caddy manages renewals internally; API exposes only certificate status.

### Q4: Traffic Limits & Resource Quotas
Should SFTP or bandwidth be rate-limited per site?

**Current assumption**: No built-in quotas; left to system-level tools (cgroups, iptables).

### Q5: WordPress Multisite Support
Single WordPress installation per site, or support multisite networks?

**Current assumption**: Single installation per domain.

### Q6: Development vs. Production
Should the toolkit support staging/development mode per site (e.g., disable caching, enable debug mode)?

**Current assumption**: Not in initial scope; configuration managed within application (e.g., via wp-config.php).

### Q7: API Documentation
OpenAPI/Swagger specs required?

**Current assumption**: Plain Markdown API docs initially; OpenAPI schema can be auto-generated from FastAPI.

---

## 10. Technology Stack Summary

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| **Web Server** | Caddy | Auto HTTPS, minimal config, Go-based (statically compiled) |
| **PHP Runtime** | PHP-FPM (2 versions) | Flexible, per-site pools, wide compatibility |
| **Database (SQL)** | MariaDB + PostgreSQL | Choice per site; both stable and widely supported |
| **Cache** | Valkey | Drop-in Redis replacement; actively maintained |
| **Scripts** | Bash (POSIX + GNU extensions) | Installed by default, maximum portability |
| **API** | FastAPI (Python 3.10+) | Async, minimal dependencies, great DX |
| **Scripting Lang** | Bash for ops, Python for API | Best tool for each domain |

---

## 11. Next Steps

1. **Feedback on this plan**: Confirm assumptions, address questions 1-7, identify gaps
2. **Skeleton implementation**: Create directory structure and basic config.sh
3. **Bootstrap.sh first**: Get the stack installed and running
4. **Iterative development**: One script + corresponding API routes per sprint
5. **Testing strategy**: Manual testing on staging VM, then automated test suite

---

## Appendix A: Example Workflows

### Create a Static Site
```bash
./scripts/site-create.sh -d cdn.example.com -t static -r admin@example.com
# Creates webroot, Caddy config, SFTP user
# User can now rsync files to the site
```

### Create a PHP Site with Database
```bash
./scripts/site-create.sh \
  -d app.example.com \
  -t php \
  -p primary \
  -b mariadb \
  -r admin@example.com
# Creates webroot, PHP-FPM pool, database, Caddy config, SFTP user
# App can read DB credentials from .db.env
```

### Install WordPress
```bash
./scripts/site-create.sh \
  -d blog.example.com \
  -t wordpress \
  -r admin@example.com
# Interactive prompts for admin username, email, password
# WordPress installed and ready to use
```

### Deploy Static Assets
```bash
./scripts/site-deploy.sh \
  -d cdn.example.com \
  -s ./build/ \
  --delete
# Syncs ./build to site webroot, removes missing files
```

### Delete Site with Backup
```bash
./scripts/site-delete.sh -d old-site.example.com
# Backs up webroot + databases to ${BACKUPS_ROOT}
# Removes all site resources
# Old backups (>30 days) automatically cleaned
```

### API Usage Example: Create Site
```bash
curl -X POST http://localhost:8000/api/sites \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "domain": "shop.example.com",
    "type": "php",
    "owner_email": "admin@example.com",
    "php_version": "primary",
    "db_engine": "mariadb"
  }'
# Response includes database credentials (one-time)
```

---

**Document Version**: 1.0  
**Last Updated**: June 22, 2026  
**Status**: Ready for Implementation
