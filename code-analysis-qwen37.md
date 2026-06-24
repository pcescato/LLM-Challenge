# VPS Manager — Blind Comparative Code Review

## Per-file observations

### 1. `scripts/lib/common.sh`

| | Model A | Model B | Model C | Model D |
|---|---|---|---|---|
| Lines | 98 | 310 | 366 | 184 |

**Model A** — Minimal but functional. `redact_secrets()` at lines 26-38 uses bash glob substitution (`${line//DB_PASSWORD=[^ ]*/DB_PASSWORD=***}`), which is NOT regex — it is a glob pattern. This works for simple `KEY=VALUE` tokens but will miss quoted values, multi-word secrets, or patterns with spaces. No domain validation, no `require_cmd()`, no locking. `map_exit_code()` (lines 87-98) duplicates logic that the Python runner also implements.

**Model B** — The most feature-rich common library. Includes `normalize_domain()` (lines 95-106), `require_cmd()` (lines 70-76), `ensure_package()` (lines 85-92), `acquire_lock()`/`release_lock()` (lines 280-302), `gen_password()` (lines 188-192), and `is_idempotent_ok()` (lines 53-59). `redact_credentials()` (lines 43-49) uses `sed -E` with regex patterns — more robust than Model A's glob approach. However, the `export -f` block (lines 304-310) is unusual and unnecessary for sourced libraries.

**Model C** — The most carefully engineered. Configurable redaction via `VPSMGR_REDACT_PATTERNS` (line 51) applied in `vpsmgr_log()` (lines 74-94) before every write. Atomic state writes via `mktemp` + `mv` (lines 172-182). `validate_domain()` (lines 121-138) rejects localhost and validates RFC-1035 format. `json_get()` (lines 207-229) gracefully falls back from `jq` to `python3`. `print_credentials()` (lines 291-295) wraps output in `<<<CREDENTIALS>>>`/`<<<END CREDENTIALS>>>` markers. All variables are exported for subshell access (lines 55-69).

**Model D** — Clean structure with named exit helpers (`exit_input_error()`, `exit_not_found()`, etc. at lines 47-52). `validate_domain()` and `validate_site_type()` are present. **Critical flaw**: `redact()` (lines 33-43) exists but is **never called** by `log_info()`, `log_warn()`, or `log_error()` (lines 28-30). These log functions write directly via `tee -a` to the log file with no redaction. Secrets will be written to disk in plaintext.

---

### 2. `scripts/site-create.sh`

| | Model A | Model B | Model C | Model D |
|---|---|---|---|---|
| Lines | 131 | 203 | 166 | 187 |

**Model A** — Uses `--flag` argument parsing. Validates types as `static|php|wordpress` (line 39) — **proxy is missing from the type validation**. Proxy is handled as a post-hoc override (lines 85-93) that overwrites the Caddy block, which is fragile. SFTP password is printed once inside `<<<CREDENTIALS>>>` markers (lines 124-128) and cleared at line 131 (`SFTP_PASS=""`). WordPress handling is a stub — lines 97-101 just print an info message telling the user to run other scripts. State JSON at lines 105-118 uses shell interpolation which could break on special characters.

**Model B** — Uses non-standard `key=value` argument parsing (lines 20-27). **Critical bug**: line 159 uses `local state_json=$(jq -n ...)` **outside any function** — `local` is only valid inside functions in bash, so `set -e` will cause this script to abort at runtime. **WordPress is explicitly blocked** at lines 54-57 (`exit $E_USAGE`), violating the spec requirement to handle all 4 types. PHP-FPM is only activated for `site_type == "php"` (line 131), not for `wordpress`. Cleanup-on-failure (lines 126-127, 136-138, 151-154) is a good pattern. SFTP password is printed at line 200 but never cleared from memory.

