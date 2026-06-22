"""Settings for the vps-manager API.

Resolved at import time from environment variables (with sensible defaults
matching /etc/vpsmgr/vpsmgr.conf). Loopback-only binding is enforced (D2).
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _env_bool(name: str, default: bool = False) -> bool:
    v = os.environ.get(name)
    if v is None:
        return default
    return v.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    # Loopback only (D2). Refuse any external bind in v1.
    api_host: str = os.environ.get("VPSMGR_API_HOST", "127.0.0.1")
    api_port: int = int(os.environ.get("VPSMGR_API_PORT", "8000"))

    api_token_file: str = os.environ.get(
        "VPSMGR_API_TOKEN_FILE", "/etc/vpsmgr/api.token"
    )

    # State directory (per-site JSON, no passwords).
    state_dir: str = os.environ.get(
        "VPSMGR_STATE_DIR", "/var/lib/vpsmgr/sites"
    )
    backup_dir: str = os.environ.get(
        "VPSMGR_BACKUP_DIR", "/var/backups/vpsmgr"
    )

    # Scripts root. Defaults to repo layout under /opt/vps-manager.
    scripts_dir: str = os.environ.get(
        "VPSMGR_SCRIPTS_DIR", "/opt/vps-manager/scripts"
    )

    debug: bool = _env_bool("VPSMGR_DEBUG", False)

    def __post_init__(self) -> None:
        # D2: never bind to a non-loopback address in v1.
        if self.api_host not in {"127.0.0.1", "localhost", "::1"}:
            raise RuntimeError(
                f"v1 API refuses non-loopback bind: {self.api_host!r}. "
                "Use an SSH tunnel for remote access."
            )


settings = Settings()
