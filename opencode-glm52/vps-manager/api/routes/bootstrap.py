"""POST /bootstrap — idempotent host provisioning."""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse

from ..auth import verify_token
from ..config import settings
from ..runner import run_script
from ..schemas import BootstrapRequest, ScriptResult

router = APIRouter(tags=["bootstrap"])


@router.post("/bootstrap")
async def bootstrap(
    body: BootstrapRequest = BootstrapRequest(),
    _: None = Depends(verify_token),
) -> JSONResponse:
    args: list[str] = []
    if body.with_api:
        args.append("--with-api")
    if body.no_caddy:
        args.append("--no-caddy")
    if body.no_php:
        args.append("--no-php")
    if body.no_db:
        args.append("--no-db")
    if body.no_wp:
        args.append("--no-wp")
    if body.no_sftp_harden:
        args.append("--no-sftp-harden")

    script = os.path.join(settings.scripts_dir, "bootstrap.sh")
    result: ScriptResult = await run_script(script, args)
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)
