# VPS Manager — Implementation Plan

A minimal, Docker-free VPS management toolkit for Ubuntu 24.04: shell scripts
for all operations, exposed through a lightweight FastAPI interface for
automation. No control panels, no abstraction layers.

---

## 1. Project Structure

```
vps-manager/
├── config/
│   └── vpsmgr.conf              # Single source of truth for all tunables
│                                # (shell-sourceable KEY=VALUE, also parsed by API)
├── scripts/
│   ├── bootstrap.sh             # Full stack install + hardening on clean host
│   ├── site-create.sh           # Provision a site (static | php | wordpress | proxy)
│   ├── site-delete.sh           # Tear down a site (backup-first, retention enforced)
│   ├── db-create.sh             # Create a database + user for an existing site
│   ├── deploy.sh                # rsync a local build into a site webroot
│   ├── backup.sh                # Archive webroot + DB dump (per site or all)
│   ├── service.sh               # start/stop/restart/reload/status of components
│   └── lib/
│       ├── common.sh            # Logging, config loader, exit-code conventions
│       ├── caddy.sh             # Caddy site config templating + reload
│       ├── php.sh               # PHP-FPM pool create/destroy, version picker
│       ├── db.sh                # MariaDB + PostgreSQL create/drop/dump helpers
│       ├── sftp.sh              # Chrooted SFTP user create/remove
│       └── wp.sh                # WP-CLI download + interactive install wrapper
├── api/
│   ├── main.py                  # FastAPI app + router registration
│   ├── auth.py                  # Bearer token dependency (constant-time compare)
│   ├── config.py                # Loads vpsmgr.conf + env overrides
│   ├── runner.py                # subprocess wrapper: exit code -> HTTP status
│   ├── schemas.py               # Pydantic request/response models
│   └── routes/
│       ├── bootstrap.py
│       ├── sites.py
│       ├── databases.py
│       ├── deploy.py
│       ├── backups.py
│       └── services.py
├── systemd/
│   ├── vpsmgr-api.service       # Unit for the FastAPI app (uvicorn behind Caddy)
│   └── vpsmgr-backup-prune.timer  # Daily retention pruning
├── templates/
│   ├── Caddyfile.site.j2        # Per-site Caddy block
│   ├── php-pool.conf.j2         # Per-site FPM pool
│   └── wp-config.tmpl           # WordPress config skeleton
├── logs/                        # Operational logs (created at bootstrap)
├── data/
│   └── sites/                   # Non-secret per-site metadata (JSON), e.g.
│                                #   <domain>.json: type, php_version, db_name,
│                                #   sftp_user, created_at. NO passwords.
├── backups/                     # Local backup archive root (configurable)
├── plan.md                      # This document
└── README.md                    # Usage: CLI + API
```

### Directory placement (runtime)

Bootstrap installs runtime dirs under non-VCS paths (configurable in
`vpsmgr.conf`):

- Config:      `/etc/vpsmgr/vpsmgr.conf`
- Logs:        `/var/log/vpsmgr/`
- State:       `/var/lib/vpsmgr/sites/` (per-site JSON metadata)
- Backups:     `/var/backups/vpsmgr/`
- Caddy sites: `/etc/caddy/sites/` (imported by main Caddyfile)
- PHP pools:   `/etc/php/<ver>/fpm/pool.d/<domain>.conf`
- Site roots:  `/home/<siteuser>/public/` (chroot-friendly layout)

The repository ships a development copy of `vpsmgr.conf` in `config/`;
bootstrap copies it to `/etc/vpsmgr/` if absent (idempotent).

---

## 2. Scripts and Responsibilities

All scripts:
- `set -euo pipefail`
- Source `lib/common.sh` for logging, config loading, exit-code helpers.
- Are idempotent: re-running is safe and converges to the desired state.
- Read secrets from env vars or interactive prompts only; never echo them,
  never write them to disk or logs (see §4 assumption A1).
- Use the centralized `vpsmgr.conf` for every tunable path/version/retention.

### Exit-code convention (shared with API)

| Code | Meaning              | HTTP mapping |
|------|----------------------|--------------|
| 0    | Success              | 200          |
| 1    | Invalid input/usage  | 400          |
| 2    | Not found            | 404          |
| 3    | Conflict / exists    | 409          |
| 4    | Dependency missing   | 422          |
| 5    | Internal/infra error | 500          |
| 6+   | Unhandled            | 500          |

### bootstrap.sh

Install and configure the full stack on a clean Ubuntu 24.04 host:

