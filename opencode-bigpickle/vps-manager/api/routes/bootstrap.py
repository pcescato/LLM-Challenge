from fastapi import APIRouter, Request
from ..schemas import BootstrapRequest, ScriptResponse
from ..runner import run_script, exit_to_http

router = APIRouter()

SCRIPT = "/usr/local/bin/vpsmgr-bootstrap.sh"


@router.post("/bootstrap", response_model=ScriptResponse)
async def bootstrap(req: BootstrapRequest, request: Request):
    args = []
    if req.php_version:
        args.extend(["--php-version", req.php_version])
    if req.api_token:
        args.extend(["--api-token", req.api_token])
    if req.db_root_password:
        args.extend(["--db-root-pass", req.db_root_password])
    ec, stdout, stderr = run_script(SCRIPT, args)
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )
