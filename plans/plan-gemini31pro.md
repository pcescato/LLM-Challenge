# VPS Manager — Project Plan

## 1. Project Structure

```text
/opt/vps-manager/
├── config/
│   └── vps-manager.conf          # Centralized configuration (paths, retentions, DB root creds, API token)
├── scripts/
│   ├── bootstrap.sh              # Full server setup and component installation
│   ├── site-add.sh               # Site provisioning (Caddy, PHP, DB, SFTP, WP-CLI)
│   ├── site-remove.sh            # Site deletion and cleanup
│   ├── db-add.sh                 # Database provisioning for an existing site
│   ├── deploy-static.sh          # Static deployment via rsync
│   ├── backup.sh                 # Backup execution and retention management
│   ├── service.sh                # Service state management
│   └── lib/                      # Shared bash functions
│       ├── utils.sh              # Logging, idempotency checks, prompt helpers
│       ├── caddy.sh              # Caddyfile manipulation
│       ├── db.sh                 # MariaDB/PostgreSQL operations
│       ├── php.sh                # PHP-FPM pool generation
│       └── wp.sh                 # WP-CLI operations
├── api/
│   ├── main.py                   # FastAPI application
│   ├── requirements.txt          # Python dependencies
│   └── systemd/
│       └── vps-manager-api.service # Systemd unit for the API
└── logs/                         # Dedicated log directory (scripts and API)
```

## 2. Script Responsibilities

All scripts will be designed to be idempotent and source configuration variables from `/opt/vps-manager/config/vps-manager.conf`.

*   **`bootstrap.sh`**: 
    *   Queries official sources (e.g., Ubuntu PPAs/repos or GitHub APIs) to dynamically determine the latest and fallback versions for PHP, MariaDB, PostgreSQL, Valkey, and Caddy.
    *   Installs dependencies and stack components.
    *   Configures global services, generates strong initial database root passwords (stored securely in memory and written to root-only files like `~/.my.cnf` or `.pgpass`), and sets up log rotation.
*   **`site-add.sh`**: 
    *   Accepts arguments: `domain`, `type` (static, php, wp, proxy), and optional parameters (target port, php version, db engine).
    *   Creates a system user and configures OpenSSH chroot for isolated SFTP access.
    *   Generates Caddyfile snippets and reloads Caddy.
    *   Generates a dedicated PHP-FPM pool (if `type` is `php` or `wp`).
    *   Creates a database and DB user (if requested or required).
    *   For `wp` type: Downloads WP core, configures `wp-config.php`, and uses interactive shell prompts to run `wp core install` (without logging the admin credentials).
*   **`site-remove.sh`**: 
    *   Accepts `domain` and `--skip-backup` flag.
    *   Calls `backup.sh` first unless `--skip-backup` is provided (which will trigger a confirmation prompt if run interactively).
    *   Tears down the Caddy snippet, PHP-FPM pool, Database/User, SFTP user, and deletes the webroot.
*   **`db-add.sh`**: 
    *   Creates a database and a dedicated user with a securely generated password for an existing site.
    *   Outputs the credentials to stdout (for script/API consumption).
*   **`deploy-static.sh`**: 
    *   Executes an `rsync` command from a specified local source path to a site's webroot.
*   **`backup.sh`**: 
    *   Accepts a `domain` or `--all`.
    *   Archives the site webroot using `tar`.
    *   Dumps associated databases using `mysqldump` or `pg_dump`.
    *   Cleans up older backups based on the retention period defined in `vps-manager.conf`.
*   **`service.sh`**: 
    *   Accepts an `action` (start, stop, restart, reload, status) and a `component` (caddy, php, mariadb, postgresql, valkey, all).
    *   Wraps `systemctl` commands and normalizes the exit codes/output for the API.

## 3. FastAPI Route Map

The API will run on a local port (e.g., 8000) or UNIX socket and use Bearer Token Authentication. Responses will be JSON containing `stdout`, `stderr`, and `exit_code`.

*   **`POST /sites`**: Provisions a new site. Payload specifies domain, type, db_engine, php_version, proxy_port. (WP provisioning via API will prepare files and DB, but will *skip* interactive `wp core install`).
*   **`DELETE /sites/{domain}`**: Deletes a site. Query param `?skip_backup=true` must be explicitly provided to bypass backup.
*   **`POST /sites/{domain}/databases`**: Adds a DB to an existing site. Returns generated credentials.
*   **`POST /sites/{domain}/deploy`**: Triggers `deploy-static.sh`. (Assumes deployment files are already transferred, or this endpoint triggers a server-side pull. See questions below).
*   **`POST /backups`**: Triggers `backup.sh`. Payload specifies `domain` or `all`.
*   **`GET /backups`**: Lists available backup archives.
*   **`POST /services/{component}/{action}`**: Manages services.
*   **`GET /services/{component}/status`**: Checks service status.

## 4. Assumptions & Design Decisions

*   **Version Resolution**: Since no hardcoded versions are allowed, `bootstrap.sh` will likely query the Ondrej PHP PPA (standard for Ubuntu) to parse the two highest PHP versions available. For MariaDB/PgSQL, it will query official repos.
*   **SFTP & Chroot**: To securely use OpenSSH `ChrootDirectory`, the chroot target must be owned by `root`. Therefore, the webroot structure will be `/var/www/<domain>` (owned by root) and the actual application code will reside in `/var/www/<domain>/public` (owned by the site's isolated user).
*   **WP-CLI via API**: Because the brief explicitly states WP interactive prompts must be CLI-only and not exposed to the API, the API's `POST /sites` handler for `type=wp` will stop after creating the DB, configuring Caddy/PHP, downloading WP core, and generating `wp-config.php`. The actual installation will either require the user to SSH in, or we treat `type=wp` as CLI-exclusive.
*   **Idempotency**: Scripts will heavily rely on checks (e.g., `if id -u "user" >/dev/null 2>&1`, `if [ -f "/etc/caddy/sites/domain.conf" ]`) before executing actions, preventing errors upon re-running.
*   **API Execution**: The FastAPI app will use Python's `subprocess` module to execute the bash scripts. The API service will likely need to run as `root` (or a user with robust `sudo` permissions without a password prompt) to manage system services and users.

## 5. Questions Before Implementation

1.  **WP-CLI API Behavior:** When an API request comes in to provision a WordPress site (`type=wp`), should the API completely reject the request, or should it provision the infrastructure (DB, PHP pool, download WP core) and leave the final `wp core install` step pending for a human to complete via SSH?
2.  **Dynamic Component Resolution:** By "resolved dynamically from their official sources", do you mean parsing API endpoints/RSS feeds (e.g., GitHub releases) to compile from source/download binaries, or is it acceptable to dynamically query and install the latest packages via Ubuntu's `apt` package manager (and official PPAs)?
3.  **Static Deployments via API:** How should `deploy-static.sh` work via the API? `rsync` typically pushes from a local machine to a remote machine. If the API receives a deploy request, does the API accept a file upload (like a ZIP archive) to extract, or is the `deploy-static.sh` script meant to be executed strictly from the developer's local machine?
4.  **Database User Strategy:** For sites requiring a database, should the system create one database user per database, or one database user per site (which has access to all databases created for that specific domain)?