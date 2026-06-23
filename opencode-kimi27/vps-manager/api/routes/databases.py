from fastapi import APIRouter, Depends, HTTPException
from starlette.responses import JSONResponse
from api.auth import require_auth
from api.runner import run_script
from api.schemas import CreateDatabaseRequest

router = APIRouter()


@router.post("/sites/{domain}/databases", dependencies=[Depends(require_auth)])
def create_database(domain: str, request: CreateDatabaseRequest):
    args = [domain]
    if request.engine:
        args.append(request.engine)
    result = run_script("db-create.sh", args)
    return JSONResponse(content=result, status_code=result["http_status"])
