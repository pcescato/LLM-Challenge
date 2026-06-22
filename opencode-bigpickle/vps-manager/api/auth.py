import os
from fastapi import Header, HTTPException, Request
from typing import Optional


def verify_token(request: Request):
    if request.url.path == "/health":
        return
    token = request.headers.get("Authorization", "")
    expected = request.app.state.config.get("api_token", "")
    if not expected:
        return
    if not token.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing or invalid Authorization header")
    if token.removeprefix("Bearer ") != expected:
        raise HTTPException(status_code=401, detail="Invalid token")
