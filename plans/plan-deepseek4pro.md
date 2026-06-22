# VPS Manager — Implementation Plan

---

## 1. Project Structure

```
/opt/vps-manager/
├── config.conf                  # Centralized configuration (all tunables)
├── scripts/
│   ├── lib/
│   │   ├── common.sh            # Shared: logging, config loader, secret generation, TTY guard
│   │   ├── caddy.sh             # Caddy config helpers (template render, validate, reload)
│   │   ├── php.sh               # PHP-FPM pool management (create, remove, version detection)
│   │   ├── database.sh          # DB helpers (create/drop user + database for both engines)
│   │   ├── sftp.sh              # SFTP-only user creation, chroot setup, removal
│   │   └── wordpress.sh         # WP-CLI wrapper (core download, config, install)
│   ├── bootstrap.sh             # Full stack installation & configuration
│   ├── site/
│   │   ├── provision.sh         # Create site environment (webroot, config, pool, db, sftp, wp)
│   │   ├── delete.sh            # Backup → remove all site resources
│   │   └── list.sh              # Enumerate managed sites with metadata
│   ├── database/
│   │   └── create.sh            # On-demand database + user creation for existing site
│   ├── deploy/
│   │   └── static.sh            # rsync local build → remote webroot
│   ├── backup/
│   │   ├── create.sh            # Archive webroot + DB dump (single site or all)
│   │   └── cleanup.sh           # Purge backups older than retention period (cron)
│   └── service/
│       └── manage.sh            # systemctl wrapper: start|stop|restart|reload|status
├── api/
│   ├── main.py                  # FastAPI app entrypoint, uvicorn launch
│   ├── dependencies.py          # Bearer token verification dependency
│   ├── routes.py                # All route handlers
│   └── models.py                # Pydantic request/response schemas
├── templates/
│   ├── caddy/
│   │   ├── static.conf          # Caddyfile fragment — static site
│   │   ├── php.conf             # Caddyfile fragment — PHP site
│   │   ├── wordpress.conf       # Caddyfile fragment — WordPress
│   │   └── proxy.conf           # Caddyfile fragment — reverse proxy
│   └── php/
│       └── pool.conf            # PHP-FPM pool template
├── sites/                       # Parent directory for all site webroots
│   └── <domain>/
│       ├── webroot/             # Document root (chroot target for SFTP)
│       └── .db-secrets          # 0600, root-only: DB host/port/user/pass/dbname
├── backups/                     # Backup archive storage
├── logs/                        # Runtime logs (rotate via logrotate)
└── README.md                    # Operations guide
```

Config file layout (`config.conf`):

```ini
# ---- Paths ----
SITES_ROOT="/opt/vps-manager/sites"
BACKUP_ROOT="/opt/vps-manager/backups"
LOG_DIR="/opt/vps-manager/logs"
TEMPLATE_DIR="/opt/vps-manager/templates"
CADDY_CONFIG_DIR="/etc/caddy"
PHP_POOL_DIR="/etc/php/<version>/fpm/pool.d"      # resolved at runtime

# ---- Retention ----
BACKUP_RETENTION_DAYS=7

# ---- PHP ----
PHP_CURRENT=""         # resolved at bootstrap time (e.g. 8.3)
PHP_FALLBACK=""        # resolved at bootstrap time (e.g. 8.1)

# ---- Database ----
DB_DEFAULT_ENGINE="mariadb"    # "mariadb" | "postgresql"

# ---- SFTP ----
SFTP_CHROOT_BASE="/opt/vps-manager/sites"

# ---- API ----
API_TOKEN=""           # generated at bootstrap, stored 0600
API_HOST="127.0.0.1"
API_PORT="8080"

# ---- WordPress ----
WP_CLI_PATH="/usr/local/bin/wp"
```

---

## 2. Script Inventory & Responsibilities

### 2.1 `bootstrap.sh`
- **Purpose**: Install and configure the full stack on a clean Ubuntu 24.04 server.
- **Steps**:
  1. Add Caddy, PHP, MariaDB, PostgreSQL, Valkey official repos if needed.
  2. Resolve latest available package versions via `apt-cache policy`; write `PHP_CURRENT` and `PHP_FALLBACK` into `config.conf`.
  3. Install: `caddy`, `php{PHP_CURRENT}-fpm` + extensions, `php{PHP_FALLBACK}-fpm` + extensions, `mariadb-server`, `postgresql`, `valkey-server`, `wp-cli`, `rsync`, `openssh-server`.
  4. Configure each service: set listen addresses, socket paths, default charset/collation.
  5. Secure MariaDB + PostgreSQL (set root passwords, remove test DBs, restrict remote access).
  6. Generate API token, write to `config.conf` with `0600`.
  7. Grant the API token to a `vps-manager` system user for script execution.
  8. Create directory structure (`sites/`, `backups/`, `logs/`).
  9. Set up `logrotate` for the logs directory.
  10. Install `vps-manager-api.service` systemd unit.
