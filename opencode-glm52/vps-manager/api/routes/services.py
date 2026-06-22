"""Service control API.

POST /services/{component}/{action} — start/stop/restart/reload/etc.
GET  /services                       — status snapshot of all components.
`component` may be `all`.
"""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse

from ..auth import verify_token
from ..config import settings
from ..runner import run_script
from ..schemas import ScriptResult

router = APIRouter(tags=["services"])

_VALID_COMPONENTS = {"caddy", "php", "mariadb", "postgresql", "all"}
_VALID_ACTIONS = {"start", "stop", "restart", "reload", "status", "enable", "disable"}


@router.get("/services")
async def services_status(_: None = Depends(verify_token)) -> JSONResponse:
    script = os.path.join(settings.scripts_dir, "service.sh")
    result: ScriptResult = await run_script(script, ["all", "status"])
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)


@router.post("/services/{component}/{action}")
async def service_action(
    component: str, action: str, _: None = Depends(verify_token)
) -> JSONResponse:
    if component not in _VALID_COMPONENTS:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                            detail=f"invalid component: {component}")
    if action not in _VALID_ACTIONS:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                            detail=f"invalid action: {action}")

    script = os.path.join(settings.scripts_dir, "service.sh")
    result: ScriptResult = await run_script(script, [component, action])
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)
