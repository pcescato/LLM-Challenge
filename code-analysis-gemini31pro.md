# VPS Manager — Blind Comparative Code Review

## Per-file observations

### `scripts/lib/common.sh`
- **Model A:** Basic implementation. Uses a hardcoded `redact_secrets` logic. Uses brittle inline Python for JSON parsing instead of dedicated tools.
- **Model B:** Good use of `sed` for log redaction. Includes helpful `is_idempotent_ok` and `require_cmd` functions to validate system state.
- **Model C:** Highly comprehensive. Implements pure-bash JSON parsing fallback if `jq` is missing. Excellent credential wrapping logic and clean configuration loading.
- **Model D:** Decent log redaction using configurable patterns. Defines explicit exit code helpers correctly.
- **Model E:** Clean implementation. Good `_vpsmgr_redact` using regex. Good identifier validation logic (`_safe_name`).

### `scripts/site-create.sh`
- **Model A:** Fails validation if type is `proxy` due to a strict `case` statement, despite accepting `--proxy` arguments later. WordPress installation is stubbed out.
- **Model B:** Aborts entirely if type is `wordpress` instead of handling it interactively. Implements excellent rollback cleanup (e.g., `userdel`) if site creation fails midway.
- **Model C:** Perfectly checks `! -t 0` to enforce CLI-only WordPress installation without hanging the API. SFTP password securely handled in memory.
- **Model D:** WordPress installation is only a printed warning; the application is not actually provisioned.
- **Model E:** Clean logic, but misses a TTY check before invoking interactive WordPress installation, which could hang the API.

### `scripts/site-delete.sh`
- **Model A:** Executes an unconditional `read -r confirm` if `--skip-backup` is used, which will cause API requests to hang indefinitely waiting for stdin.
- **Model B:** Properly avoids API hangs by requiring a `--confirm` argument instead of interactive `read`. However, it hardcodes `/var/backups/vpsmgr`.
- **Model C:** Intelligently checks for a TTY before prompting for confirmation, gracefully falling back to the `--confirm` argument for API calls.
- **Model D:** Unconditional `read -r confirmation` causes API hangs.
- **Model E:** Checks for TTY `if [[ ! -t 0 ]]` and successfully enforces `--confirm` for API safety.

### `scripts/backup.sh`
- **Model A:** Loops properly for `--all`, but lacks sophisticated pruning or post-hook error handling.
- **Model B:** Hardcodes `/var/backups/vpsmgr` explicitly ignoring the configured `BACKUP_DIR`.
- **Model C:** Creates archives securely (`0600`). The post-hook acts as a safe escape hatch without failing the backup process if it errors.
- **Model D:** Compresses SQL dumps nicely. Generates a useful JSON manifest alongside the backup archive.
- **Model E:** Solid implementation. Prunes correctly. Good use of `rsync` for staging files safely.

### `api/runner.py`
- **Model A:** Basic synchronous wrapper. No Pydantic schemas used.
- **Model B:** Logs `stderr` up to 500 characters on failure without any redaction, potentially leaking secrets into the API application logs.
- **Model C:** Outstanding. Uses `asyncio` for non-blocking execution, utilizes the Pydantic `ScriptResult` schema, and explicitly redacts stderr via `_safe_log_stderr` before logging.
- **Model D:** Basic synchronous wrapper. Uses Pydantic for output formatting. No execution logging implemented.
- **Model E:** Good environment injection (`NONINTERACTIVE="1"`). Synchronous execution, returns a basic `Dict` instead of a structured model.

## Scoring table

| Criterion       | model A | model B | model C | model D | model E |
|-----------------|---------|---------|---------|---------|---------|
| Security        | 3/5     | 3/5     | 5/5     | 4/5     | 4/5     |
| Correctness     | 2/5     | 4/5     | 5/5     | 2/5     | 4/5     |
| Idempotency     | 2/5     | 4/5     | 5/5     | 2/5     | 4/5     |
| Code quality    | 2/5     | 4/5     | 5/5     | 3/5     | 4/5     |
| Completeness    | 2/5     | 3/5     | 5/5     | 3/5     | 5/5     |
| **Total**       | **11/25** | **18/25** | **25/25** | **14/25** | **21/25** |

## Ranking

1. **Model C (25/25):** Demonstrates exceptional attention to detail. It perfectly implements the API/CLI boundary by checking for TTY presence, ensures atomic state updates via `mktemp` and `mv`, and enforces strict credential redaction not only in bash but also explicitly in the Python API runner. The code is highly robust.
2. **Model E (21/25):** A very strong contender with clean shell code, excellent atomic state management, and reliable TTY checks for deletion. It slightly trails C due to a synchronous API runner that lacks Pydantic schemas and missing a TTY guard before interactive WordPress installation.
3. **Model B (18/25):** Features impressive rollback logic on failure and good use of shell tools. However, it completely refuses to implement WordPress site creation, hardcodes backup paths ignoring configuration, and critically, fails to scrub `stderr` in the API runner, risking credential leaks.
4. **Model D (14/25):** Has a clean API output format, but suffers from fatal API usability flaws. Using an unconditional `read` prompt for skip-backup confirmations will cause API threads to hang indefinitely. Furthermore, WordPress creation is entirely stubbed out.
5. **Model A (11/25):** The weakest implementation. The validation block incorrectly rejects `proxy` sites, it hangs on `--skip-backup` without a TTY, WordPress creation is non-functional, and the inline Python JSON parsing is brittle.

## Key differentiators

1. **API Thread Safety (TTY Checks):** The best implementations (C and E) actively verify if a TTY is present (`! -t 0`) before falling back to interactive prompts, whereas weak implementations (A and D) execute unconditional `read` commands that will permanently hang an API runner waiting for standard input.
2. **Cross-Boundary Credential Redaction:** While most models scrub logs in Bash, Model C goes the extra mile by implementing a `_safe_log_stderr` function in the FastAPI runner to ensure that if a Bash script crashes and dumps environment variables or errors, the Python logger won't leak those secrets.
3. **Atomic State Management:** Models C and E write JSON state to a temporary file and use `mv` to overwrite the existing state atomically. Models A and D `echo` or `cat` directly into the live state file, risking corrupted JSON states if the process is killed midway.

## Production readiness

- **Model A:** No. Blocking issues: API hangs on deletion, proxy sites cannot be created due to broken input validation, and state writes are not atomic.
- **Model B:** No. Blocking issues: The API runner's exception logger leaks unredacted `stderr` which could easily expose database passwords or SFTP credentials if a script fails.
- **Model C:** Yes. It is robust, secure, handles edge cases perfectly, and elegantly handles the differences between API execution and interactive CLI execution.
- **Model D:** No. Blocking issues: API hangs on `site-delete.sh` when skipping backups.
- **Model E:** Yes, conditionally. Blocking issue to fix before deployment: A TTY check must be added to the WordPress installation block to prevent the API from hanging during an interactive `wp core install`.