- **Idempotency**: Checks if packages are installed, repos are configured, directories exist before each step.
- **Side effects**: Prints API token to stdout once; never logs it.

### 2.2 `site/provision.sh`
- **Purpose**: Create a fully functional site environment.
- **Arguments**: `--domain`, `--type` (static|php|wordpress|proxy), `--php-version` (current|fallback, required for php/wordpress), `--database-engine` (mariadb|postgresql, optional for php/wordpress), `--proxy-port` (required for proxy), `--db-name` (optional override).
- **Steps**:
  1. Validate domain format and ensure it doesn't already exist.
  2. Create webroot: `$SITES_ROOT/<domain>/webroot/`.
  3. Render Caddy config from template, link into `/etc/caddy/sites-available/`, enable.
  4. If type is php/wordpress: create PHP-FPM pool under correct version's pool.d, restart FPM.
  5. If type requires database: generate random credentials, create database + user via `database.sh` helpers, write to `<site>/.db-secrets` (0600).
  6. If type is wordpress: download core via WP-CLI, generate `wp-config.php` from db-secrets. If running interactively (TTY detected), prompt for admin user/email/password and complete install. If non-interactive, skip WP install step (CLI-only per spec).
  7. Create SFTP user, chroot to `$SITES_ROOT/<domain>/`.
  8. Reload Caddy.
- **Idempotency**: Returns success if site already exists with same configuration.

### 2.3 `site/delete.sh`
- **Purpose**: Remove all resources for a domain, with mandatory backup.
- **Arguments**: `--domain`, `--force` (skip backup), `--yes` (skip confirmation prompt when used with `--force`).
- **Steps**:
  1. Verify domain exists.
  2. Unless `--force`: run `backup/create.sh --domain <domain>` to create full backup.
  3. If `--force` and not `--yes`: prompt "Delete <domain> without backup? [y/N]" (TTY required).
  4. Remove Caddy config, reload Caddy.
  5. Remove PHP-FPM pool if present, restart FPM.
  6. Drop database + user if `.db-secrets` exists.
  7. Remove SFTP user.
  8. Remove `$SITES_ROOT/<domain>/` directory.
- **Idempotency**: Returns success if domain doesn't exist.

### 2.4 `site/list.sh`
- **Purpose**: Output JSON list of all managed sites.
- **Arguments**: `--format` (json|table, default json for API).
- **Steps**: Scan `$SITES_ROOT/` for directories, read each site's type from its Caddy config fragment, detect PHP pool, database engine from `.db-secrets`.
- **Output**: `[{"domain": "...", "type": "...", "php_version": "...", "database_engine": "...", "created_at": "..."}]`

### 2.5 `database/create.sh`
- **Purpose**: Add a database to an existing site that didn't get one at provision time.
- **Arguments**: `--domain`, `--engine` (mariadb|postgresql), `--db-name` (optional).
- **Steps**:
  1. Verify site exists and has no existing database.
  2. Generate credentials, create database + user, write `.db-secrets` (0600).
  3. For WordPress sites: regenerate `wp-config.php` with new credentials.
- **Idempotency**: Fail if `.db-secrets` already exists (use `--recreate` to force).

### 2.6 `deploy/static.sh`
- **Purpose**: Push a local static build to a site's webroot.
- **Arguments**: `--domain`, `--source` (local path), `--delete` (remove extraneous files at destination).
- **Steps**:
  1. Verify site exists and is type `static` or `php` (static deploy should work for PHP sites too for asset updates).
  2. `rsync -avz --chown=<sftp-user>:<sftp-user> $source/ $SITES_ROOT/<domain>/webroot/`.
  3. If `--delete`, add `--delete` to rsync.
- **Idempotency**: rsync is idempotent by nature.

### 2.7 `backup/create.sh`
- **Purpose**: Archive webroot and database dumps.
- **Arguments**: `--domain` (optional, omit for all sites), `--output-dir` (optional override).
- **Steps**:
  1. If `--domain`: backup single site. Otherwise: iterate all sites.
  2. For each site: `tar -czf $BACKUP_ROOT/<domain>-<timestamp>.tar.gz -C <site-dir> webroot/`.
  3. If `.db-secrets` exists: read credentials, dump database into tar or as companion `.sql`/`.dump` file.
  4. Output JSON: `{"backups": [{"domain": "...", "file": "...", "size_bytes": N, "created_at": "..."}]}`.
  5. Run `backup/cleanup.sh` automatically afterward to enforce retention.
