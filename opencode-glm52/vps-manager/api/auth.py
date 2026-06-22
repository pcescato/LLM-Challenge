"""Bearer-token authentication for the vps-manager API.

Token is read from /etc/vpsmgr/api.token (chmod 600, root-owned) at startup
and held in memory. Constant-time comparison via hmac.compare_digest.
No external auth provider in v1.
"""
from __future__ import annotations

import hmac
import os
from typing import Optional

from fastapi import HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import settings

_bearer = HTTPBearer(auto_error=False)

# Loaded once at import; never re-read per-request to avoid log noise.
_TOKEN: Optional[bytes] = None


def _load_token() -> Optional[bytes]:
    global _TOKEN
    if _TOKEN is not None:
        return _TOKEN
    path = settings.api_token_file
    try:
        with open(path, "rb") as fh:
            _TOKEN = fh.read().strip()
    except OSError:
        _TOKEN = b""
    return _TOKEN


async def verify_token(request: Request) -> None:
    """FastAPI dependency: require a valid Bearer token on every protected route.

    Public routes (e.g. /health) do not declare this dependency.
    """
    expected = _load_token()
    if not expected:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="API token not configured on the server; run bootstrap.",
        )
    creds: HTTPAuthorizationCredentials = await _bearer(request)
    if creds is None or creds.scheme.lower() != "bearer":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="missing or malformed Authorization header",
            headers={"WWW-Authenticate": "Bearer"},
        )
    provided = creds.credentials.encode("utf-8")
    if not hmac.compare_digest(provided, expected):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid bearer token",
            headers={"WWW-Authenticate": "Bearer"},
        )


__all__ = ["verify_token"]