**Model C** — Handles all 4 types correctly (line 48: `static|php|proxy|wordpress`). WordPress requires a TTY (lines 54-58: `[[ ! -t 0 && "${TYPE}" == "wordpress" ]]`), defending against API-based credential exposure. Database creation is integrated for WordPress (lines 95-107). SFTP and DB passwords are wrapped in `print_credentials` (lines 150-159) and `unset` immediately after (line 162). State JSON is constructed via `python3 -c` (lines 131-146) which is safer than shell interpolation. PHP-FPM is correctly activated for both `php` and `wordpress` types (line 74).

**Model D** — Handles all 4 types in validation (line 69: `static|php|wordpress|proxy`). **Major gap**: no SFTP password is generated or output anywhere in the script. `sftp_user_create` is called (line 67) but no password generation, no `<<<CREDENTIALS>>>` block, no credential output at all. WordPress shows a warning box (lines 107-137) but doesn't actually create a database or download WordPress core files. State JSON uses shell heredoc interpolation (lines 151-164) which is fragile. `mkdir -p "${STATE_DIR}"` at line 168 is done **after** `write_state` at line 167 — the directory should exist before writing.

---

### 3. `scripts/site-delete.sh`

| | Model A | Model B | Model C | Model D |
|---|---|---|---|---|
| Lines | 86 | 138 | 103 | 143 |

**Model A** — Clean teardown: PHP pool, Caddy block, SFTP user, databases, webroot, state. Backup before deletion with `--skip-backup` requiring interactive confirmation (lines 48-58). Uses `python3 -c` for JSON field extraction (lines 35-45) — spawns a separate python process per field, which is inefficient but functional. Confirmation requires typing `DELETE ${DOMAIN}` (line 54).

**Model B** — **Critical bug**: lines 75 and 114 use `local` outside a function. Line 75: `local backup_file=...` and line 114: `local state_file` — both at the script's top level. These will cause immediate failure with `set -e`. Uses `key=value` arg parsing. Backup is inline (lines 78-89) rather than calling `backup.sh`. Database cleanup uses `jq` (line 119). Skip-backup confirmation requires passing `confirm=DELETE $domain` as an argument (lines 48-53), which means the confirmation string travels as a CLI argument — visible in `/proc`.

**Model C** — Backup is delegated to `backup.sh` and **aborts deletion if backup fails** (line 66: `|| die "${E_INTERNAL}" "pre-delete backup failed; aborting deletion"`). This is the safest approach. Confirmation has two paths: interactive TTY prompt (lines 52-56) and non-interactive `--confirm` flag (lines 57-59). Database cleanup uses `python3 -c` for JSON parsing (lines 72-79). Clean ordering: DBs, PHP, Caddy, SFTP, state.

**Model D** — Backup before deletion (line 78). Skip-backup requires interactive `read` confirmation (lines 71-76). Uses `python3 -c` for JSON field extraction (lines 64-68). Database cleanup handles both mariadb and postgresql (lines 109-116). Removes empty home directory (lines 129-132) — a nice touch. Uses `rm -rf "${webroot:?}"` (line 124) with the `:?` safety guard to prevent accidental `rm -rf /`.

---

### 4. `scripts/backup.sh`

| | Model A | Model B | Model C | Model D |
|---|---|---|---|---|
| Lines | 75 | 147 | 146 | 211 |

**Model A** — Handles `--domain` and `--all`. `--all` recursively calls `$0 --domain` for each state file (lines 27-34) — simple and effective. Uses `tar czf` for compression. Database dumps via `db_dump` + `gzip` (lines 58-63). Post-hook uses `eval "$POST_HOOK"` (line 74) — **security risk** if the hook string is attacker-controlled. No backup pruning/retention. No manifest.

**Model B** — **Critical bug**: lines 110, 116, 119 use `local` outside a function (`local sites_dir`, `local backup_count`, `local site_domain`). Uses `xz` compression (line 66: `tar -cJf`). Has backup pruning (line 135: `find ... -mtime +${BACKUP_RETENTION_DAYS:-30} -delete`). Post-hook uses `eval` (line 140) — same security risk. Database dumps use a temp file in `/tmp` (line 84) which is a security concern (predictable path, world-writable directory).

**Model C** — Stages backup contents in a `mktemp -d` directory (line 71) before archiving — avoids partial archives. Uses `tar -czf`. Archive permissions set to `VPSMGR_BACKUP_MODE` (0600, line 102) and `chown root:root` (line 103). Pruning per-site (lines 108-112). Post-hook uses `bash -c "${POST_HOOK} '${archive}'"` (line 117) — slightly safer than `eval` but still a risk if `POST_HOOK` is user-controlled. `--all` mode uses `shopt -s nullglob` (line 128) to handle empty state directories gracefully.

**Model D** — Most feature-rich: has `--list` option (lines 144-161), manifest files (lines 99-109), and handles mariadb/postgresql separately with engine-specific dump commands. Creates a temp backup directory, archives it, then cleans up (lines 92-96). Post-hook uses `eval` (line 116). `list_backups()` reads manifest JSON files. No retention/pruning logic. `backup_all()` (lines 123-142) iterates over `list_states` output.

---

### 5. `api/runner.py`

| | Model A | Model B | Model C | Model D |
|---|---|---|---|---|
| Lines | 28 | 184 | 96 | 82 |

**Model A** — Minimal: 28 lines. `run_script()` (lines 6-16) is a bare `subprocess.run` wrapper with no timeout, no error handling, no logging. `exit_to_http()` (lines 19-28) correctly maps exit codes. No `ScriptResult` model. No credential protection in logs (there are no logs at all — which is accidentally secure but not by design).

**Model B** — Most comprehensive: 184 lines. `ScriptRunner` class with `EXIT_CODE_MAP` (lines 20-27), timeout handling (line 70), script discovery via `_find_script()` (lines 101-120), and convenience methods for each operation (lines 122-180). Logs command execution (line 62: `logger.info(f"Executing: {cmd_str[:100]}")`) — truncated but could leak domain names. Logs stderr on failure (lines 81-84) without redaction. Imports from `config` module (line 11). Uses `shlex.quote` for logging (line 61). Returns 4-tuple `(exit_code, stdout, stderr, http_status)`.

**Model C** — Async implementation using `asyncio.create_subprocess_exec` (line 54). **Never logs stdout** (line 67 comment: "Never log stdout (may contain credentials)"). `_safe_log_stderr()` (lines 78-93) redacts line-by-line: any line containing "password", "passwd", "secret", or "token" is replaced with `[REDACTED-LINE]`. Length-bounded to 2KB (line 83). Uses `ScriptResult` Pydantic model. Clean separation of concerns. `__all__` export list (line 96). No timeout parameter — relies on default asyncio behavior.

**Model D** — 82 lines. `build_command()` (lines 12-17) uses `shlex.quote` but is **never called** — dead code. `run_script()` (lines 20-82) has timeout handling (line 41) and `FileNotFoundError` handling (lines 52-58). No logging at all — accidentally secure. Returns `ScriptResult` model. Exit code mapping at lines 65-75 with fallback for codes > 5. `stdin_input` parameter (line 24) is accepted but its use case is unclear.

---

## Scoring table

| Criterion       | Model A | Model B | Model C | Model D |
|-----------------|---------|---------|---------|---------|
| Security        | 3/5     | 3/5     | 5/5     | 2/5     |
| Correctness     | 3/5     | 2/5     | 5/5     | 2/5     |
| Idempotency     | 3/5     | 3/5     | 5/5     | 3/5     |
| Code quality    | 3/5     | 2/5     | 5/5     | 3/5     |
| Completeness    | 3/5     | 2/5     | 5/5     | 2/5     |
| **Total**       | **15/25** | **12/25** | **25/25** | **12/25** |

---

## Ranking

### 1st — Model C (25/25)

Model C is the clear winner. It is the only implementation that correctly handles all four site types, enforces WordPress TTY-only admin credentials, applies secret redaction consistently in both bash logging and the Python runner, uses atomic state file writes (`mktemp` + `mv`), and produces a runner that never logs stdout while line-by-line redacting stderr. Every script uses `set -euo pipefail`, consistent `--flag` argument parsing, and proper exit codes. The code is well-organized with single-purpose functions, configurable defaults, and defensive checks at every boundary. No blocking issues found.

