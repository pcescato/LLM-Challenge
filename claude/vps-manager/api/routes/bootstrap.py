"""
Bootstrap endpoint - Initialize VPS Manager system
"""
from fastapi import APIRouter, Depends, HTTPException, status
from typing import Optional

from auth import verify_api_token
from schemas import BootstrapRequest, ScriptResponse
from runner import runner

router = APIRouter(prefix="/bootstrap", tags=["bootstrap"])


@router.post(
    "",
    response_model=ScriptResponse,
    summary="Initialize VPS Manager system",
    description="Idempotent system bootstrap. Installs dependencies and initializes directories."
)
async def bootstrap(
    request: BootstrapRequest,
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Bootstrap the VPS Manager system
    - Install system dependencies (Caddy, PHP, MariaDB, PostgreSQL, WP-CLI)
    - Create directory structure (/etc/vpsmgr, /var/lib/vpsmgr, etc.)
    - Configure system services
    - Idempotent: safe to run multiple times

    Design Decision D10: Uses stable Caddy channel only
    Design Decision D5: PostgreSQL version resolved from PGDG repo
    Design Decision D9: PHP fallback = previous minor version
    """
    exit_code, stdout, stderr, http_status = runner.bootstrap()

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Bootstrap failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )
