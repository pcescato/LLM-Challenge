import json
import os
from fastapi import APIRouter, Query, Request
from ..schemas import ScriptResponse, SiteCreateRequest, SiteDeleteRequest
from ..runner import run_script, exit_to_http

router = APIRouter()

SCRIPT_CREATE = "/usr/local/bin/vpsmgr-site-create.sh"
SCRIPT_DELETE = "/usr/local/bin/vpsmgr-site-delete.sh"


@router.get("/sites")
async def list_sites(request: Request):
    state_dir = request.app.state.config.get("state_dir", "/var/lib/vpsmgr/sites")
    sites = []
    if os.path.isdir(state_dir):
        for fname in sorted(os.listdir(state_dir)):
            if fname.endswith(".json"):
                fpath = os.path.join(state_dir, fname)
                with open(fpath) as f:
                    sites.append(json.load(f))
    return sites


@router.get("/sites/{domain}")
async def get_site(domain: str, request: Request):
    state_dir = request.app.state.config.get("state_dir", "/var/lib/vpsmgr/sites")
    fpath = os.path.join(state_dir, f"{domain}.json")
    if not os.path.isfile(fpath):
        return ScriptResponse(exit_code=2, stdout="", stderr=f"Site {domain} not found", http_status=404)
    with open(fpath) as f:
        return json.load(f)


@router.post("/sites", response_model=ScriptResponse)
async def create_site(req: SiteCreateRequest, request: Request):
    if req.type == "wordpress":
        return ScriptResponse(
            exit_code=1,
            stdout="",
            stderr="WordPress sites cannot be created via API (requires interactive TTY for admin setup). Use CLI.",
            http_status=400,
        )
    args = ["--domain", req.domain, "--type", req.type]
    if req.php_version:
        args.extend(["--php-version", req.php_version])
    if req.proxy_target:
        args.extend(["--proxy", req.proxy_target])
    ec, stdout, stderr = run_script(SCRIPT_CREATE, args)
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )


@router.delete("/sites/{domain}", response_model=ScriptResponse)
async def delete_site(
    domain: str,
    request: Request,
    skip_backup: bool = Query(False),
    confirm: str = "",
):
    args = ["--domain", domain]
    if skip_backup:
        if confirm != f"DELETE {domain}":
            return ScriptResponse(
                exit_code=1,
                stdout="",
                stderr=f"Confirmation required: 'DELETE {domain}'",
                http_status=400,
            )
        args.append("--skip-backup")
    ec, stdout, stderr = run_script(SCRIPT_DELETE, args)
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )
