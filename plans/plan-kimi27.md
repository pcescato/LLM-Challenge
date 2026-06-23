# VPS Manager — Implementation Plan

## 1. Project Structure

```
vps-manager/
├── config/
│   └── vps-manager.conf          # Single source of truth for tunables
├── lib/
│   ├── common.sh                 # Shared helpers: logging, idempotency, secrets, DB utilities
│   ├── version-resolver.sh       # Resolve current package versions from official sources
│   └── validators.sh             # Domain, user, version, path validation helpers
├── scripts/
│   ├── bootstrap.sh              # One-shot server bootstrap
│   ├── site/
│   │   ├── create.sh             # Provision a new site
│   │   ├── delete.sh             # Remove a site (with auto-backup + optional skip)
│   │   ├── backup.sh             # Backup one or all sites
│   │   ├── deploy-static.sh      # rsync a local build to a static site webroot
│   │   └── add-database.sh       # Add a database to an existing site
│   └── service/
│       └── control.sh            # Start/stop/restart/reload/status for components
├── api/
│   ├── main.py                   # FastAPI application
│   ├── auth.py                   # Bearer token dependency
│   ├── models.py                 # Pydantic request/response models
│   └── executor.py               # Shell script invocation and response mapping
├── systemd/
│   └── vps-manager-api.service   # Systemd unit for the API service
├── logs/                         # Runtime log directory (created on bootstrap)
└── plan.md                       # This document
```

## 2. Script Inventory & Responsibilities

### Config
- **`config/vps-manager.conf`**
  - Base paths (`SITES_ROOT`, `LOG_DIR`, `BACKUP_DIR`)
  - Component selection flags (`INSTALL_MARIADB`, `INSTALL_POSTGRES`, `INSTALL_VALKEY`)
  - Current + fallback PHP version *detection rules* (not hardcoded numbers)
  - Backup retention period in days
  - Default Caddy/global settings
  - External version URLs/repos for dynamic resolution
  - API bind host/port (for reference; token is provided via env var only)

### Library/Shared
- **`lib/common.sh`**
  - Source the config once and validate required variables
  - Logging: write structured log lines to `LOG_DIR/vps-manager.log` without ever echoing secrets
  - Idempotency primitives: `ensure_dir`, `ensure_user`, `ensure_service`, `file_exists_p`
  - Secrets: generate random passwords/credentials in memory only; pass to WP-CLI/DB clients via environment variables or process substitution; never write to temp files
  - Error handling: `die`, `trap` cleanup, strict mode (`set -euo pipefail`)
  - Component status helpers

- **`lib/version-resolver.sh`**
  - Resolve latest stable versions at install time from official upstreams:
    - Caddy: `https://api.github.com/repos/caddyserver/caddy/releases/latest`
    - PHP: `https://packages.sury.org/php/dists/` (Ubuntu) or `ondrej/php` PPA metadata
    - MariaDB: `https://mariadb.org/download/?t=repo` or repository metadata
    - PostgreSQL: `https://apt.postgresql.org/pub/repos/apt/dists/`
    - Valkey: `https://api.github.com/repos/valkey-io/valkey/releases/latest`
    - WP-CLI: `https://api.github.com/repos/wp-cli/wp-cli/releases/latest`
  - Cache resolved versions for the duration of bootstrap only (in memory); no persistence

- **`lib/validators.sh`**
  - Validate FQDN format and uniqueness
  - Validate Linux username format and uniqueness
  - Validate PHP version string against installed pool versions
  - Validate site type against allowed set

### Operational Scripts
- **`scripts/bootstrap.sh`**
  - Run on clean Ubuntu 24.04 as root
  - Update system and install dependencies (`curl`, `gnupg`, `rsync`, `jq`, etc.)
  - Add official APT repositories (Caddy, Ondrej PHP Sury, MariaDB, PostgreSQL)
  - Resolve versions dynamically via `lib/version-resolver.sh` and install:
    - Caddy
    - Current PHP-FPM + common extensions
    - Fallback PHP-FPM (configurable rule, e.g., previous major) + common extensions
    - MariaDB server/client
    - PostgreSQL server/client
    - Valkey server
    - WP-CLI (for WordPress sites)
  - Configure base services:
    - Caddy global config + snippet for PHP upstreams
    - MariaDB/PG hardening (bind to localhost, secure defaults)
    - Valkey supervised systemd
    - Default PHP-FPM pools (`www` disabled or restricted)
  - Create directory layout: `SITES_ROOT`, `BACKUP_DIR`, `LOG_DIR`
  - Create API user, install Python deps, configure systemd unit
  - Mark bootstrap completion flag
  - Idempotent: safe to re-run; skips already-installed components or re-applies harmless config

