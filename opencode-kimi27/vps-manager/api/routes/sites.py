import json
from pathlib import Path
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from starlette.responses import JSONResponse
from api.auth import require_auth
from api.config import SETTINGS
from api.runner import run_script
from api.schemas import CreateSiteRequest, DeleteSiteRequest

router = APIRouter()


def _state_dir() -> Path:
    return Path(SETTINGS.get("STATE_DIR", "/var/lib/vpsmgr/sites"))


@router.get("/sites", dependencies=[Depends(require_auth)])
def list_sites():
    sites = []
    state_dir = _state_dir()
    if state_dir.exists():
        for p in sorted(state_dir.glob("*.json")):
            try:
                sites.append(json.loads(p.read_text()))
            except Exception:
                continue
    return sites


@router.get("/sites/{domain}", dependencies=[Depends(require_auth)])
def get_site(domain: str):
    sp = _state_dir() / f"{domain}.json"
    if not sp.exists():
        raise HTTPException(status_code=404, detail="site not found")
    return json.loads(sp.read_text())


@router.post("/sites", dependencies=[Depends(require_auth)])
def create_site(request: CreateSiteRequest):
    if request.type == "wordpress":
        raise HTTPException(
            status_code=400,
            detail="wordpress sites must be created interactively on the CLI",
        )

    args = [request.domain, request.type]
    if request.php_version:
        args += ["--php-version", request.php_version]
    if request.database:
        args += ["--database"]
    if request.db_engine:
        args += ["--db-engine", request.db_engine]
    if request.proxy_target:
        args += ["--proxy-target", request.proxy_target]

    result = run_script("site-create.sh", args)
    return JSONResponse(content=result, status_code=result["http_status"])


@router.delete("/sites/{domain}", dependencies=[Depends(require_auth)])
def delete_site(
    domain: str,
    skip_backup: bool = Query(False),
    request: Optional[DeleteSiteRequest] = None,
):
    args = [domain]
    if skip_backup:
        expected = f"DELETE {domain}"
        confirm = (request.confirm if request else None) or ""
        if confirm != expected:
            raise HTTPException(
                status_code=400,
                detail=f"skip_backup requires confirmation: {expected}",
            )
        args += ["--skip-backup", "--confirm", expected]

    result = run_script("site-delete.sh", args)
    return JSONResponse(content=result, status_code=result["http_status"])