- `apt update` + prerequisite packages (curl, ca-certificates, gnupg, rsync).
- Add Caddy official repo; install Caddy.
- Add the Sury PHP PPA; discover available PHP versions dynamically (parse
  `apt-cache pkgnames php-fpm` / `apt-cache showphp`), select the **current**
  = highest stable and **fallback** = previous minor; install both `php*-fpm`
  plus a common extension set. Persist chosen versions back into
  `/etc/vpsmgr/vpsmgr.conf` (the only place versions are recorded).
- Install MariaDB from official repo; secure install non-interactively
  (root via unix_socket, set root password only if env-provided).
- Install PostgreSQL from official PGDG repo; version resolved dynamically
  from the PGDG apt listing (latest stable).
- Install Valkey from official repo; bind to 127.0.0.1.
- Install WP-CLI (phar, from official URL, verified checksum from upstream).
- Create system group for SFTP chroot users (`SFTP_GROUP`).
- Create `/etc/caddy/sites/` and import it from the main Caddyfile.
- Create log/state/backup dirs with restrictive perms.
- Register + enable `vpsmgr-api.service` and `vpsmgr-backup-prune.timer`.
- Reload/restart everything; print a status summary.

Idempotent: each block guards "already installed / already configured" checks.

### site-create.sh

`site-create.sh --domain <d> --type <static|php|wordpress|proxy> \
   [--php-version <ver>] [--db-engine mariadb|postgresql] [--proxy-target <host:port>]`

- Validate args; reject duplicate domain (exit 3).
- Create a dedicated system user `<siteuser>` (derivable from domain, slugified)
  in `SFTP_GROUP`; set up chroot-compliant home (`/home/<user>` root:root 0755,
  `public/` user:user 0755, logs/ subdir).
- Create webroot `/home/<siteuser>/public/` with an index placeholder.
- Generate Caddy site block from `Caddyfile.site.j2`:
  - static    -> root + file_server, no PHP.
  - php       -> root + `php_fastcgi unix/<pool>.sock`, no PHP unless needed.
  - wordpress -> root + `php_fastcgi` + standard WP permalinks try_files.
  - proxy     -> `reverse_proxy <target>`, no root, no PHP.
- For php/wordpress: generate per-site FPM pool (`php-pool.conf.j2`) running
  as the site user, listen on unix socket; enable on chosen PHP version
  (current default; `--php-version` may pick fallback). Reload that php-fpm.
- For php with `--db-engine`, wordpress (always), or `--with-db`: create DB +
  user via `lib/db.sh` (random password, piped into app config only).
- For wordpress: invoke `lib/wp.sh` — download core, generate salts, write
  `wp-config.php` with DB creds (chmod 600), then **interactive** `wp core
  install` prompting for admin_user/admin_password/admin_email/site title.
  Admin password read from a TTY with echo off; never logged, never returned.
- Reload Caddy. Write non-secret metadata JSON to `data/sites/<domain>.json`.

### site-delete.sh

`site-delete.sh --domain <d> [--skip-backup]`

- Require domain exists (exit 2 if not).
- Unless `--skip-backup` is given: run `backup.sh --domain <d>` first; failure
  aborts deletion (exit 5).
- If `--skip-backup`: require an interactive confirmation prompt
  `Type DELETE <domain> to confirm:`; non-TTY invocation exits 1.
- Remove: Caddy site block + reload, PHP pool file + reload FPM, DB + DB user
  (both engines checked), SFTP user + home, state JSON.
- Move the pre-deletion backup into the retention-tracked delete-backup area
  (longer retention, `DELETE_BACKUP_RETENTION_DAYS`).

### db-create.sh

`db-create.sh --domain <d> --engine mariadb|postgresql [--name <n>]`

- Site must exist (exit 2).
- Default db name derived from domain if not given; reject if db exists (409).
- Create DB + user with random password; print credentials once to stdout
  wrapped in `<<<CREDENTIALS>>>` markers so the caller (CLI or API) can display
  them, but the password is **not** written to any file or log. API returns
  them in the JSON response field `credentials` (single opportunity to capture).

### deploy.sh

`deploy.sh --domain <d> --source <local-path> [--exclude <pattern>...]`

- Validate site exists; `rsync -a --delete` from source into webroot.
- Honor `.rsync-exclude` in source if present; CLI excludes merged.
- Reload php-fpm for the site (opcache) — cheap, idempotent.
- Preserve ownership (files become siteuser:siteuser via `--chown`).

### backup.sh

`backup.sh [--domain <d>] [--all]`

