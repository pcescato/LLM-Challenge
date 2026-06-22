from fastapi import APIRouter, Request
from ..schemas import ScriptResponse, DatabaseCreateRequest
from ..runner import run_script, exit_to_http

router = APIRouter()

SCRIPT = "/usr/local/bin/vpsmgr-db-create.sh"


@router.post("/sites/{domain}/databases", response_model=ScriptResponse)
async def create_database(domain: str, req: DatabaseCreateRequest, request: Request):
    args = ["--domain", domain, "--engine", req.engine]
    if req.prefix:
        args.extend(["--prefix", req.prefix])
    ec, stdout, stderr = run_script(SCRIPT, args)
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )
