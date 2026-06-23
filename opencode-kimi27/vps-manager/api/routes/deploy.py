from fastapi import APIRouter, Depends
from starlette.responses import JSONResponse
from api.auth import require_auth
from api.runner import run_script
from api.schemas import DeployRequest

router = APIRouter()


@router.post("/sites/{domain}/deploy", dependencies=[Depends(require_auth)])
def deploy_static(domain: str, request: DeployRequest):
    result = run_script("deploy.sh", [domain, request.source])
    return JSONResponse(content=result, status_code=result["http_status"])
