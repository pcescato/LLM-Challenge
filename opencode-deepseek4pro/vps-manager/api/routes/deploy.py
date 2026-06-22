"""Deploy route — deploy site files from server-local source."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from api.auth import verify_token
from api.config import DEPLOY_SCRIPT
from api.runner import run_script
from api.schemas import DeployRequest, ScriptResult

router = APIRouter()


@router.post("/sites/{domain}/deploy", response_model=ScriptResult)
async def deploy_site(
    domain: str,
    body: DeployRequest,
    _token: str = Depends(verify_token),
) -> ScriptResult:
    args = [
        "--domain", domain,
        "--source", body.source,
    ]
    if body.archive:
        args.extend(["--archive", body.archive.value])
    if body.backup_before:
        args.append("--backup-before")

    return run_script(DEPLOY_SCRIPT, *args)