- **Idempotency**: Always creates a new archive; never overwrites.

### 2.8 `backup/cleanup.sh`
- **Purpose**: Delete backups older than `BACKUP_RETENTION_DAYS`.
- **Steps**: Find files in `$BACKUP_ROOT` older than retention, delete them, output count of removed files.
- **Idempotency**: Safe to run repeatedly.

### 2.9 `service/manage.sh`
- **Purpose**: Control systemd services.
- **Arguments**: `--service` (caddy|php<PID>-fpm|mariadb|postgresql|valkey|all), `--action` (start|stop|restart|reload|status).
- **Steps**: Map `--service` to systemd unit names, run `systemctl <action> <unit>`. For `all`, run sequentially and aggregate results.
- **Output**: JSON with per-service status and exit code.

---

## 3. API Route Map

All routes prefixed with `/api/v1`. Authentication via `Authorization: Bearer <token>` header.

| Method   | Route                              | Script Wrapped              | Notes                                       |
|----------|------------------------------------|-----------------------------|---------------------------------------------|
| `POST`   | `/bootstrap`                       | `bootstrap.sh`              | One-time; idempotent. Returns stack status. |
| `POST`   | `/sites`                           | `site/provision.sh`         | WordPress type allowed but WP install is skipped (non-interactive). |
| `GET`    | `/sites`                           | `site/list.sh`              | Returns array of site objects.              |
| `GET`    | `/sites/{domain}`                  | `site/list.sh --domain`     | Single site details.                        |
| `DELETE` | `/sites/{domain}`                  | `site/delete.sh`            | `?force=true` query param for skip-backup.  |
| `POST`   | `/sites/{domain}/database`         | `database/create.sh`        | Body: `{"engine": "mariadb", "db_name": "..."}` |
| `POST`   | `/sites/{domain}/deploy`           | `deploy/static.sh`          | Multipart or JSON with `source_path` (must be server-local). |
| `POST`   | `/backups`                         | `backup/create.sh`          | Body: `{"domain": "..."}` or `{}` for all. |
| `GET`    | `/backups`                         | *(ls + stat on backup dir)* | List existing backup files with metadata.   |
| `POST`   | `/services/{service}/manage`       | `service/manage.sh`         | Body: `{"action": "restart"}`.              |
| `GET`    | `/services`                        | `service/manage.sh`         | Action=`status`, service=`all`.             |
| `GET`    | `/services/{service}`              | `service/manage.sh`         | Action=`status` for single service.         |

**Response format** (all routes):
```json
{
  "success": true,
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "data": { /* route-specific payload */ }
}
```

HTTP status codes: `200` on script exit 0, `400` on validation error, `409` on resource conflict, `500` on script failure (exit ≠ 0).

---

## 4. Design Decisions & Assumptions

### 4.1 Version Resolution
At bootstrap, each package's available version is resolved via `apt-cache policy <pkg> | grep Candidate`. PHP versions are sorted; the highest two become `PHP_CURRENT` and `PHP_FALLBACK`. Caddy uses its official Cloudsmith repo to ensure latest. MariaDB, PostgreSQL, Valkey use Ubuntu 24.04 default repos.

### 4.2 Security Model
- **Credentials**: DB passwords and API token generated via `openssl rand -hex 32`. Not passed as CLI arguments (passed via heredoc or temporary file descriptor). Not logged.
- **File permissions**: `.db-secrets` files are `0600` owned by `root:root`. `config.conf` is `0600`.
- **SFTP**: Each site user is shell-less (`/usr/sbin/nologin`), chrooted via `Subsystem sftp internal-sftp` and `Match Group sftpusers` block in `/etc/ssh/sshd_config`. Bind mounts for shared resources (if needed) are avoided — each site is fully self-contained.
- **API token**: Stored in `config.conf` with `0600`. FastAPI reads it from config on startup. No environment variable fallback to avoid leaking in `/proc`.

### 4.3 WordPress Constraints
- WP-CLI is the only interface for WordPress operations.
- `wp core install` requires interactive TTY for admin credentials. The API route for WordPress creation skips this step and returns a warning instructing the user to SSH in and run the install manually.
- WP always uses MariaDB in this setup. PostgreSQL + WordPress is possible but poorly supported; we default to MariaDB for WP and don't offer PostgreSQL as a WordPress DB option.

### 4.4 Caddy Configuration
- Each site gets its own Caddyfile fragment in `/etc/caddy/sites-available/<domain>.conf`.
- Enabled sites are symlinked from `/etc/caddy/sites-enabled/`.
- The main `/etc/caddy/Caddyfile` has a global `import /etc/caddy/sites-enabled/*`.
- Automatic HTTPS via Caddy's built-in ACME client. No cert management needed.

