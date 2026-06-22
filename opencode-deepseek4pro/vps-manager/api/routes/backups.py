"""Backup routes — create and list backups."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from api.auth import verify_token
from api.config import BACKUP_SCRIPT
from api.runner import run_script
from api.schemas import BackupRequest, ScriptResult

router = APIRouter()


@router.post("/backups", response_model=ScriptResult)
async def create_backup(
    body: BackupRequest,
    _token: str = Depends(verify_token),
) -> ScriptResult:
    args: list[str] = []

    if body.all:
        args.append("--all")
    elif body.domain:
        args.extend(["--domain", body.domain])

    if body.post_hook:
        args.extend(["--post-hook", body.post_hook])

    return run_script(BACKUP_SCRIPT, *args, timeout=1800)