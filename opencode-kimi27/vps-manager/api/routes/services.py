from fastapi import APIRouter, Depends
from starlette.responses import JSONResponse
from api.auth import require_auth
from api.runner import run_script

router = APIRouter()

_VALID_ACTIONS = {"start", "stop", "restart", "reload", "status"}


@router.get("/services", dependencies=[Depends(require_auth)])
def list_services_status():
    result = run_script("service.sh", ["all", "status"])
    return JSONResponse(content=result, status_code=result["http_status"])


@router.post("/services/{component}/{action}", dependencies=[Depends(require_auth)])
def service_action(component: str, action: str):
    if action not in _VALID_ACTIONS:
        return JSONResponse(
            content={
                "exit_code": 1,
                "stdout": "",
                "stderr": f"invalid action: {action}",
                "http_status": 400,
            },
            status_code=400,
        )
    result = run_script("service.sh", [component, action])
    return JSONResponse(content=result, status_code=result["http_status"])
