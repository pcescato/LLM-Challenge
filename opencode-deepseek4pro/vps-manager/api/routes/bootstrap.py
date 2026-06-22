"""Bootstrap route."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from api.auth import verify_token
from api.config import BOOTSTRAP_SCRIPT
from api.runner import run_script
from api.schemas import ScriptResult

router = APIRouter()


@router.post("/bootstrap", response_model=ScriptResult)
async def bootstrap(_token: str = Depends(verify_token)) -> ScriptResult:
    return run_script(BOOTSTRAP_SCRIPT, timeout=1800)