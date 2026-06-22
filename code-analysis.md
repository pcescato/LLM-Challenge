# VPS Manager — Comparative Code Review

## Per-File Observations

### 1. `scripts/lib/common.sh`

**A (BigPickle)** — 98 lines, concise. `redact_secrets()` covers all 10 WordPress salt/key patterns explicitly (lines 28-37). `map_exit_code()` present. No domain validation, no `require_cmd()`, no password generation, no atomic state writes.

**B (Claude)** — 310 lines, comprehensive. Named exit constants (`readonly E_OK=0` etc.), `normalize_domain()` with regex, `require_cmd()`, `ensure_package()`, `gen_password()`, `acquire_lock()`/`release_lock()`, atomic `write_state()` with `mv`. `redact_credentials()` uses `sed` but misses WP salts. Exports all functions.

**C (GLM 5.2)** — 366 lines, most thorough. Configurable `VPSMGR_REDACT_PATTERNS` applied in `vpsmgr_log()` via `sed` (lines 83-88). `validate_domain()` with RFC-1035 regex. `json_get()`/`json_set()`/`json_append_to_list()` helpers. Atomic `state_write()` with `mktemp`+`mv`. `print_credentials()` with markers. `render_template()` for config files. `require_cmd()` with `die E_DEP`.

**D (DeepSeek)** — 184 lines. Hard error if config missing (line 17-19: `exit 5`). `redact()` uses configurable `LOG_REDACT_PATTERNS`. Exit helper functions (`exit_input_error`, `exit_conflict`, etc.) are clean. `generate_password()` uses `openssl rand`. No `require_cmd()`, no atomic writes, no locking.

---

### 2. `scripts/site-create.sh`

**A (BigPickle)** — Proxy type **missing from validation** (line 39: `static|php|wordpress`) but proxy handling exists at lines 85-93. WordPress is a stub — just prints info message (lines 97-101). State JSON uses heredoc with unquoted variables: `"proxy_target": ${PROXY_TARGET:-null}` (line 115) — broken JSON if PROXY_TARGET contains spaces. `"php_version": "${PHP_VERSION:-null}"` (line 111) produces string `"null"` not JSON `null`.

**B (Claude)** — **WordPress blocked entirely** (lines 54-57: `exit $E_USAGE`). This violates the spec. Uses key=value arg style (unusual). `local state_json=$(jq -n ...)` at line 159 — `local` outside a function is a bash error. SFTP password never `unset` after printing. Cleanup on failure (lines 126-127, 137-138) is good.

**C (GLM 5.2)** — All 4 types validated. TTY guard for WordPress (line 54: `[[ ! -t 0 && "${TYPE}" == "wordpress" ]]`). PHP-FPM for both php AND wordpress. Database creation for WordPress. `wp_download_core`, `wp_config_write`, `wp_install_interactive` called. `unset SFTP_PASS DB_PASS` at line 162. State built via `python3 -c` with `json.dumps` (safe). Credentials piped through `print_credentials`.

**D (DeepSeek)** — All 4 types validated. WordPress shows a notice but doesn't actually install WP or create DB. SFTP password **never captured or printed** — `sftp_user_create "${sitename}"` at line 67 returns nothing to the caller. Same heredoc JSON bugs as A: `"php_version": "${php_ver:-null}"` (line 157). `main "$@"` pattern is good.

---

### 3. `scripts/site-delete.sh`

**A (BigPickle)** — Clean. Backup via `"$SCRIPT_DIR/backup.sh"` (line 50). Skip-backup confirmation (lines 52-57). Redundant `elif $SKIP_BACKUP` at line 51 (should be `else`). DB extraction via python3. Removes PHP, Caddy, SFTP, DBs, webroot, state.