- **`scripts/site/create.sh <domain> <type> [options]`**
  - Validate domain and type (static, php, wordpress, reverse_proxy)
  - Create Linux user (e.g., `site-<domainhash>`) for SFTP with chroot to site webroot
  - Create webroot directory with correct ownership
  - Generate or accept database flag:
    - For WordPress: database + user always created
    - For PHP: optional `--database`
    - Static/Reverse proxy: no database
  - Select PHP version:
    - `--php-version current|fallback|<version>`
    - Create dedicated PHP-FPM pool only if type is `php` or `wordpress`
  - For reverse proxy: accept `--upstream http://127.0.0.1:<port>` and skip PHP
  - Render Caddy site config in `/etc/caddy/sites/<domain>.Caddyfile` and include it
  - For WordPress: download core via WP-CLI, create `wp-config.php` from env vars (credentials not logged), then stop and require interactive CLI to finalize admin account
  - Reload Caddy
  - Output JSON summary (excluding credentials)

- **`scripts/site/delete.sh <domain> [--skip-backup]`**
  - If `--skip-backup` is passed, require interactive confirmation `YES`
  - Otherwise, automatically create a full backup via `scripts/site/backup.sh` first
  - Remove Caddy site config and reload Caddy
  - Stop and remove dedicated PHP-FPM pool if present
  - Remove SFTP user and home/chroot directory
  - Drop database and database user if they exist
  - Delete backups older than retention period (configurable)
  - Output result and backup path (if applicable)

- **`scripts/site/backup.sh <domain>|--all`**
  - Timestamped archive in `BACKUP_DIR/<domain>/YYYY-MM-DD_HH-MM-SS.tar.gz`
  - Include webroot (recursively, excluding caches)
  - If MariaDB/PG database exists, dump it into archive without writing password to shell history/logs
  - If `--all`: iterate over all sites in `SITES_ROOT`
  - Optionally purge backups older than retention days with `--prune`
  - Output archive path

- **`scripts/site/deploy-static.sh <domain> <source-path>`**
  - Validate domain is type `static`
  - rsync local source path to site webroot
  - Set ownership/permissions
  - Optionally clear Valkey cache keys prefixed by domain
  - Output summary

- **`scripts/site/add-database.sh <domain> [--engine mariadb|postgres]`**
  - Create database and database user for an existing site
  - Generate random password in memory and print (CLI only) or return masked
  - Update site metadata so backups/deletion know about the new DB
  - Optionally create/update `wp-config.php` for WordPress if missing DB credentials

- **`scripts/service/control.sh <component> <action>`**
  - Components: `caddy`, `php-<version>`, `mariadb`, `postgresql`, `valkey`, `all`
  - Actions: `start`, `stop`, `restart`, `reload`, `status`
  - Map PHP component names to installed PHP-FPM service units
  - For `all`, run sequentially with dependency-aware ordering and aggregate results
  - Print tabular/status output

## 3. API Route Map

Base URL: `http://<host>:<port>`  
Authentication: `Authorization: Bearer <TOKEN>` (token read from env `VPS_MANAGER_API_TOKEN`)

### Common Response Shape

```json
{
  "success": true,
  "exit_code": 0,
  "stdout": "...",
  "stderr": "..."
}
```

HTTP status mapping:
- `exit_code == 0` → `200 OK`
- validation/config error → `400 Bad Request`
- auth failure → `401 Unauthorized`
- resource not found → `404 Not Found`
- any non-zero script exit → `422 Unprocessable Entity` (or `500` for internal/exec failure)

### Endpoints

| Method | Route | Script | Notes |
|--------|-------|--------|-------|
| `POST` | `/bootstrap` | `scripts/bootstrap.sh` | Idempotent; returns when finished |
| `POST` | `/sites` | `scripts/site/create.sh` | Body: domain, type, php_version, database, upstream, etc. Not allowed for WordPress interactive install; WordPress type returns webroot/core ready but marks admin setup as CLI-only. |
| `DELETE` | `/sites/{domain}` | `scripts/site/delete.sh` | Backup runs automatically unless `?skip_backup=true` — then rejected by design (API never allows skip). |
| `POST` | `/sites/{domain}/backup` | `scripts/site/backup.sh <domain>` | Returns archive path |
| `POST` | `/backup/all` | `scripts/site/backup.sh --all` | Returns list of archive paths |
| `POST` | `/sites/{domain}/deploy-static` | `scripts/site/deploy-static.sh` | Accept a ZIP/tar upload or remote rsync source spec; unpack/sync to webroot |
| `POST` | `/sites/{domain}/database` | `scripts/site/add-database.sh` | Body: engine (default mariadb). Credentials returned once, then not stored/logged. |
| `GET` | `/services/{component}/status` | `scripts/service/control.sh <component> status` | |
| `POST` | `/services/{component}/{action}` | `scripts/service/control.sh <component> <action>` | action ∈ {start, stop, restart, reload} |
| `GET` | `/health` | Inline FastAPI probe | Returns API health, not full stack health |