### 4.5 PHP-FPM Pools
- Each PHP/WordPress site gets a dedicated pool listening on a Unix socket: `/run/php/<domain>.sock`.
- Pool runs as the site's SFTP user for filesystem permission alignment.
- `pm=ondemand` with conservative `pm.max_children` to limit memory on small VPS.

### 4.6 Database Engine Selection
- Default engine is MariaDB (configurable in `config.conf`).
- For PHP sites: if `--database-engine` not specified, use the default.
- For WordPress: always MariaDB.
- Site deletion reads `.db-secrets` to know which engine to drop from.

### 4.7 Backup Strategy
- Full backup = `tar.gz` of webroot + individual DB dump file, both in a single archive.
- Naming: `<domain>-<ISO8601-timestamp>.tar.gz`.
- Retention enforced by `backup/cleanup.sh`, which can be run as a daily cron job.
- Deletion always backs up first (opt-out requires `--force --yes`).

### 4.8 Logging
- All scripts write to `$LOG_DIR/<script-name>-<YYYY-MM-DD>.log`.
- Format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`.
- Levels: INFO, WARN, ERROR.
- Sensitive values are redacted by the logging helper (matches patterns for passwords, tokens).
- `logrotate` config: daily rotation, 30-day retention, compress.

### 4.9 Idempotency
Every script checks current state before acting:
- Package installs → `dpkg -l` check.
- Directory creation → `[ -d ... ]` check.
- Service config → file existence check.
- DB/user creation → query for existence first.
- All scripts can be safely re-run.

### 4.10 Error Handling
- `set -euo pipefail` in all bash scripts.
- Trap `ERR` to log stack trace.
- Scripts exit with distinct codes: 0=success, 1=general error, 2=invalid args, 3=permission denied, 4=resource exists, 5=resource not found.
- API maps these to HTTP status codes.

---

## 5. Open Questions

1. **Database default preference**: Should `database/create.sh` default to MariaDB or require `--engine` to always be explicit? Leaning toward: default to `config.conf`'s `DB_DEFAULT_ENGINE` with an override flag.

2. **WordPress + PostgreSQL**: Should we support it at all, or hard-require MariaDB for WP? Recommendation: MariaDB only — WP's PostgreSQL support via `pg4wp` is niche and fragile.

3. **API token distribution**: Auto-generate at bootstrap and print once, or let the admin set it before bootstrap? Leaning toward: auto-generate, print once, admin can rotate by editing `config.conf`.

4. **SFTP chroot scope**: Chroot to `$SITES_ROOT/<domain>/` (contains `webroot/` and `.db-secrets`), or chroot to `webroot/` directly? Leaning toward: site directory so the SFTP user can see their full site scope (but `.db-secrets` stays 0600 root-owned regardless).

5. **Backup retention default**: 7 days reasonable for a small VPS? Or 14/30? Depends on disk constraints.

6. **Static deploy source**: Should the deploy script expect a local build directory on the server, or support pulling from a remote source (scp/rsync over SSH)? The brief says "push a local build" — assuming source is already on the server at a known path.

7. **Service enable/disable**: Should `service/manage.sh` also support `enable` and `disable` (systemd enable/disable) beyond start/stop/restart/reload/status?

8. **Multi-site backup all**: When backing up all sites, should each site get its own archive (current plan) or one combined archive? Recommendation: individual archives — easier to restore selectively.

9. **Site deletion — soft vs hard**: Hard delete (remove everything, backup is the only remnant). No soft-delete/archive. This matches the brief's "remove all resources."

10. **Monitoring/health checks**: Out of scope for this phase, but worth noting that a `/health` endpoint on the API would be useful. Should I include it?

---

## 6. Implementation Phasing (Recommended)

| Phase | Scope | Effort |
|-------|-------|--------|
| **1** | `common.sh`, `config.conf`, `bootstrap.sh`, `service/manage.sh` | Foundation — get the stack running |
| **2** | `caddy.sh`, `php.sh`, `sftp.sh`, `site/provision.sh`, `site/list.sh`, `site/delete.sh` | Core site lifecycle |
| **3** | `database.sh`, `database/create.sh`, `wordpress.sh` | Database + WordPress support |
| **4** | `backup/create.sh`, `backup/cleanup.sh`, `deploy/static.sh` | Backup + deployment |
| **5** | FastAPI: `main.py`, `dependencies.py`, `routes.py`, `models.py` | API layer |
| **6** | Integration testing, README, `logrotate` config, systemd units | Polish |

---

*Generated for planning review. No implementation has begun.*