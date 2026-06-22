"""POST /backups — create a site or full backup.

Accepts {domain} or {all: true}. Optional post_hook for off-site escape (D3).
Synchronous in v1 (D4): blocks until the archive is created.
"""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse

from ..auth import verify_token
from ..config import settings
from ..runner import run_script
from ..schemas import BackupRequest, ScriptResult

router = APIRouter(tags=["backups"])


@router.post("/backups")
async def create_backup(
    body: BackupRequest, _: None = Depends(verify_token)
) -> JSONResponse:
    if body.all and body.domain:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="provide either {domain} or {all: true}, not both",
        )
    if not body.all and not body.domain:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="either {domain} or {all: true} is required",
        )

    if body.domain:
        state_path = os.path.join(settings.state_dir, f"{body.domain}.json")
        if not os.path.isfile(state_path):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                                detail=f"site not found: {body.domain}")

    args: list[str] = []
    if body.all:
        args.append("--all")
    else:
        args += ["--domain", body.domain]
    if body.post_hook:
        args += ["--post-hook", body.post_hook]

    script = os.path.join(settings.scripts_dir, "backup.sh")
    result: ScriptResult = await run_script(script, args)
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)
