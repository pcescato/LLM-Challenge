# VPS Manager — Implementation Plan

## 1. Project Structure

```
/opt/vpsmgr/
├── etc/
│   ├── vpsmgr.conf            # Single sourced config (paths, versions, ports, retention)
│   └── skel/
│       ├── public_html/       # Static landing page skeleton
│       └── .ssh/              # Authorized keys template
├── lib/                       # Shell scripts (all functions, no main)
│   ├── common.sh              # Logging, config loader, password gen, validation
│   ├── bootstrap.sh           # Full-stack install: Caddy, PHP-FPM, MariaDB, PG, Valkey, WP-CLI
│   ├── site-create.sh         # Provision: webroot, Caddy conf, PHP pool, DB+user, SFTP user
│   ├── site-delete.sh         # Teardown: backup → remove all resources per domain
│   ├── site-db.sh             # Create / drop database on an existing site
│   ├── site-deploy.sh         # rsync a local build into webroot
│   ├── backup.sh              # Archive webroot + DB dump (single or all sites)
│   └── service.sh             # Systemctl wrapper for any component
├── var/
│   ├── log/                   # Operation logs, one file per day
│   ├── backup/                # Per-site tarballs + SQL dumps
│   └── run/                   # PID files, temp tokens
├── api/                       # FastAPI application
│   ├── main.py                # App factory, exception handlers, cli-only guard
│   ├── auth.py                # Bearer token dependency (token from env var)
│   ├── schemas.py             # Pydantic request/response models
│   ├── executor.py            # Subprocess runner → JSON stdout/stderr/exit
│   ├── routes/
│   │   ├── __init__.py
│   │   ├── sites.py           # CRUD + deploy for sites
│   │   ├── databases.py       # DB sub-ops for sites
│   │   ├── backups.py         # Backup trigger + listing
│   │   └── services.py        # Service control
│   └── requirements.txt       # fastapi[standard], pydantic
├── bin/
│   ├── vpsmgr                 # Symlink target → dispatches subcommands to lib scripts
│   └── vpsmgr-completion      # Bash completions
├── install.sh                 # Idempotent setup: create dirs, users, perms, venv, symlink
└── README.md                  # Only if user asks for it
```

## 2. Script Responsibilities

### `common.sh` — shared library (idempotent, sourced, never executed alone)

- Source `/opt/vpsmgr/etc/vpsmgr.conf`
- `log_info`, `log_error`, `log_debug` → write to `VPSMGR_LOG_DIR/vpsmgr-YYYY-MM-DD.log`
- `die <msg>` → log + exit 1
- `random_password` → 32-char alnum, printed to stdout only
- `validate_domain` → regex check, reject IPs, reject control chars
- `validate_php_version` → check it's one of `PHP_VERSIONS` from config
- `ensure_root` → die if not root
- `site_root <domain>` → echo `WWW_ROOT/<domain>`
- `php_socket <domain>` → echo pool socket path
- `compose_db_name <domain>` → sanitise domain → db prefix
- `run_as_site_user <domain> <cmd>` → sudo -u with chroot awareness

### `bootstrap.sh` — one-shot (idempotent)

Sources:
- `common.sh`

Actions:
1. Detect OS (must be Ubuntu 24.04) — die otherwise
2. Install system packages: caddy (from official repo), php8.3-fpm, php8.2-fpm, mariadb-server, postgresql, valkey-server, rsync, unzip, git, ufw
3. For each PHP version: enable FPM unit, install common extensions (cli, curl, mbstring, xml, mysql, pgsql, intl, zip, bcmath, gd, imagick, opcache, redis)
4. Install WP-CLI from `https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar` → `/usr/local/bin/wp`
5. Fetch latest Caddy version from GitHub releases (no hardcode); install from official script
6. Fetch latest MariaDB version from official repo list; add apt source
7. Create `vpsmgr` system group; create `vpsmgr` system user (no shell, home `/opt/vpsmgr`)
8. Create directory structure (`/opt/vpsmgr/var/*`, `/opt/vpsmgr/etc/skel`)
9. Set up Caddy site config include: `import /etc/caddy/sites/*.conf`
10. Add `sftponly` group; configure sshd Match block for chroot SFTP (`/var/www/%u`)
11. Start & enable all services
12. Configure UFW: 22, 80, 443, (optionally SSH port)

