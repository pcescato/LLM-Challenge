Here's a comprehensive plan for your VPS Manager toolkit:

## Project Structure

```bash
vps-manager/
├── config/
│   ├── main.conf          # Centralized configuration
│   └── auth.conf          # API authentication tokens
├── scripts/
│   ├── bootstrap.sh       # Server setup
│   ├── site/
│   │   ├── create.sh      # Site provisioning
│   │   ├── delete.sh      # Site removal
│   │   ├── db-create.sh   # Database creation
│   │   └── deploy.sh      # Static deployment
│   ├── backup/
│   │   ├── site.sh        # Single site backup
│   │   └── all.sh         # All sites backup
│   ├── service/
│   │   ├── caddy.sh       # Caddy management
│   │   ├── php.sh         # PHP-FPM management
│   │   ├── mariadb.sh     # MariaDB management
│   │   ├── postgresql.sh  # PostgreSQL management
│   │   ├── valkey.sh      # Valkey management
│   │   └── all.sh         # All services management
│   └── utils/
│       ├── logging.sh     # Logging functions
│       ├── validation.sh # Input validation
│       └── wp-cli.sh     # WordPress helpers
├── api/
│   ├── main.py            # FastAPI app
│   ├── models.py          # Pydantic models
│   └── routes/
│       ├── sites.py       # Site routes
│       ├── backups.py     # Backup routes
│       └── services.py    # Service routes
├── logs/                  # Log directory
└── README.md
```

## Script Responsibilities

<details>
<summary>Bootstrap Script</summary>

- `bootstrap.sh`:
  - Detects Ubuntu 24.04
  - Installs all dependencies
  - Configures Caddy with automatic HTTPS
  - Installs current and fallback PHP-FPM versions
  - Sets up MariaDB and PostgreSQL
  - Installs Valkey
  - Creates directory structure
  - Generates initial config files
</details>

<details>
<summary>Site Management Scripts</summary>

- `site/create.sh`:
  - Validates domain format
  - Creates webroot directory
  - Generates Caddy config
  - Creates PHP-FPM pool if needed
  - Sets up database if needed
  - Creates chrooted SFTP user
  - For WordPress: runs interactive WP-CLI setup

- `site/delete.sh`:
  - Creates backup (unless --skip-backup)
  - Removes webroot
  - Drops database if exists
  - Removes PHP pool if exists
  - Deletes Caddy config
  - Removes SFTP user

- `site/db-create.sh`:
  - Creates database for existing site
  - Generates random credentials
  - Updates site config with DB details

- `site/deploy.sh`:
  - Validates source directory
  - Rsyncs to webroot
  - Sets proper permissions
</details>

<details>
<summary>Backup Scripts</summary>

- `backup/site.sh`:
  - Archives webroot
  - Dumps database if exists
  - Creates compressed tarball
  - Prunes old backups

- `backup/all.sh`:
  - Runs backup for all sites
  - Creates manifest file
</details>

<details>
<summary>Service Management Scripts</summary>

Each service script (`caddy.sh`, `php.sh`, etc.):
- `start`, `stop`, `restart`, `reload`, `status` operations
- Version detection for PHP
- Service-specific health checks
</details>

## API Route Map

```python
# Authentication
POST /token - Get bearer token

# Sites
POST /sites - Create site
DELETE /sites/{domain} - Delete site
POST /sites/{domain}/db - Create database
POST /sites/{domain}/deploy - Deploy static site

# Backups
POST /backups/{domain} - Backup single site
POST /backups - Backup all sites

# Services
POST /services/{service}/{action} - Service management
POST /services/all/{action} - All services management
```

## Design Decisions

1. **Configuration Management**:
   - All paths and versions in `config/main.conf`
   - Example:
     ```ini
     [paths]
     webroot = /var/www
     backups = /var/backups
     logs = /var/log/vps-manager

     [versions]
     php_current = 8.3
     php_fallback = 8.1

     [retention]
     backups = 30
     ```

2. **Security**:
   - API tokens stored in `config/auth.conf` (600 permissions)
   - All sensitive operations require confirmation
   - No credentials logged or stored

3. **WordPress Handling**:
   - Interactive setup only via CLI
   - API can trigger installation but requires pre-configured credentials

4. **Idempotency**:
   - All scripts check existing state
   - Skip operations if already completed

5. **Logging**:
   - Structured logs to `logs/` directory
   - Separate files for API and script operations

## Questions Before Implementation

1. Should the API support bulk operations (e.g., delete multiple sites)?
2. What's the preferred backup storage format (tar.gz, zip, etc.)?
3. Should we implement any rate limiting for the API?
4. What's the expected scale (number of sites) this needs to handle?
5. Should we include any monitoring endpoints in the API?

Would you like me to elaborate on any particular aspect of this plan?