- `--all` iterates over `data/sites/*.json`.
- Per site: tarball webroot (`tar` preserving perms) + `mariadb-dump` (if DB)
  + `pg_dump` (if DB). Stream into `backups/<domain>/<timestamp>.tar.zst`.
- Prune local backups older than `BACKUP_RETENTION_DAYS` for normal backups,
  `DELETE_BACKUP_RETENTION_DAYS` for delete-triggered ones.
- Manifest file per archive listing contents + checksums.
- Non-secret: archive metadata only. DB dump inside the tar is protected by
  archive file perms 0600.

### service.sh

`service.sh <component> <action>`  |  `service.sh all <action>`

- `component` ∈ `caddy | php@<ver> | mariadb | postgresql | valkey`
  (`php@<ver>` resolved from config; bare `php` acts on current version).
- `action`   ∈ `start | stop | restart | reload | status`.
- `all` fans out to every component; aggregates status into a single report.
- Uses `systemctl`; reload maps to `reload` for caddy/php-fpm/postgres/valkey
  and `reload` for mariadb (or `restart` if reload unsupported).
- Exit 0 if all requested actions succeeded; non-zero with a structured
  stderr line per failed component.

---

## 3. API Route Map

Single FastAPI app, uvicorn, bound to `127.0.0.1` by default (fronted by Caddy
reverse proxy with its own auth header or mTLS if exposed externally — see Q2).
Bearer token via `Authorization: Bearer <token>`; token loaded from env or
config, constant-time compared, never logged.

All non-health routes require auth. All routes that wrap a script return:

```json
{
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "http_status": 200
}
```

HTTP status is derived from script exit code per the table in §2.

| Method | Path                                 | Script              | Notes |
|--------|--------------------------------------|---------------------|-------|
| GET    | `/health`                            | (none)              | 200 `{status: ok}`; no auth |
| POST   | `/bootstrap`                         | `bootstrap.sh`      | Idempotent full install |
| GET    | `/sites`                             | (reads state dir)   | List provisioned sites (non-secret metadata) |
| GET    | `/sites/{domain}`                    | (reads state)       | Single site metadata |
| POST   | `/sites`                             | `site-create.sh`    | Body: `{domain,type,php_version?,db_engine?,proxy_target?}`. **`type=wordpress` rejected with 400** (CLI-only due to interactive admin creds) |
| DELETE | `/sites/{domain}`                    | `site-delete.sh`    | Query `?skip_backup=true` requires body `{confirm: "DELETE <domain>"}`; otherwise backup runs first |
| POST   | `/sites/{domain}/databases`          | `db-create.sh`      | Body: `{engine?, name?}`. Response includes `credentials` (one-shot) |
| POST   | `/sites/{domain}/deploy`             | `deploy.sh`         | Body: `{source, exclude?[]}`. `source` must be a server-local path (API is not a file upload endpoint) |
| POST   | `/backups`                           | `backup.sh`         | Body: `{domain}` or `{all: true}` |
| POST   | `/services/{component}/{action}`     | `service.sh`        | `component` may be `all` |
| GET    | `/services`                          | `service.sh all status` | Convenience status snapshot |

`runner.py` centralizes: command build from validated Pydantic models, env
scrubbing (never pass `API_TOKEN` or stdin secrets to subprocess), stdout/stderr
capture with a hard timeout from config, and exit-code -> HTTP mapping. Long
operations (bootstrap, backup --all) run synchronously by default; a future
`?async=true` may return a job id (out of scope for v1 — noted in §5).

---

## 4. Assumptions and Design Decisions

**A1 — What "never written to disk" means.** The toolkit itself keeps no
credential store. Application-level secrets that an app legitimately needs
(e.g. WordPress DB password in `wp-config.php`, created at provision time) are
written **directly** into the application's own config file with `chmod 600`,
owned by the site user, and are never echoed to stdout/stderr/logs or stored
in the toolkit's `data/sites/` state. DB user passwords generated by
`db-create.sh` are printed once to the caller and then forgotten by the
toolkit. SFTP users authenticate via SSH keys (password auth disabled by
bootstrap) so no SFTP password is ever stored. API bearer token is sourced
from env (`VPSMGR_API_TOKEN`) or a root-only mode-0600 env file; never logged.

**A2 — Per-site isolation model.** One dedicated system user per site. PHP-FPM
pool runs as that user (socket in `/run/php/<domain>.sock`, mode 0660,
group = site user). Caddy (`www-data`/`caddy`) is added to each site user's
group so it can read the socket and the world-readable webroot files. Chroot
SFTP uses the standard `/home/<user>` root-owned + writable `public/` pattern.
No `bindfs`, no ACLs required for the common case.

