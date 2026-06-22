# VPS Manager — Development Prompt

You are implementing a complete VPS management toolkit. The architecture has
been validated. Implement it fully, file by file, without asking questions.
Write each file to disk as you go.

---

## Validated Architecture

### Project structure

```
vps-manager/
├── config/
│   └── vpsmgr.conf
├── scripts/
│   ├── bootstrap.sh
│   ├── site-create.sh
│   ├── site-delete.sh
│   ├── db-create.sh
│   ├── deploy.sh
│   ├── backup.sh
│   ├── service.sh
│   └── lib/
│       ├── common.sh
│       ├── caddy.sh
│       ├── php.sh
│       ├── db.sh
│       ├── sftp.sh
│       └── wp.sh
├── api/
│   ├── main.py
│   ├── auth.py
│   ├── config.py
│   ├── runner.py
│   ├── schemas.py
│   └── routes/
│       ├── bootstrap.py
│       ├── sites.py
│       ├── databases.py
│       ├── deploy.py
│       ├── backups.py
│       └── services.py
├── systemd/
│   ├── vpsmgr-api.service
│   └── vpsmgr-backup-prune.timer
├── templates/
│   ├── Caddyfile.site.j2
│   ├── php-pool.conf.j2
│   └── wp-config.tmpl
└── data/
    └── sites/
```

### Runtime paths (installed by bootstrap)

- Config:   `/etc/vpsmgr/vpsmgr.conf`
- Logs:     `/var/log/vpsmgr/`
- State:    `/var/lib/vpsmgr/sites/` (per-site JSON, no passwords)
- Backups:  `/var/backups/vpsmgr/`
- Caddy:    `/etc/caddy/sites/` (imported by main Caddyfile)
- PHP pools: `/etc/php/<ver>/fpm/pool.d/<domain>.conf`
- Webroots: `/home/<siteuser>/public/`

---

## Validated Design Decisions

**D1 — App credentials vs no secrets on disk.**
The toolkit stores no credentials. Application config files that legitimately
require them (e.g. `wp-config.php`) are written directly into the application's
own config with `chmod 600`, owned by the site user, and are never echoed to
stdout/stderr/logs or stored in the toolkit state. DB passwords printed once to
stdout wrapped in `<<<CREDENTIALS>>>` markers, then forgotten.

**D2 — API exposure.**
uvicorn binds to `127.0.0.1:8000` only. No external exposure in v1. Consumed
from the same host or via SSH tunnel.

**D3 — Off-site backups.**
Local only in v1. `backup.sh` accepts a `--post-hook <cmd>` parameter as escape
hatch but does not implement S3/rclone natively.

**D4 — Async API jobs.**
All operations synchronous in v1. Long operations (bootstrap, backup --all)
block until completion. No job queue.

**D5 — PostgreSQL version.**
Resolved dynamically from the PGDG apt repo at bootstrap time, same rule as
PHP. Latest stable, no pinning.

**D6 — WordPress scope.**
Single-site installs only. No multisite support.

**D7 — SFTP authentication.**
Password generated in memory at site creation, printed once to stdout, never
stored. Password auth disabled globally by bootstrap for SSH management users;
site SFTP users use password auth (chrooted, isolated).

**D8 — Backup encryption.**
No encryption in v1. Archives at 0600 perms, owned by root. Encryption key
would itself be a secret requiring storage — contradiction with D1.

**D9 — PHP fallback definition.**
Previous minor only. If current = 8.5, fallback = 8.4. Never previous major.
EOL versions (7.x) not supported.

**D10 — Caddy channel.**
Stable channel only from official Caddy apt repo. No testing/cloud channel.

---

## Exit-code convention (scripts → API)

| Code | Meaning             | HTTP |
|------|---------------------|------|
| 0    | Success             | 200  |
| 1    | Invalid input/usage | 400  |
| 2    | Not found           | 404  |
| 3    | Conflict / exists   | 409  |
| 4    | Dependency missing  | 422  |
| 5    | Internal error      | 500  |
| 6+   | Unhandled           | 500  |

---

## API Route Map

Base: `http://127.0.0.1:8000`
Auth: `Authorization: Bearer <token>` on all routes except `/health`.

| Method | Path                             | Script           | Notes |
|--------|----------------------------------|------------------|-------|
| GET    | `/health`                        | —                | No auth |
| POST   | `/bootstrap`                     | `bootstrap.sh`   | Idempotent |
| GET    | `/sites`                         | reads state dir  | List sites |
| GET    | `/sites/{domain}`                | reads state      | Site metadata |
| POST   | `/sites`                         | `site-create.sh` | `type=wordpress` → 400 (CLI only) |
| DELETE | `/sites/{domain}`                | `site-delete.sh` | `?skip_backup=true` requires `{confirm: "DELETE <domain>"}` |
| POST   | `/sites/{domain}/databases`      | `db-create.sh`   | Returns credentials once |
| POST   | `/sites/{domain}/deploy`         | `deploy.sh`      | `source` = server-local path |
| POST   | `/backups`                       | `backup.sh`      | `{domain}` or `{all: true}` |
| POST   | `/services/{component}/{action}` | `service.sh`     | `component` may be `all` |
| GET    | `/services`                      | `service.sh all status` | Status snapshot |

All script routes return:
```json
{
  "exit_code": 0,
  "stdout": "...",
  "stderr": "...",
  "http_status": 200
}
```

---

## Non-negotiable constraints

- No Docker
- `set -euo pipefail` on every script
- Every script sources `lib/common.sh` first
- No hardcoded versions anywhere — resolved dynamically at bootstrap
- PHP-FPM activated only for `php` and `wordpress` site types
- No secret ever written to disk or logs by the toolkit itself
- SFTP password generated in memory, printed once, then unset
- WordPress admin credentials: interactive TTY only, never via API
- Backups created automatically before any site deletion
- `--skip-backup` requires explicit confirmation: `Type DELETE <domain> to confirm:`
- Idempotent: safe to re-run any script
- Logs at `/var/log/vpsmgr/` with redaction of secret patterns
- State JSON at `/var/lib/vpsmgr/sites/<domain>.json` — no password fields ever

## State file schema

```json
{
  "domain": "example.com",
  "type": "wordpress",
  "sftp_user": "ex_example_com",
  "webroot": "/home/ex_example_com/public",
  "php_version": "8.5",
  "php_pool": "/etc/php/8.5/fpm/pool.d/example.com.conf",
  "caddy_block": "/etc/caddy/sites/example.com.caddy",
  "databases": [{"engine": "mariadb", "name": "exwp"}],
  "proxy_target": null,
  "created_at": "2026-06-22T21:00:00Z"
}
```

---

## Implementation order

Implement in this exact order:

1. `config/vpsmgr.conf`
2. `scripts/lib/common.sh`
3. `scripts/lib/caddy.sh`
4. `scripts/lib/php.sh`
5. `scripts/lib/db.sh`
6. `scripts/lib/sftp.sh`
7. `scripts/lib/wp.sh`
8. `scripts/bootstrap.sh`
9. `scripts/site-create.sh`
10. `scripts/site-delete.sh`
11. `scripts/db-create.sh`
12. `scripts/deploy.sh`
13. `scripts/backup.sh`
14. `scripts/service.sh`
15. `templates/Caddyfile.site.j2`
16. `templates/php-pool.conf.j2`
17. `templates/wp-config.tmpl`
18. `api/schemas.py`
19. `api/auth.py`
20. `api/config.py`
21. `api/runner.py`
22. `api/routes/bootstrap.py`
23. `api/routes/sites.py`
24. `api/routes/databases.py`
25. `api/routes/deploy.py`
26. `api/routes/backups.py`
27. `api/routes/services.py`
28. `api/main.py`
29. `systemd/vpsmgr-api.service`
30. `systemd/vpsmgr-backup-prune.timer`

Write every file to disk. Do not summarize or skip any file.
