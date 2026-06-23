from fastapi import APIRouter, Depends, HTTPException
from starlette.responses import JSONResponse
from api.auth import require_auth
from api.runner import run_script
from api.schemas import BackupRequest

router = APIRouter()


@router.post("/backups", dependencies=[Depends(require_auth)])
def create_backup(request: BackupRequest):
    if not request.domain and not request.all:
        raise HTTPException(status_code=400, detail="domain or all is required")
    if request.domain and request.all:
        raise HTTPException(status_code=400, detail="specify domain or all, not both")

    args = []
    if request.all:
        args.append("--all")
    elif request.domain:
        args += ["--domain", request.domain]

    result = run_script("backup.sh", args, timeout=1800)
    return JSONResponse(content=result, status_code=result["http_status"])
