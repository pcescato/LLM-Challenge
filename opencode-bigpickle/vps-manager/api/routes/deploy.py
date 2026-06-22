from fastapi import APIRouter, Request
from ..schemas import ScriptResponse, DeployRequest
from ..runner import run_script, exit_to_http

router = APIRouter()

SCRIPT = "/usr/local/bin/vpsmgr-deploy.sh"


@router.post("/sites/{domain}/deploy", response_model=ScriptResponse)
async def deploy(domain: str, req: DeployRequest, request: Request):
    args = ["--domain", domain]
    if req.source:
        args.extend(["--source", req.source])
    ec, stdout, stderr = run_script(SCRIPT, args)
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )
