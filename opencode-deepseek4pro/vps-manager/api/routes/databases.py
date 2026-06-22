"""Database routes — create databases for sites."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from api.auth import verify_token
from api.config import DB_CREATE_SCRIPT
from api.runner import run_script
from api.schemas import DatabaseCreateRequest, ScriptResult

router = APIRouter()


@router.post("/sites/{domain}/databases", response_model=ScriptResult)
async def create_database(
    domain: str,
    body: DatabaseCreateRequest,
    _token: str = Depends(verify_token),
) -> ScriptResult:
    args = ["--domain", domain, "--engine", body.engine.value]
    if body.db_name:
        args.extend(["--db-name", body.db_name])

    return run_script(DB_CREATE_SCRIPT, *args)