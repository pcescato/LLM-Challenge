"""Token-based authentication for vpsmgr API."""

from __future__ import annotations

import os

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from api.config import API_TOKEN_FILE

security = HTTPBearer(auto_error=False)


def load_api_token() -> str | None:
    if not os.path.exists(API_TOKEN_FILE):
        return None
    with open(API_TOKEN_FILE) as f:
        token = f.read().strip()
    return token or None


def verify_token(credentials: HTTPAuthorizationCredentials | None = Depends(security)) -> str:
    token = load_api_token()
    if token is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="API token not configured. Run bootstrap first.",
        )
    if credentials is None or credentials.credentials != token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing authentication token",
        )
    return credentials.credentials