### `site-create.sh` — provision a site

Usage: `site-create.sh <domain> <type> [--php-version 8.2]`

Types: `static`, `php`, `wordpress`, `proxy`

Steps:
1. Validate domain, type, and PHP version (type must require it)
2. Die if domain already has a Caddy config
3. Create webroot at `/var/www/<domain>/public_html` + `/var/www/<domain>/log`
4. **PHP required (php / wordpress)**: create FPM pool config at `/etc/php/<ver>/fpm/pool.d/<domain>.conf` — unix socket, chroot off, listen owner = site user, pm = dynamic, children capped at config value
5. **PHP required**: symlink pool config into enabled; reload PHP-FPM
6. Create system user `<sanitised_domain>` with home `/var/www/<domain>`, shell `/usr/sbin/nologin`, primary group `sftponly`
7. Set webroot ownership to site user:group (`www-data` for group so Caddy can read)
8. Generate random password; print to stdout once
9. **Database required (php + db flag / wordpress)**: 
   - Create MariaDB database + user (random password, printed once)
   - Create PostgreSQL database + user (random password, printed once) — only for php type when `--pg` flag set
   - Save credentials nowhere; emit to stdout
10. **WordPress**: 
    - Download WP via wp-cli into webroot
    - Generate `wp-config.php` with DB creds (in-memory only)
    - Run `wp core install` — prompts for admin email/user/pass on CLI; reads from stdin for non-interactive CLI
    - **Never expose WP admin prompts through the API**
11. **Proxy**: ask for `--target http://localhost:PORT`; write reverse-proxy Caddy directive
12. Write Caddy site config:
    - `static` → `root * /var/www/<domain>/public_html` + `try_files {path} /index.html`
    - `php` → `php_fastcgi unix://run/php/php<ver>-fpm-<domain>.sock` + `root * /var/www/<domain>/public_html`
    - `wordpress` → same as php + `try_files {path} /index.php?$args`
    - `proxy` → `reverse_proxy <target>`
    - All: `encode gzip`, `log { output file /var/www/<domain>/log/access.log }`
13. Reload Caddy
14. Create `.vpsmgr-site` metadata file in webroot parent (JSON: domain, type, php_version, created_at, db_engine)

### `site-delete.sh` — destroy a site

Usage: `site-delete.sh <domain> [--force]`

Steps:
1. Validate domain exists (check Caddy config exists)
2. **Unless `--force` given**: run backup.sh for this domain (full webroot + all DBs)
3. **If `--force`**: prompt "Delete without backup? [y/N]" on TTY; die if not confirmed
4. Disable and remove Caddy config; reload Caddy
5. Remove PHP-FPM pool if it exists; reload PHP-FPM
6. Drop all databases (MariaDB & PG) associated with this site
7. Remove system user; remove home `/var/www/<domain>` (chroot-aware)
8. Log completion; emit summary to stdout

### `site-db.sh` — manage databases for existing site

Usage: `site-db.sh <domain> create [--engine mariadb|postgresql]`
       `site-db.sh <domain> drop [--engine mariadb|postgresql]`

Steps:
1. Validate domain exists and has a `.vpsmgr-site` metadata file
2. **create**: generate random password (stdout only), create DB + user, grant all
3. **drop**: drop DB and user
4. Log operation

### `site-deploy.sh` — push build to webroot

Usage: `site-deploy.sh <domain> <local_path>`

Steps:
1. Validate domain exists
2. Validate local_path is a readable directory
3. `rsync -az --delete --chown=<site_user>:www-data <local_path>/ /var/www/<domain>/public_html/`
4. Log file count and total size

### `backup.sh` — backup site(s)

Usage: `backup.sh [domain]`  (no domain = all sites)

Steps:
1. Determine target domains
2. For each domain:
   a. Create temp dir
   b. Dump each associated database (MariaDB + PG) to temp dir
   c. Tar.gz webroot + dumps → `/opt/vpsmgr/var/backup/<domain>-<timestamp>.tar.gz`
   d. Cleanup temp dir
