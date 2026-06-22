"""POST /sites/{domain}/deploy — deploy files from a server-local source."""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse

from ..auth import verify_token
from ..config import settings
from ..runner import run_script
from ..schemas import DeployRequest, ScriptResult

router = APIRouter(tags=["deploy"])


@router.post("/sites/{domain}/deploy")
async def deploy(
    domain: str,
    body: DeployRequest,
    _: None = Depends(verify_token),
) -> JSONResponse:
    state_path = os.path.join(settings.state_dir, f"{domain}.json")
    if not os.path.isfile(state_path):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"site not found: {domain}")

    args: list[str] = ["--domain", domain, "--source", body.source]
    if body.rsync_args:
        args += ["--rsync-args", body.rsync_args]

    script = os.path.join(settings.scripts_dir, "deploy.sh")
    result: ScriptResult = await run_script(script, args)
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)
