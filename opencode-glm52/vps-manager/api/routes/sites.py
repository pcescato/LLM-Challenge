"""Sites API: list, get, create, delete.

POST /sites rejects type=wordpress (CLI-only — D7). DELETE supports
?skip_backup=true only when the body confirms with "DELETE <domain>".
GET routes read state JSON directly (no script invocation).
"""
from __future__ import annotations

import json
import os
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import JSONResponse

from ..auth import verify_token
from ..config import settings
from ..runner import run_script
from ..schemas import (
    ScriptResult,
    SiteCreateRequest,
    SiteDeleteRequest,
)

router = APIRouter(tags=["sites"])


def _state_path(domain: str) -> str:
    return os.path.join(settings.state_dir, f"{domain}.json")


def _read_state(domain: str) -> dict[str, Any]:
    path = _state_path(domain)
    if not os.path.isfile(path):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"site not found: {domain}")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                            detail=f"state read failed: {exc}") from exc


@router.get("/sites")
async def list_sites(_: None = Depends(verify_token)) -> list[dict[str, Any]]:
    state_dir = settings.state_dir
    out: list[dict[str, Any]] = []
    if not os.path.isdir(state_dir):
        return out
    for name in sorted(os.listdir(state_dir)):
        if not name.endswith(".json"):
            continue
        domain = name[:-5]
        try:
            with open(os.path.join(state_dir, name), "r", encoding="utf-8") as fh:
                out.append(json.load(fh))
        except (OSError, json.JSONDecodeError):
            continue
    return out


@router.get("/sites/{domain}")
async def get_site(domain: str, _: None = Depends(verify_token)) -> dict[str, Any]:
    return _read_state(domain)


@router.post("/sites")
async def create_site(
    body: SiteCreateRequest, _: None = Depends(verify_token)
) -> JSONResponse:
    # SiteCreateRequest validator already rejects type=wordpress.
    args: list[str] = ["--domain", body.domain, "--type", body.type]
    if body.proxy_target:
        args += ["--proxy-target", body.proxy_target]
    if body.php_version:
        args += ["--php-version", body.php_version]
    if body.db_engine:
        args += ["--db-engine", body.db_engine]
    if body.db_name:
        args += ["--db-name", body.db_name]
    if body.no_db:
        args.append("--no-db")

    script = os.path.join(settings.scripts_dir, "site-create.sh")
    result: ScriptResult = await run_script(script, args)
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)


@router.delete("/sites/{domain}")
async def delete_site(
    domain: str,
    skip_backup: bool = Query(default=False),
    body: SiteDeleteRequest = SiteDeleteRequest(),
    _: None = Depends(verify_token),
) -> JSONResponse:
    # Existence pre-check gives a clean 404 before invoking the script.
    if not os.path.isfile(_state_path(domain)):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                            detail=f"site not found: {domain}")

    args: list[str] = ["--domain", domain]
    if skip_backup:
        # Require explicit confirmation matching "DELETE <domain>".
        if body.confirm != f"DELETE {domain}":
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail='skip_backup requires confirm="DELETE <domain>"',
            )
        args += ["--skip-backup", "--confirm", f"DELETE {domain}"]
    else:
        # Non-interactive delete: also pass confirm so the script doesn't
        # block waiting on a TTY.
        args += ["--confirm", f"DELETE {domain}"]

    script = os.path.join(settings.scripts_dir, "site-delete.sh")
    result: ScriptResult = await run_script(script, args)
    return JSONResponse(content=result.model_dump(), status_code=result.http_status)
