from fastapi import APIRouter, Request
from ..schemas import ScriptResponse, BackupRequest
from ..runner import run_script, exit_to_http

router = APIRouter()

SCRIPT = "/usr/local/bin/vpsmgr-backup.sh"


@router.post("/backups", response_model=ScriptResponse)
async def create_backup(req: BackupRequest, request: Request):
    args = []
    if req.all:
        args.append("--all")
    elif req.domain:
        args.extend(["--domain", req.domain])
    else:
        return ScriptResponse(
            exit_code=1,
            stdout="",
            stderr="Either 'domain' or 'all' is required",
            http_status=400,
        )
    if req.post_hook:
        args.extend(["--post-hook", req.post_hook])
    ec, stdout, stderr = run_script(SCRIPT, args)
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )
