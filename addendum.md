# VPS Manager — Code Review Addendum: Model E

## Per-file observations for Model E

### `scripts/lib/common.sh` (259 lines)

**Strengths:**
- Redaction function is thorough: strips `password=...`, `token=...`, and long hex strings from all log output (`_vpsmgr_redact`, lines 36-42).
- Exit-code helpers map 1:1 to the API contract: `die_input->1`, `die_notfound->2`, `die_conflict->3`, `die_dependency->4`, `die_internal->5` (lines 55-59).
- State files are JSON validated via `jq` before writing (line 172), and credentials are explicitly excluded from state (state_create takes no password args).
- `require_command` gives clean dependency errors with exit 4 (lines 70-75).

**Weaknesses:**
- `_vpsmgr_redact` hex pattern `[a-f0-9]{32,}` could false-positive on legitimate long hex values (e.g., file hashes in logs).
- `state_get` passes user-controlled `$key` directly to `jq -r` (line 208) — low risk since domain is validated, but still an injection surface.

---

### `scripts/site-create.sh` (172 lines)

**Strengths:**
- Validates domain, type, proxy-target requirement, and database/type compatibility before doing any work (lines 77-96).
- PHP-FPM activated only for `php` and `wordpress` types (lines 111-119).
- Credentials printed once via `print_credentials` with `<<<CREDENTIALS>>>` markers, never written to state (lines 164-169).
- WordPress admin install deferred to TTY interactive session — never passed via CLI args (wp.sh lines 64-68).

**Weaknesses:**
- **DB passwords exposed in process arguments.** `db_create` in db.sh:31 passes `IDENTIFIED BY '${db_pass}'` directly in a `mysql -e` string — visible in `/proc/*/cmdline`. Same for postgres at db.sh:42.
- SFTP password always reset via `chpasswd` even if user already exists (sftp.sh:80), though the `state_exists` guard at site-create.sh:79 prevents this path in practice.

---

### `scripts/site-delete.sh` (139 lines)

**Strengths:**
- Backup-before-delete is the default; `--skip-backup` requires explicit confirmation with domain name match (lines 49-65).
- Iterates state-file databases and drops each with engine-specific logic (lines 100-113).
- Cleans up Caddy config, PHP pool, SFTP user, chroot directory, and state file in correct order.
- `prune_old_backups` runs after deletion (line 133).

**Weaknesses:**
- `userdel -f -r ... 2>/dev/null || true` (sftp.sh:96) silently masks failures — if user has running processes, the home directory may not be fully removed.
- No atomicity: if Caddy reload succeeds but PHP reload fails partway through, the site is in a partially-deleted state with no rollback.

---

### `scripts/backup.sh` (150 lines)

**Strengths:**
- Supports `--domain`, `--all`, and `--prune` modes correctly (lines 121-147).
- Stages files in `mktemp -d` before tarring, then cleans up (lines 77-97).
- Archives are `chmod 0600` and `chown root:root` (lines 98-99).
- Post-hook support via `VPSMGR_BACKUP_ARCHIVE` env var (lines 101-103).
- `--all` correctly iterates `STATE_DIR/*.json` and handles empty state dir (lines 127-138).

**Weaknesses:**
- `rsync` is used (line 81) but never checked with `require_command rsync` — relies on bootstrap having installed it.
- `dump_database` for mariadb uses `mysqldump -u root` with no password (line 56) — works only if root socket auth is configured, which bootstrap doesn't explicitly set up.
- `parse_args` doesn't validate that `--domain` has a following argument — `$2` would trigger an unbound variable error under `set -u`.

---

### `api/runner.py` (50 lines)

**Strengths:**
- Exit-code-to-HTTP mapping is correct and complete (lines 11-20).
- Uses `sudo -n` when not root, avoiding interactive password prompts (line 30).
- Sets `NONINTERACTIVE=1` env var for scripts (line 34).
- Timeout parameter with sensible default (600s).

**Weaknesses:**
- **No script-name validation** — `script` parameter is joined directly to path (line 25). If a route ever passed user-controlled script names, path traversal would be possible. Currently safe because routes hardcode script names.
- **No credential parsing** — the `<<<CREDENTIALS>>>` markers in stdout are returned verbatim in the JSON response. The API consumer must parse them. This works but is fragile.
- **stdout/stderr returned in full** — no size limiting. A script that produces massive output could bloat the API response.

---

## Score for Model E

| Criterion | Model E |
|-----------|---------|
| Security | 3/5 |
| Correctness | 4/5 |
| Idempotency | 4/5 |
| Code quality | 4/5 |
| Completeness | 4/5 |
| **Total** | **19/25** |

---

## Production readiness

**Not ready as-is.** The blocking issue is credential handling in `db_create` (db.sh:31-33, 42-43): database passwords are passed as inline SQL in `mysql -e` and `psql -c` command arguments, making them visible in `/proc/*/cmdline` to any user on the system. On a multi-tenant VPS, this is a real vulnerability. The fix is straightforward — use `MYSQL_PWD` env var for MariaDB and `PGPASSWORD` for Postgres (as `db_dump` already does correctly at db.sh:84,88) — but it must be fixed before deployment.

Secondary concerns: `rsync` not checked in backup.sh, and `parse_args` unbound-variable risk on missing option arguments.

---

## Comparison note

Model E sits in the **solid mid-tier**. Its architecture is the cleanest of the five — the lib/ split (common, caddy, php, db, sftp, wp) is well-organized and the most modular approach. Exit-code mapping, state management, and idempotency patterns are consistently applied. However, it loses significant ground on security due to the subprocess argument password exposure, which is a more egregious flaw than the log-redaction or file-permission issues seen in other models. It scores comparably to models B/C but below the top-ranked implementation on the security axis. The code quality and completeness are strong, but the security gap prevents it from leading the pack.