**B (Claude)** — `local backup_file=...` at line 75 and `local state_file` at line 114 — **`local` outside function is a runtime error**. Backup is inline (doesn't call backup.sh). Confirmation logic correct. DB deletion via `jq` parsing.

**C (GLM 5.2)** — Confirmation handles both TTY (interactive prompt, line 53) and non-TTY (`--confirm` flag, line 57). Calls `backup.sh` and **aborts deletion if backup fails** (line 66: `die "${E_INTERNAL}" "pre-delete backup failed"`). DB drop via python3 JSON parsing. Clean teardown order.

**D (DeepSeek)** — Interactive confirmation only (line 73: `read -r confirmation`). No `--confirm` flag for non-interactive use — **blocks API-driven skip-backup**. Calls backup.sh. `${webroot:?}` safety at line 124. Home dir cleanup. `main "$@"` pattern.

---

### 4. `scripts/backup.sh`

**A (BigPickle)** — 75 lines, minimal. `--all` recurses via `"$0" --domain "$d"` (line 31). `eval "$POST_HOOK"` (line 74) — **command injection risk**. No retention pruning. No compression choice (gz).

**B (Claude)** — Uses `xz` compression. `local sites_dir=...` at line 110 — **`local` outside function**. Retention pruning with `find -mtime` (line 135). `eval "$post_hook"` (line 140) — same injection risk. DB export via `export_database`.

**C (GLM 5.2)** — `backup_one()` function with temp dir and `trap 'rm -rf "${tmpd}"' RETURN` (line 72). Archive at `0600`, owned by `root:root` (lines 102-103). Retention pruning per-site (lines 108-112). Post-hook receives archive path as `$1` argument (line 117: `bash -c "${POST_HOOK} '${archive}'"`) — **safer than eval**. `--all` and `--domain` validated as mutually exclusive.

**D (DeepSeek)** — Most feature-rich: `--list`, manifest JSON, per-engine DB dump (mariadb-dump, pg_dump). `eval "${post_hook}"` (line 116) — injection risk. Creates temp dir then re-archives (double compression). `backup_all` iterates `list_states`. Verbose but complete.

---

### 5. `api/runner.py`

**A (BigPickle)** — 28 lines. Bare-bones: `run_script()` returns tuple, `exit_to_http()` mapping. No timeout, no logging, no error handling, no credential redaction, no Pydantic model.

**B (Claude)** — 184 lines. `ScriptRunner` class with `EXIT_CODE_MAP`. Timeout handling. `_find_script()` with search paths. Convenience methods for each script. Logs stderr truncated to 500 chars. Returns 4-tuple. Imports `config` module. No Pydantic model.

**C (GLM 5.2)** — 96 lines. **Async** with `asyncio.create_subprocess_exec`. `_safe_log_stderr()` redacts markers and password-like lines (lines 78-93). **Never logs stdout** (line 67 comment). Returns `ScriptResult` Pydantic model. `_REDACT_MARKERS` for defense-in-depth. Clean docstrings.

**D (DeepSeek)** — 82 lines. `build_command()` defined but **never used** (dead code). `run_script()` builds its own cmd. Timeout and `FileNotFoundError` handling. Returns `ScriptResult`. No logging, no credential redaction.

---

## Scoring Table

| Criterion | A (BigPickle) | B (Claude) | C (GLM 5.2) | D (DeepSeek) |
|-----------|---------------|------------|-------------|--------------|
| Security | 3/5 | 3/5 | 5/5 | 2/5 |
| Correctness | 3/5 | 2/5 | 5/5 | 3/5 |
| Idempotency | 3/5 | 5/5 | 4/5 | 2/5 |
| Code quality | 4/5 | 3/5 | 5/5 | 3/5 |
| Completeness | 3/5 | 2/5 | 5/5 | 3/5 |
| **Total** | **16/25** | **15/25** | **24/25** | **13/25** |

---

## Ranking

### 1st — C (GLM 5.2) — 24/25

Dominant across all criteria. The only implementation that fully handles all 4 site types including WordPress (with TTY-guarded interactive install, DB creation, core download, and `wp-config.php` writing). Security is best-in-class: configurable redaction patterns applied in every log call, `unset` of secrets immediately after use, runner.py never logs stdout, and post-hook receives the archive path as an argument instead of using `eval`. Atomic state writes with `mktemp`+`mv`. The only deduction is the lack of explicit file locking (though atomic writes mitigate this).

### 2nd — A (BigPickle) — 16/25

Solid middle ground. Concise, readable code with the most comprehensive WordPress salt/key redaction patterns (all 10 keys). Correct exit code convention. The main weaknesses are: proxy type missing from validation, WordPress not actually implemented (stub), heredoc JSON construction vulnerable to injection, and runner.py is bare-bones (no timeout, no logging, no error handling).

### 3rd — B (Claude) — 15/25

The common.sh library is the most feature-rich (locking, package management, domain normalization), but the implementation is undermined by critical bugs. `local` used outside functions in 3 scripts will cause bash errors at runtime. WordPress is entirely blocked (lines 54-57 of site-create.sh), violating the spec. The key=value argument style is non-idiomatic for shell scripts.

### 4th — D (DeepSeek) — 13/25

Has good structure (`main "$@"` pattern, exit helper functions, manifest JSON in backups) but significant gaps. SFTP password is never captured or printed in site-create.sh — the core credential flow is broken. WordPress shows a notice but performs no actual installation. No `require_cmd()` for dependency checking. runner.py has dead code (`build_command` defined but unused) and no logging or credential redaction. site-delete.sh has no `--confirm` flag for non-interactive skip-backup, blocking API usage. Config file is hard-required with exit 5 if missing.

---

## Key Differentiators (Best vs Worst: C vs D)

1. **Credential handling**: C captures SFTP password in `SFTP_PASS="$(sftp_create_user ...)"`, prints it once via `print_credentials`, then `unset SFTP_PASS`. D calls `sftp_user_create "${sitename}"` without capturing the return value — the password is lost and the user never sees it.

2. **WordPress implementation**: C downloads WP core, writes `wp-config.php` with DB credentials, runs interactive install, then `unset DB_PASS`. D only prints a notice box telling the user to do it manually — no DB creation, no WP download, no config generation.

3. **Runner.py logging**: C explicitly never logs stdout (which may contain credentials) and applies multi-layer redaction to stderr before logging. D has no logging at all — script execution is a black box with no audit trail.

---

## Production Readiness

**A (BigPickle)**: Not deployable as-is. Runner.py has no timeout (a hung script blocks the API indefinitely). WordPress is a stub. Proxy type validation is broken. The heredoc JSON construction could produce invalid state files if domains contain special characters.

**B (Claude)**: Not deployable. `local` outside functions in 3 scripts will cause bash errors at runtime. WordPress is entirely blocked. These are blocking bugs that prevent basic operation.

**C (GLM 5.2)**: Closest to production-ready. The async runner, atomic state writes, comprehensive redaction, and full type support are solid. Blocking issues: none critical. Minor: no file locking for concurrent operations; the `python3 -c` JSON construction in site-create.sh interpolates shell variables into Python strings (mitigated by domain validation).

**D (DeepSeek)**: Not deployable. SFTP credential flow is broken (password never shown to user). WordPress doesn't actually install. No `--confirm` flag in site-delete blocks API-driven deletion with skip-backup. Runner.py has no logging for audit trails.