3. Prune backups older than `BACKUP_RETENTION_DAYS` (from config)
4. Log results

### `service.sh` — service control

Usage: `service.sh <component> <action>`
       `service.sh all <action>`

Components: `caddy`, `php8.3-fpm`, `php8.2-fpm`, `mariadb`, `postgresql`, `valkey-server`

Actions: `start`, `stop`, `restart`, `reload`, `status`

Steps:
1. Map component name → systemd unit name
2. Run `systemctl <action> <unit>` (or `systemctl reload-or-restart` for PHP-FPM)
3. For `status`: capture `systemctl is-active`, exit with service status code
4. For `all`: iterate over all components, aggregate results

## 3. API Route Map

Base: `http://<host>:8043` (configurable via env `VPSMGR_API_PORT`)

| Method | Route | Script | Notes |
|--------|-------|--------|-------|
| POST | `/api/bootstrap` | `bootstrap.sh` | No params; can take 5+ min |
| POST | `/api/sites` | `site-create.sh` | Body: `{domain, type, php_version?, db_engine?, target?}` |
| GET | `/api/sites` | — | Lists sites by scanning `/etc/caddy/sites/*.conf` |
| GET | `/api/sites/{domain}` | — | Reads `.vpsmgr-site` metadata file |
| DELETE | `/api/sites/{domain}` | `site-delete.sh` | Query: `?force=false` |
| POST | `/api/sites/{domain}/deploy` | `site-deploy.sh` | Body: `{local_path}` |
| POST | `/api/sites/{domain}/db` | `site-db.sh` | Body: `{action: create\|drop, engine: mariadb\|postgresql}` |
| POST | `/api/backup` | `backup.sh` | Body (optional): `{domain}` — omit = all sites |
| GET | `/api/backup` | — | List backup tarballs in backup dir |
| DELETE | `/api/backup/{domain}/{filename}` | — | Remove a specific backup tarball |
| POST | `/api/services/{name}` | `service.sh` | Body: `{action}` — `name` = component or `all` |
| GET | `/api/services/{name}` | `service.sh` | Returns status |

**Auth**: All routes except `/docs` and `/openapi.json` require `Authorization: Bearer <token>`. Token read from env `VPSMGR_API_TOKEN` at startup. Never in config.

**Response format** (all routes):
```json
{
  "success": true,
  "exit_code": 0,
  "stdout": "...",
  "stderr": "..."
}
```

HTTP status: 200 on exit 0, 400 on exit 1, 500 on ≥2.

**Cli-only guard**: Route `POST /api/sites` with `type: wordpress` returns `422` with `{"error": "WordPress installation is CLI-only. Run site-create.sh manually."}`

## 4. Design Decisions & Assumptions

1. **Config file format**: POSIX `sh` sourced file. All tunables in one place:
   - `WWW_ROOT=/var/www`
   - `VPSMGR_ROOT=/opt/vpsmgr`
   - `LOG_DIR`, `BACKUP_DIR`, `RUN_DIR`
   - `PHP_VERSIONS="8.3 8.2"` (space-separated)
   - `PHP_DEFAULT=8.3`
   - `MARIA_PORT=3306`, `PG_PORT=5432`
   - `BACKUP_RETENTION_DAYS=30`
   - `SFTP_SSH_PORT=22` (customisable)
   - `CADDY_ADMIN_PORT=2019`, `VPSMGR_API_PORT=8043`
   - `POOL_MAX_CHILDREN=10`

2. **Passwords never persisted**: Generated at runtime with `openssl rand -base64 24`, printed once to stdout. The caller (human or API consumer) is responsible for capturing. MariaDB/PostgreSQL credentials pushed directly into config or WP-CLI stdin, never hitting disk.

3. **PHP-FPM per site**: Each site gets its own FPM pool with a unix socket. Socket path derived from domain. The pool is created only if site type requires PHP.

4. **Fallback PHP version**: Optional arg on site creation. Default is `PHP_DEFAULT`. The chosen version is persisted in `.vpsmgr-site` metadata. It affects only which FPM pool version is created.

