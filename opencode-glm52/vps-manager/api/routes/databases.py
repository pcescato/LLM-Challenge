"""POST /sites/{domain}/databases — attach a new database to a site.

Returns credentials once (wrapped in <<<CREDENTIALS>>> markers in stdout).
The password is never persisted by the toolkit (D1).
"""
from __future__ import annotations

import os

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse

from ..auth import verify_token
from ..config import settings
from ..runner import run_script
from ..schemas import DatabaseCreateRequest, ScriptResult

router = APIRouter(tags=["databases"])


@router.post("/sites/{domain}/databases")
async def create_database(
    domain: str,
    body: DatabaseCreateRequest = DatabaseCreateRequest(),
    _: None = Depends(verify_token),
) -> JSONResponse:
    # Pre-check existence for a clean 404.
    state_path = os.path.join(settings.state_dir, f"{domain}.json")
    if not os.path.isfile(state_path):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"site not found: {domain}")

    args: list[str] = ["--domain", domain, "--engine", body.engine]
    if body.name:
        args += ["--name", body.name]

    script = os.path.join(settings.scripts_dir, "db-create.sh")
    result: ScriptResult = await run_script(script, args)
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)