### WordPress API Restriction
- The endpoint `POST /sites` accepts type `wordpress` but only downloads WordPress, creates DB/user, writes `wp-config.php` (values injected in-memory), and creates the Caddy/PHP pool config.
- It intentionally **does not** run the final `wp core install` step.
- Final admin credentials must be supplied interactively on the server via `wp core install` on the CLI.
- The API response includes a message: `WordPress downloaded. Complete installation via CLI with wp core install --url=...`.

## 4. Assumptions & Design Decisions

1. **Target OS**: Scripts target a fresh Ubuntu 24.04 LTS server. Adapting to Debian would be minor; other distros out of scope.

2. **Root execution**: All scripts require root and refuse to run otherwise. The FastAPI service runs as an unprivileged user and uses passwordless sudoers entries restricted to the exact `vps-manager` script paths.

3. **No Docker**: Every service is installed natively via APT and runs under systemd.

4. **Dynamic versions**: Versions are resolved at bootstrap time by querying upstream APT metadata or GitHub releases. The config file stores *rules* (e.g., `PHP_CURRENT=latest`, `PHP_FALLBACK=previous-major`) rather than literal version strings.

5. **PHP pool isolation**: Each PHP/WordPress site gets its own PHP-FPM pool file owned by the site user, running as that user, listening on a Unix socket. Static and reverse-proxy sites do not spawn a pool.

6. **Database Engines**:
   - WordPress only supports MariaDB (MySQL-compatible).
   - PHP sites may choose MariaDB or PostgreSQL.
   - Both servers are installed; provisioning decides which to use.

7. **SFTP chroot**: One system user per site, chrooted to its webroot. SSH password login is disabled; authorized SSH keys only. Site users cannot log in interactively (`/bin/false`).

8. **Idempotency**: Every script checks existing state before creating/changing. Re-running bootstrap or create should be safe.

9. **Secrets discipline**:
   - API token comes only from the env var `VPS_MANAGER_API_TOKEN` (not config file on disk in plain text; optionally read from systemd `EnvironmentFile`).
   - Database passwords are generated with `openssl rand`, passed through env vars, and printed exactly once. They are never logged or persisted.
   - WP-CLI commands receive DB credentials via exported env variables or via `--dbpass=<(echo)` process substitution, never command-line flags in `ps`.

10. **Log handling**: Operational scripts log actions to `LOG_DIR/vps-manager.log`. The API logs requests (method, path, status, exit code) but never bodies containing credentials.

11. **Backups**: Backups include webroot + DB dump and are stored locally under `BACKUP_DIR`. Retention pruning happens on delete and can be run manually via backup script `--prune`.

12. **Caddy configuration**: Each site gets its own file under `/etc/caddy/sites/` included by the global Caddyfile. SSL is automatic (Let’s Encrypt/ZeroSSL via Caddy defaults).

13. **Static deployment via API**: For simplicity, the API accepts an uploaded archive (ZIP or tar.gz) and extracts it into the site webroot; CLI version supports direct rsync from a local source path.

14. **No multi-server/replication**: Single-server deployment only.

## 5. Open Questions

Before implementation begins, please confirm:

1. **API token provisioning**: Should the bootstrap script generate and print the initial API token, or will you supply one via environment/cloud-init? Should it be rotated periodically?

2. **Default domain for bootstrap validation (Caddy)**: Should bootstrap install a placeholder or default catch-all site, or leave Caddy without any site until the first `create`?

3. **PHP version selection granularity**: Is selecting per site between current/fallback sufficient, or do you need arbitrary PHP versions installed side-by-side?

4. **Backup destination**: Should backups be kept only locally, or do you also need off-site/sync targets (S3, rsync.net, etc.) from day one?

5. **Reverse proxy upstream validation**: Should the toolkit verify that the upstream port is actually listening, or trust the provided URL?

6. **WordPress CLI-only install**: Is the proposed trade-off acceptable (API prepares site, admin setup only via SSH/CLI), or do you want a separate non-interactive API flow with credentials provided in the request?

7. **MariaDB vs PostgreSQL default**: For optional DB on PHP sites, which engine should be the default?

8. **Log retention**: Should logs have their own retention/rotation policy, or is a fixed 30-day window acceptable?

9. **Monitoring/alerts**: Is basic service status via API enough, or should bootstrap also install a simple health dashboard/metric exporter?

10. **Naming convention for site users**: Is `site-<short_hash>` acceptable, or do you prefer a different prefix/pattern?
