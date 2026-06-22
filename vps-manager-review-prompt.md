# VPS Manager — Comparative Code Review

You are a senior Linux systems engineer and Python developer.
You have been given four independent implementations of the same VPS
management toolkit, produced by four different AI coding agents.
Your task is to evaluate them objectively and comparatively.

Do NOT favor any implementation. Cite specific code in your analysis.
Score each criterion 1–5 for each implementation.

---

## Project context

A minimal VPS management toolkit for Ubuntu 24.04:
- Shell scripts for all operations
- FastAPI interface wrapping the scripts
- No Docker, no control panel
- Key constraints: idempotent scripts, no secrets on disk or logs,
  PHP-FPM only for PHP/WordPress sites, backup before deletion

---

## Implementations under review

- **A** — `opencode-bigpickle/vps-manager/`
- **B** — `claude/vps-manager/`
- **C** — `opencode-glm52/vps-manager/`
- **D** — `opencode-deepseek4pro/vps-manager/`

---

## Files to review (read all before scoring)

For each implementation, read these 5 files:

```
scripts/lib/common.sh
scripts/site-create.sh
scripts/site-delete.sh
scripts/backup.sh
api/runner.py
```

---

## Evaluation criteria

Score each implementation 1–5 on each criterion.
Provide specific observations with code citations.

### 1. Security
- Secrets never written to disk or logs
- Credential redaction in logs complete and correct
- SFTP password handling (in-memory, printed once)
- No sensitive data in subprocess arguments
- WordPress admin credentials CLI-only

### 2. Correctness & robustness
- Scripts handle missing dependencies gracefully
- Exit codes consistent with the convention (0→200, 1→400, 2→404, 3→409, 4→422, 5→500)
- Edge cases handled (site already exists, domain not found, etc.)
- Backup created before deletion (with skip confirmation)
- PHP-FPM activated only for php/wordpress site types

### 3. Idempotency
- Scripts safe to re-run without side effects
- Existence checks before creation
- State files managed correctly

### 4. Code quality
- `set -euo pipefail` on all scripts
- Functions well-named and single-purpose
- No hardcoded versions or paths outside config
- Shell conventions respected
- Python code Pydantic-idiomatic

### 5. Completeness
- All 5 files fully implemented (no stubs, no TODOs)
- API runner correctly maps exit codes to HTTP status
- Backup handles single site AND all sites
- site-create handles all 4 types (static, php, wordpress, proxy)

---

## Output format

### Per-file observations

For each of the 5 files, note specific strengths and weaknesses
per implementation. Cite code directly.

### Scoring table

| Criterion | A (BigPickle) | B (Claude) | C (GLM 5.2) | D (DeepSeek) |
|-----------|---------------|------------|-------------|--------------|
| Security | /5 | /5 | /5 | /5 |
| Correctness | /5 | /5 | /5 | /5 |
| Idempotency | /5 | /5 | /5 | /5 |
| Code quality | /5 | /5 | /5 | /5 |
| Completeness | /5 | /5 | /5 | /5 |
| **Total** | **/25** | **/25** | **/25** | **/25** |

### Ranking

Rank the four implementations from best to worst with a one-paragraph
justification for each position.

### Key differentiators

What are the 3 most significant differences between the best and worst
implementations? Be specific.

### Production readiness

For each implementation, state: would you deploy this on a production
VPS as-is? If not, what are the blocking issues?
