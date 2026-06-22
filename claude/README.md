# VPS Manager — Complete Implementation

A production-ready VPS management toolkit with shell scripts and REST API for managing sites, databases, and deployments.

## 📁 Project Structure

```
vps-manager/
├── config/
│   └── vpsmgr.conf                 # Configuration (versions resolved at bootstrap)
├── scripts/
│   ├── bootstrap.sh                # Initialize system
│   ├── site-create.sh              # Create site
│   ├── site-delete.sh              # Delete site
│   ├── db-create.sh                # Create database
│   ├── deploy.sh                   # Deploy code
│   ├── backup.sh                   # Backup sites/DBs
│   ├── service.sh                  # Manage services
│   └── lib/
│       ├── common.sh               # Shared utilities
│       ├── caddy.sh                # Web server management
│       ├── php.sh                  # PHP-FPM management
│       ├── db.sh                   # Database management
│       ├── sftp.sh                 # SFTP user management
│       └── wp.sh                   # WordPress management
├── api/
│   ├── main.py                     # FastAPI application
│   ├── auth.py                     # Token authentication
│   ├── config.py                   # Configuration loading
│   ├── runner.py                   # Script execution
│   ├── schemas.py                  # Pydantic models
│   └── routes/
│       ├── bootstrap.py            # Bootstrap endpoint
│       ├── sites.py                # Site management
│       ├── databases.py            # Database management
│       ├── deploy.py               # Deployment
│       ├── backups.py              # Backups
│       └── services.py             # Service management
├── templates/
│   ├── Caddyfile.site.j2           # Caddy config template
│   ├── php-pool.conf.j2            # PHP-FPM template
│   └── wp-config.tmpl              # WordPress config
├── systemd/
│   ├── vpsmgr-api.service          # API service unit
│   ├── vpsmgr-backup-prune.service # Backup pruning service
│   └── vpsmgr-backup-prune.timer   # Daily backup pruning
└── data/
    └── sites/                      # State files (created at runtime)
```

## 🎯 Key Features

### Site Management
- **Static sites**: Plain HTML/CSS/JS
- **PHP applications**: Full PHP-FPM with database support
- **Reverse proxy**: Upstream target proxying
- **WordPress**: Single-site WordPress with database (CLI-only setup)

### Database Support
- **MariaDB**: MySQL-compatible, auto-installed
- **PostgreSQL**: Enterprise database, auto-installed
- Credentials printed once at creation, never stored

### Deployment
- Code push from local filesystem
- Archive extraction (tar, tar.gz, tar.xz, tar.bz2, zip)
- Pre-deployment backup with rollback
- PHP syntax checking for PHP sites

### Backups
- Webroot file backups (tar.xz compressed)
- Database backups (SQL dumps, compressed)
- Automatic retention pruning (30 days default)
- Post-hook support for offsite replication

### Security
- No credentials stored on disk (design decision D1)
- SFTP users chrooted to their home directory
- API token authentication (Bearer tokens)
- Systemd security hardening
- Password auth disabled for management users

## 🔧 Quick Start

### Bootstrap System
```bash
# Initialize VPS Manager
sudo bash scripts/bootstrap.sh

# System will:
# - Install Caddy, PHP, MariaDB, PostgreSQL, WP-CLI
# - Create directories (/etc/vpsmgr, /var/lib/vpsmgr, etc.)
# - Configure Caddy and OpenSSH
# - Enable systemd services
```

### Create Site (API or CLI)

**Via CLI:**
```bash
sudo scripts/site-create.sh domain=example.com type=static
```

**Via API:**
```bash
curl -X POST http://127.0.0.1:8000/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain":"example.com","type":"static"}'
```

### Deploy Code
```bash
sudo scripts/deploy.sh domain=example.com source=/tmp/myapp.tar.xz
```

### Create Database
```bash
# Create database for site
sudo scripts/db-create.sh domain=example.com engine=mariadb

# Or install WordPress
sudo scripts/db-create.sh domain=example.com engine=mariadb install_wordpress=true
```

### Create Backup
```bash
# Backup single site
sudo scripts/backup.sh domain=example.com

# Backup all sites
sudo scripts/backup.sh all=true
```

## 🔐 Design Decisions

| Decision | Implementation |
|----------|---|
| **D1: No secrets on disk** | Credentials printed once, wrapped in markers, never stored |
| **D2: API exposure** | Binds to 127.0.0.1:8000 only (localhost) |
| **D3: Off-site backups** | Local in v1; post-hook for S3/rclone |
| **D4: Async operations** | Synchronous in v1; long operations block |
| **D5: PostgreSQL version** | Resolved dynamically from PGDG apt repo |
| **D6: WordPress scope** | Single-site only (no multisite) |
| **D7: SFTP auth** | Password generated in memory, printed once |
| **D8: Backup encryption** | No encryption in v1 (key storage contradiction) |
| **D9: PHP fallback** | Previous minor version only (8.5 → 8.4, never 7.x) |
| **D10: Caddy channel** | Stable only (no testing/cloud channels) |

