"""Service routes — manage and query services."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from api.auth import verify_token
from api.config import SERVICE_SCRIPT
from api.runner import run_script
from api.schemas import ScriptResult

router = APIRouter()


@router.get("/services")
async def get_service_status(_token: str = Depends(verify_token)) -> ScriptResult:
    return run_script(SERVICE_SCRIPT, "all", "status")


@router.post("/services/{component}/{action}", response_model=ScriptResult)
async def service_action(
    component: str,
    action: str,
    _token: str = Depends(verify_token),
) -> ScriptResult:
    return run_script(SERVICE_SCRIPT, component, action)