"""Subprocess runner that translates script exit codes into HTTP status.

Exit-code convention (shared with bash scripts):
    0  Success             → 200
    1  Invalid input/usage → 400
    2  Not found           → 404
    3  Conflict / exists   → 409
    4  Dependency missing  → 422
    5  Internal error      → 500
    6+ Unhandled           → 500

Credential blocks (<<<CREDENTIALS>>>…<<<END CREDENTIALS>>>) are passed through
in stdout verbatim to the caller; they are never logged by this module (D1).
"""
from __future__ import annotations

import asyncio
import logging
from typing import Sequence

from .schemas import ScriptResult

log = logging.getLogger("vpsmgr.runner")

# Bash exit-code → HTTP status. Codes ≥6 collapse to 500.
_EXIT_TO_HTTP: dict[int, int] = {
    0: 200,
    1: 400,
    2: 404,
    3: 409,
    4: 422,
    5: 500,
}

# Patterns scrubbed from any log line we emit. We DO NOT log stdout/stderr
# bodies at all (they may contain credentials), but defense-in-depth.
_REDACT_MARKERS = ("<<<CREDENTIALS>>>", "password=", "db_password", "sftp_password")


def _http_status_for(exit_code: int) -> int:
    return _EXIT_TO_HTTP.get(exit_code, 500)


async def run_script(script: str, args: Sequence[str]) -> ScriptResult:
    """Run a vps-manager bash script and return a ScriptResult.

    Runs as the current (root) user. All operations synchronous in v1 (D4).
    """
    cmd = ["bash", script, *args]
    # Log the command WITHOUT args that may contain secrets; args here are
    # configuration flags only (never passwords), so they're safe.
    log.info("running: %s %s", script, " ".join(args))

    proc = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout_b, stderr_b = await proc.communicate()
    rc = proc.returncode if proc.returncode is not None else 5

    stdout = stdout_b.decode("utf-8", errors="replace")
    stderr = stderr_b.decode("utf-8", errors="replace")

    http_status = _http_status_for(rc)

    # Never log stdout (may contain credentials). Log a redacted stderr summary.
    _safe_log_stderr(rc, stderr)

    return ScriptResult(
        exit_code=rc,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status,
    )


def _safe_log_stderr(rc: int, stderr: str) -> None:
    """Log a redacted, length-bounded copy of stderr for debugging.

    Secret patterns are replaced with [REDACTED]. Only the first 2KB is logged.
    """
    snippet = stderr[:2048]
    for marker in _REDACT_MARKERS:
        snippet = snippet.replace(marker, "[REDACTED]")
    # Also redact lines that look like key=value secrets.
    lines = []
    for line in snippet.splitlines():
        if any(m in line.lower() for m in ("password", "passwd", "secret", "token")):
            lines.append("[REDACTED-LINE]")
        else:
            lines.append(line)
    log.info("script exit=%d stderr(redacted)=%s", rc, " | ".join(lines)[:512])


__all__ = ["run_script"]
