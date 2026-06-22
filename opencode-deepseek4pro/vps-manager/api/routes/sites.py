"""Sites routes — create, list, get, delete sites."""

from __future__ import annotations

import json
import os
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query

from api.auth import verify_token
from api.config import SITE_CREATE_SCRIPT, SITE_DELETE_SCRIPT, STATE_DIR
from api.runner import run_script
from api.schemas import ScriptResult, SiteCreateRequest, SiteDeleteRequest, SiteInfo

router = APIRouter()


@router.get("/sites")
async def list_sites(_token: str = Depends(verify_token)) -> list[str]:
    if not os.path.isdir(STATE_DIR):
        return []
    domains = []
    for f in os.listdir(STATE_DIR):
        if f.endswith(".json"):
            domains.append(f[:-5])
    return sorted(domains)


@router.get("/sites/{domain}")
async def get_site(domain: str, _token: str = Depends(verify_token)) -> SiteInfo:
    state_file = os.path.join(STATE_DIR, f"{domain}.json")
    if not os.path.isfile(state_file):
        raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")

    with open(state_file) as f:
        data = json.load(f)

    return SiteInfo(
        domain=data.get("domain", domain),
        type=data.get("type", "unknown"),
        sftp_user=data.get("sftp_user", ""),
        webroot=data.get("webroot", ""),
        php_version=data.get("php_version"),
        php_pool=data.get("php_pool"),
        caddy_block=data.get("caddy_block"),
        databases=data.get("databases", []),
        proxy_target=data.get("proxy_target"),
        created_at=data.get("created_at"),
    )


@router.post("/sites", response_model=ScriptResult)
async def create_site(
    body: SiteCreateRequest,
    _token: str = Depends(verify_token),
) -> ScriptResult:
    if body.type.value == "wordpress":
        raise HTTPException(
            status_code=400,
            detail="wordpress site type is not supported via API. Use CLI with --wp-interactive.",
        )

    args = ["--domain", body.domain, "--type", body.type.value]
    if body.proxy_target:
        args.extend(["--proxy-target", body.proxy_target])
    if body.php_version:
        args.extend(["--php-version", body.php_version])

    return run_script(SITE_CREATE_SCRIPT, *args)


@router.delete("/sites/{domain}", response_model=ScriptResult)
async def delete_site(
    domain: str,
    skip_backup: bool = Query(False),
    body: Optional[SiteDeleteRequest] = None,
    _token: str = Depends(verify_token),
) -> ScriptResult:
    state_file = os.path.join(STATE_DIR, f"{domain}.json")
    if not os.path.isfile(state_file):
        raise HTTPException(status_code=404, detail=f"Site '{domain}' not found")

    args = ["--domain", domain]

    if skip_backup:
        confirm = f"DELETE {domain}\n"
        args.append("--skip-backup")
        return run_script(SITE_DELETE_SCRIPT, *args, stdin_input=confirm)
    else:
        return run_script(SITE_DELETE_SCRIPT, *args)