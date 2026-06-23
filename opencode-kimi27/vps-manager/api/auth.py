import os
from fastapi import Header, HTTPException, status

_TOKEN = os.environ.get("VPSMGR_API_TOKEN")
if not _TOKEN:
    raise RuntimeError("VPSMGR_API_TOKEN environment variable is not set")


def require_auth(authorization: str = Header(...)) -> None:
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or token != _TOKEN:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing bearer token",
        )