5. **Caddy configs**: One file per site at `/etc/caddy/sites/<domain>.conf`. Main `/etc/caddy/Caddyfile` includes `import /etc/caddy/sites/*.conf`. This makes enable/disable a simple file-create / file-remove + reload.

6. **SFTP chroot**: Uses OpenSSH `Match Group sftponly` + `ChrootDirectory /var/www/%u` + `ForceCommand internal-sftp`. Each site user's home IS their webroot parent, so chroot keeps them in `/var/www/<domain>/`.

7. **Metadata file**: `/var/www/<domain>/.vpsmgr-site` is a JSON file. The API reads this to know which DB engines are in use and what PHP version is assigned. It is NOT sourced by shell scripts (config is enough); it's for the API layer to enumerate.

8. **WP-CLI elevation**: When running via CLI (not API), `site-create.sh` with `wordpress` type drops into interactive WP admin creation. The script reads from `/dev/tty` for the prompts. The API route returns an error telling the user to run the CLI script manually.

9. **No version hardcoding**: `bootstrap.sh` fetches Caddy via `caddy.com'`s official script (which determines latest), MariaDB via its official repo list, PHP via Ubuntu repos (version pinned by config), WP-CLI from the phar URL (latest). Only PHP versions in the config are a policy choice, not hardcoded.

10. **Idempotency**: Every script guards its operations with existence checks:
    - `bootstrap.sh`: check if `caddy` binary exists before installing
    - `site-create.sh`: die if Caddy config exists for domain
    - `site-delete.sh`: die if domain doesn't exist
    - DB creation: `CREATE DATABASE IF NOT EXISTS` / `CREATE USER IF NOT EXISTS`
    - Service: `systemctl` already idempotent

11. **Error handling**: Shell scripts use `set -euo pipefail`. The API executor captures exit codes and maps them to HTTP status. Exit 0 → 200, Exit 1 → 400 (usage/user error), Exit 2 → 500 (internal error).

12. **Logging**: All scripts log to `VPSMGR_LOG_DIR/vpsmgr-YYYY-MM-DD.log` via `common.sh` functions. Logs include timestamp, level, script name, and message. Passwords/credentials are explicitly filtered with `grep -v` pattern in log function if they somehow reach the message (defence in depth).

## 5. Open Questions

1. **Per-site database naming convention**: `<prefix>_<domain_sanitised>` — what separator? Underscore? Hyphen? MariaDB/PostgreSQL have different rules for identifier quoting. My proposal: sanitise domain by replacing dots and hyphens with underscores, prepend `wps_` (for WordPress) or `app_` (for PHP custom). E.g., `wps_my_site_com`.

2. **PostgreSQL for WordPress?**: WordPress natively supports MariaDB/MySQL only. Should the `postgresql` engine option be exposed only for `php` type sites, or should we also support PG for WordPress via a plugin? Assumption: PG is only for `php` type, not `wordpress`.

3. **Shared hosting or single-user?**: Should multiple sites share the same Linux user, or is the "one user per site" model with chroot correct? The brief says "dedicated chrooted user per site" so this is settled — just confirming.

4. **PHP extension set**: Is the extension list in bootstrap.sh sufficient, or should it be configurable per site (e.g., an `--extensions` flag on site creation)?

5. **Caddy admin API**: Caddy exposes an admin API on `localhost:2019` by default. Should we use that for config management instead of writing files directly? My proposal: stick with file-based Caddy configs (simpler, fits the "no abstraction" goal), only use the admin API for reload.

6. **Backup format for databases**: Single `.sql` dump per engine, or `mysqldump --all-databases`? Proposal: per-database dump named `<domain>-<engine>-<dbname>.sql` inside the tarball.

7. **SELinux/AppArmor**: Ubuntu 24.04 ships with AppArmor. Should we provide AppArmor profiles for the chroot SFTP setup, or assume the default profile handles internal-sftp? Assumption: default AppArmor profile is sufficient for the chroot SFTP pattern described.

8. **API process manager**: Should the FastAPI server use a systemd unit? I propose shipping an `install.sh` that creates `/etc/systemd/system/vpsmgr-api.service` and enables it.