## 📝 Runtime Paths

| Path | Purpose |
|------|---------|
| `/etc/vpsmgr/vpsmgr.conf` | System configuration |
| `/etc/vpsmgr/api.token` | API authentication token (600 perms) |
| `/var/lib/vpsmgr/sites/` | Site state files (domain.json) |
| `/var/log/vpsmgr/` | Application logs |
| `/var/backups/vpsmgr/` | Backup archives (700 perms) |
| `/etc/caddy/sites/` | Per-site Caddy configs (imported) |
| `/etc/php/X.Y/fpm/pool.d/` | PHP-FPM pool configs |
| `/home/{sftp_user}/public/` | Site webroot |

## 📊 Exit Codes (Scripts → API HTTP Status)

| Code | Meaning | HTTP |
|------|---------|------|
| 0    | Success | 200 |
| 1    | Usage/invalid input | 400 |
| 2    | Not found | 404 |
| 3    | Conflict/exists | 409 |
| 4    | Dependency missing | 422 |
| 5    | Internal error | 500 |

## 🔄 Idempotency

All scripts are idempotent and safe to re-run:
- `bootstrap.sh` checks if already initialized
- `site-create.sh` errors if site exists
- `db-create.sh` errors if database exists
- Services are reloaded gracefully

## 🛡️ Security Features

- **No hardcoded versions**: All resolved dynamically at runtime
- **No secrets in logs**: Redaction of password patterns
- **Chrooted SFTP**: Users isolated to their home directory
- **File permissions**: 600 for sensitive files, 755 for directories
- **systemd hardening**: Strict system/home protection, syscall filtering
- **API authentication**: Bearer token, constant-time comparison

## 📦 Dependencies

### System Packages (auto-installed)
- curl, wget, git, jq, net-tools, netcat, lsb-release, gnupg
- caddy (official apt repo, stable channel)
- php (latest minor, with FPM + common extensions)
- mariadb-server, mariadb-client
- postgresql, postgresql-contrib
- wp-cli

### Python Packages (API)
- FastAPI
- Uvicorn
- Pydantic

## 🚀 API Usage

### Health Check (No Auth)
```bash
curl http://127.0.0.1:8000/health
```

### List Sites
```bash
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/sites
```

### Service Management
```bash
# Restart Caddy
curl -X POST -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/services/caddy/restart

# Get all service status
curl -H "Authorization: Bearer $TOKEN" \
  http://127.0.0.1:8000/services
```

## 📋 State File Schema

```json
{
  "domain": "example.com",
  "type": "wordpress",
  "sftp_user": "ex_example_com",
  "webroot": "/home/ex_example_com/public",
  "php_version": "8.5",
  "php_pool": "/etc/php/8.5/fpm/pool.d/example.com.conf",
  "caddy_block": "/etc/caddy/sites/example.com.caddy",
  "databases": [
    {
      "engine": "mariadb",
      "name": "ex_example_com_mar",
      "user": "ex_example_com_user"
    }
  ],
  "proxy_target": null,
  "created_at": "2026-06-22T21:00:00Z"
}
```

## ⚠️ Important Notes

1. **WordPress**: Requires separate `db-create.sh` call with `install_wordpress=true`
2. **Admin credentials**: Set interactively in TTY only, never via API
3. **Backups before deletion**: Automatic unless `skip_backup=true` with confirmation
4. **PHP fallback**: Used if primary version becomes unavailable
5. **Credentials printed once**: In format `<<<CREDENTIALS>>>...<<<CREDENTIALS>>>`
6. **No multisite**: Single WordPress site per domain

## 🔧 Troubleshooting

### API fails to start
```bash
# Check if port 8000 is free
sudo lsof -i :8000

# Check systemd status
sudo systemctl status vpsmgr-api

# View logs
sudo journalctl -u vpsmgr-api -f
```

### Sites don't appear
```bash
# Check state directory
ls -la /var/lib/vpsmgr/sites/

# Verify Caddy is running
sudo systemctl status caddy

# Check Caddy config
sudo caddy validate -c /etc/caddy/Caddyfile
```

### PHP-FPM issues
```bash
# List installed PHP versions
php -v
apt list --installed | grep php-fpm

# Check pool configs
sudo ls -la /etc/php/*/fpm/pool.d/
```

## 📄 License

This implementation is provided as-is for the VPS Manager project.
