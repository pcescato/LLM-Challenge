# VPS Management Toolkit – Planning Document

## 1. Project Structure
```
project_root/
├─ config/                     # Central configuration
│   └─ vps_manager.conf          # Key paths, versions, retention, etc.
├─ scripts/                     # Core bash scripts (idempotent)
│   ├─ bootstrap.sh              # Server stack installation & config
│   ├─ site_create.sh            # Provision a new site (all types)
│   ├─ site_delete.sh           # Delete a site with backup option
│   ├─ db_create.sh             # Create DB for existing site
│   ├─ static_deploy.sh         # Rsync build to webroot
│   ├─ backup.sh                # Site or global backup archive
│   ├─ service.sh               # Generic service control wrapper
│   └─ utils.sh                 # Shared helper functions (logging, prompts)
├─ api/                         # FastAPI application
│   ├─ main.py                  # Entry point, route registration
│   ├─ routers/                 # One file per operation group
│   │   ├─ bootstrap.py
│   │   ├─ site.py
│   │   ├─ backup.py
│   │   └─ service.py
│   ├─ auth.py                  # Bearer token validation
│   └─ models.py                # Pydantic request/response schemas
├─ logs/                        # Runtime logs, rotated per day
│   └─ vps_manager.log
├─ docs/                        # Optional documentation (README, etc.)
│   └─ README.md
└─ requirements.txt            # Python dependencies (fastapi, uvicorn, pydantic)
```

## 2. Script List & Responsibilities
| Script | Responsibility |
|--------|-----------------|
| `bootstrap.sh` | Install Caddy, PHP‑FPM (detect latest stable & fallback), MariaDB, PostgreSQL, Valkey; configure system users, directories, log rotation, and generate default config file. |
| `site_create.sh` | Create webroot, Caddy site block, optional PHP‑FPM pool, generate random SFTP chroot user, set permissions, create DB + user (MariaDB or PostgreSQL) if required, call WP‑CLI for WordPress sites (interactive admin credentials). |
| `site_delete.sh` | Run `backup.sh` (unless `--skip-backup`), stop site services, remove Caddy config, PHP pool, webroot, SFTP user, DB objects, and clean logs for that domain. |
| `db_create.sh` | Add a new database and user for an already‑provisioned site; supports both MariaDB and PostgreSQL, generates random secure password, outputs credentials only to stdout (never writes to file). |
| `static_deploy.sh` | Rsync supplied local directory to the site's webroot; ensures proper ownership & permissions after transfer. |
| `backup.sh` | Archive (tar.gz) the site’s webroot and dump the associated DB(s); move archive to `/var/backups/vps_manager/` with timestamp; enforce retention policy from config (delete oldest when limit exceeded). |
| `service.sh` | Wrapper for `systemctl` actions (`start|stop|restart|reload|status`) on any component (`caddy|php<ver>|mariadb|postgresql|valkey`). Accepts component name or `all`. |
| `utils.sh` | Common functions: logging to `/var/log/vps_manager/`, safe prompting, generating random passwords, loading config, error handling. |

## 3. FastAPI Route Map
| HTTP Method | Path | Description | Script invoked |
|-------------|------|-------------|----------------|
| `POST` | `/api/bootstrap` | Run full server bootstrap | `bootstrap.sh` |
| `POST` | `/api/sites` | Create a new site (JSON body defines domain, type, DB engine, PHP version, etc.) | `site_create.sh` |
| `DELETE` | `/api/sites/{domain}` | Delete site; query param `skip_backup` optional | `site_delete.sh` |
| `POST` | `/api/sites/{domain}/db` | Create additional database for existing site | `db_create.sh` |
| `POST` | `/api/sites/{domain}/deploy` | Deploy static build (expects tar/zip in request or path to local dir) | `static_deploy.sh` |
| `POST` | `/api/backup` | Backup a specific site (`domain` field) or all sites (`all=true`) | `backup.sh` |
| `POST` | `/api/service/{component}` | Manage service actions; body `{ "action": "start|stop|restart|reload|status" }` | `service.sh` |
| `GET`  | `/api/status` | Health check – returns version, uptime, and basic component statuses | (internal) |

All routes require a Bearer token validated by `auth.py`. Responses:
- `200` – success, `stdout` included.
- `4xx` – client error (validation, missing params).
- `5xx` – script execution failure, `stderr` returned.

## 4. Assumptions & Design Decisions
1. **Dynamic version resolution** – `bootstrap.sh` fetches the latest stable releases from official apt repositories or GitHub releases (e.g., `curl -s https://api.github.com/repos/caddyserver/caddy/releases/latest`). No hard‑coded versions.
2. **Idempotency** – scripts check for existing resources before creation (`caddy list-sites`, `systemctl is-active`, database existence queries). Re‑running a script will leave the system unchanged.
3. **Security** – passwords generated on‑the‑fly and printed only to stdout; API never accepts passwords for WordPress admin creation (handled interactively inside `site_create.sh`). Logs never contain secrets.
4. **Configuration** – single file `config/vps_manager.conf` (INI‑style) holds paths (`/var/www`, `/etc/caddy/sites`), retention count, default PHP versions, and authorized API tokens.
5. **Logging** – each script logs to `/var/log/vps_manager/<script>.log` via `utils.sh`. API also logs request metadata without payloads that might contain secrets.
6. **SFTP chroot** – uses `systemd`‑managed `sshd` with `Match User <site_user>` to force `ChrootDirectory` to the site’s root, preventing access to other domains.
7. **Database engines** – both MariaDB and PostgreSQL are installed; the chosen engine is stored per site in the config directory (`sites/<domain>/db.conf`). Scripts query the correct service accordingly.
8. **Backup retention** – configurable `retention_count` (default 7) defines how many most‑recent backups to keep per site.
9. **FastAPI** – minimal dependencies; runs under a dedicated system user, listening on `127.0.0.1:8000` behind Caddy reverse proxy.
10. **No Docker** – everything runs directly on the host; systemd units manage services.

## 5. Questions Before Implementation
1. **Token Management** – Should the config file contain a list of allowed Bearer tokens, or do you prefer a single secret read from an environment variable at runtime?
2. **WordPress Admin Flow** – For the interactive WP‑CLI admin credential prompt, do you want the script to pause for terminal input, or should we generate a random admin password and output it for the operator to record?
3. **Backup Storage Location** – Is `/var/backups/vps_manager/` acceptable, or do you have a different mount point / external storage requirement?
4. **SFTP User Naming** – Preferred pattern (e.g., `site_<domain>` stripped of dots) and whether you need SSH key authentication only.
5. **Retention Policy Granularity** – Per‑site retention vs a global limit – which gives you more flexibility?
6. **Logging Rotation** – Any specific logrotate policy (size‑based, time‑based) you’d like to enforce?
7. **Supported PHP Versions** – Should the fallback version be the previous stable release automatically, or configurable per site?
8. **Deployment Method for Static Sites** – Do you want the API to accept a tarball upload, or will the client invoke `static_deploy.sh` locally via SSH and only call the API for status reporting?

*Please review the plan and answer the questions above so we can proceed to implementation.*