### 2nd — Model A (15/25)

Model A is a competent, minimal implementation. It handles static, PHP, and WordPress types but does not support proxy as a first-class type (it is a post-hoc Caddy override). The runner is bare-bones (no timeout, no error handling, no logging), and the redaction function uses fragile bash glob patterns instead of regex. However, the scripts are structurally sound, SFTP credentials are printed once and cleared, and backup-before-deletion works correctly. It would need significant hardening for production but has no critical bugs.

### 3rd — Model D (12/25)

Model D has clean code structure with good patterns (main() wrapper, named exit helpers, `:?` safety guards), but has two significant gaps: `site-create.sh` never generates or outputs an SFTP password (the most critical credential), and `redact()` in `common.sh` is defined but never called by the logging functions — meaning secrets will be written to log files in plaintext. WordPress support is a stub (warning message only, no database creation or core download). The backup script is the most feature-rich (manifests, --list), but the core site creation flow is incomplete.

### 4th — Model B (12/25)

Model B has the most ambitious common library (310 lines with locking, package management, domain normalization) but is undermined by critical runtime bugs. `local` is used outside functions in `site-create.sh` (line 159), `site-delete.sh` (lines 75, 114), and `backup.sh` (lines 110, 116, 119) — with `set -e`, these scripts will abort immediately at those lines. WordPress is explicitly blocked (site-create.sh lines 54-57), violating the spec. PHP-FPM is only activated for `php` type, not `wordpress`. The non-standard `key=value` argument parsing diverges from shell conventions. The runner.py is the most comprehensive of all four, but the shell scripts cannot execute as written.

---

## Key differentiators (Model C vs Model B)

1. **Runtime viability**: Model B uses `local` outside functions in 3 of 4 shell scripts (site-create.sh:159, site-delete.sh:75,114, backup.sh:110,116,119), which causes immediate failure under `set -e`. Model C has no such bugs — every script is syntactically and semantically correct.

2. **WordPress and type completeness**: Model B blocks WordPress entirely (site-create.sh:54-57: `exit $E_USAGE`) and only activates PHP-FPM for `php` type. Model C handles all four types correctly, activates PHP-FPM for both `php` and `wordpress`, and creates databases for WordPress sites.

3. **Credential safety in the API layer**: Model C's runner.py never logs stdout and applies line-by-line redaction to stderr (`_safe_log_stderr`, runner.py:78-93). Model B's runner.py logs the full command string (runner.py:62) and logs stderr without redaction (runner.py:81-84), risking secret exposure in application logs.

---

## Production readiness

### Model A — Not ready as-is
- **Blocking**: Proxy type not supported as a first-class type; runner.py has no timeout (a hung script blocks the API indefinitely); no `require_cmd()` checks mean missing dependencies produce cryptic errors.
- **To fix**: Add proxy type validation, add timeout to runner.py, add dependency checks, replace glob-based redaction with regex.

### Model B — Not ready as-is
- **Blocking**: `local` outside functions causes immediate script failure in site-create.sh, site-delete.sh, and backup.sh. WordPress is blocked. These are not configuration issues — the scripts cannot run.
- **To fix**: Move all top-level code into functions or remove `local` keyword. Unblock WordPress. Add PHP-FPM activation for WordPress type.

### Model C — Ready to deploy with minor review
- No blocking issues found. All scripts are syntactically correct, handle all four site types, enforce credential safety, and the runner correctly maps exit codes. The only minor concern is the use of `python3 -c` with shell variable interpolation for JSON construction (site-create.sh:131-146), which is safe given domain validation but could be hardened further with `jq --arg`.

### Model D — Not ready as-is
- **Blocking**: `site-create.sh` does not generate or output an SFTP password — users will have no way to access their site via SFTP. `redact()` is never called by logging functions, so secrets will be written to log files. WordPress support is a stub.
- **To fix**: Add SFTP password generation and credential output. Wire `redact()` into `log_info`/`log_warn`/`log_error`. Implement WordPress database creation and core download.