**A3 — PHP version selection.** "Current" = highest stable version published by
the Sury PPA at bootstrap time. "Fallback" = the previous minor (e.g. if
current is 8.4, fallback is 8.3). Both are installed; per-site pool can target
either via `--php-version`. Versions are written to `vpsmgr.conf` once
resolved, so all later scripts read them from config (no re-query, no
hardcoding in scripts).

**A4 — DB engines are independent.** A site may use MariaDB, PostgreSQL, both
(through separate `db-create` calls), or neither. WordPress defaults to
MariaDB. Bootstrap installs both engines regardless; `service.sh` manages them
individually.

**A5 — Backups are local-first.** `backups/` lives on the host by default with
`zstd` compression and 0600 perms. Off-site sync (S3/B2/rclone) is a planned
hook (`backup.sh --post-hook <cmd>`) but out of v1 scope — see Q3.

**A6 — Idempotency strategy.** Each operation checks for the target state and
no-ops the parts that already match (e.g. Caddy block hash compare, pool file
exists, DB exists). Re-provisioning an existing domain with a different type is
rejected (exit 3); deletion + re-creation is the supported path.

**A7 — Logging.** Every script writes to `/var/log/vpsmgr/<script>.log` via
`common.sh:log()` which prefixes `timestamp pid level`. A log redaction filter
strips anything matching known secret patterns (`password=`, `Bearer `, salts)
before the line is written, as defense in depth.

**A8 — API exposure.** uvicorn binds to `127.0.0.1:8000`. External exposure is
via a Caddy reverse_proxy block with an additional auth layer (header or mTLS),
**not** by binding uvicorn to 0.0.0.0. See Q2.

**A9 — State file schema** (`data/sites/<domain>.json`):
```json
{
  "domain": "example.com",
  "type": "wordpress",
  "sftp_user": "ex_example_com",
  "webroot": "/home/ex_example_com/public",
  "php_version": "8.4",
  "php_pool": "/etc/php/8.4/fpm/pool.d/example.com.conf",
  "caddy_block": "/etc/caddy/sites/example.com.caddy",
  "databases": [{"engine": "mariadb", "name": "exwp"}],
  "proxy_target": null,
  "created_at": "2026-06-22T21:00:00Z"
}
```
No password fields, ever.

---

## 5. Questions Before Implementation

1. **App credentials vs. "no secrets on disk".** Confirm the interpretation in
   A1: the toolkit stores no credentials, but application config files that
   legitimately require them (e.g. `wp-config.php`) are allowed and are the
   *only* place those values live, with 0600 perms and no logging. OK?

2. **API exposure.** Will the API stay loopback-only (consumed from the same
   host or via SSH tunnel), or should bootstrap also provision a Caddy reverse
   proxy + extra auth so it can be called remotely? This changes bootstrap and
   the auth layer.

3. **Off-site backups.** For v1, is local-only acceptable with a
   `--post-hook` escape hatch, or do you want built-in S3/B2/rclone support
   in `backup.sh` from day one?

4. **Async API jobs.** `bootstrap` and `backup --all` can run for many
   minutes. For v1, is synchronous request/response (with a long HTTP timeout)
   acceptable, or should I include a minimal job queue (background task +
   `GET /jobs/{id}`) now?

5. **PostgreSQL version.** Same dynamic-resolution rule as PHP (latest stable
   from PGDG)? Or pin to a specific major for reproducibility?

6. **WordPress scope.** Single-site installs only, or should `site-create.sh`
   also support multisite (subdomain/subdirectory) installs? Multisite changes
   the Caddy rewrite set and the wp-config bootstrap.

7. **SFTP only, or also shell users?** The brief says chrooted SFTP per site.
   Should bootstrap disable password auth globally and require SSH keys for the
   (non-chrooted) management user too, or only enforce keys for site SFTP users?

8. **Backup encryption at rest.** Should archives be encrypted (age/gpg with a
   key from env), or is 0600 file perms sufficient given the "no secrets on
   disk" rule (an encryption key would itself be a secret needing storage)?

9. **PHP "fallback" definition.** Confirm: previous *minor* (8.4 -> 8.3), or
   previous *major* (8.4 -> 7.4)? Sury still ships 7.x; some legacy stacks need
   it, but EOL versions carry risk.

10. **Caddy on Ubuntu 24.04.** Install from the official Caddy apt repo (stable
    channel), or track the `testing`/`cloud` channel? This affects auto-HTTPS
    behavior and update cadence.
