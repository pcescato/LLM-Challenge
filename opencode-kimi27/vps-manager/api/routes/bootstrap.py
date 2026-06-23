from fastapi import APIRouter, Depends
from starlette.responses import JSONResponse
from api.auth import require_auth
from api.runner import run_script

router = APIRouter()


@router.post("/bootstrap", dependencies=[Depends(require_auth)])
def bootstrap_stack():
    result = run_script("bootstrap.sh", [], timeout=1800)
    return JSONResponse(content=result, status_code=result["http_status"])
