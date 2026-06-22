from fastapi import APIRouter, Request
from ..schemas import ScriptResponse, ServiceActionRequest
from ..runner import run_script, exit_to_http

router = APIRouter()

SCRIPT = "/usr/local/bin/vpsmgr-service.sh"


@router.post("/services/{component}/{action}", response_model=ScriptResponse)
async def service_action(component: str, action: str, request: Request):
    ec, stdout, stderr = run_script(SCRIPT, [component, action])
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )


@router.get("/services")
async def service_status(request: Request):
    ec, stdout, stderr = run_script(SCRIPT, ["all", "status"])
    return ScriptResponse(
        exit_code=ec,
        stdout=stdout,
        stderr=stderr,
        http_status=exit_to_http(ec),
    )
