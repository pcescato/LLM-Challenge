"""vps-manager API application.

Binds to 127.0.0.1:8000 only (D2). All routes except /health require a bearer
token. Synchronous in v1 (D4): long operations block until completion.
"""
from __future__ import annotations

import logging

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from .config import settings
from .routes import backups, bootstrap, databases, deploy, services, sites

logging.basicConfig(
    level=logging.DEBUG if settings.debug else logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("vpsmgr")

app = FastAPI(
    title="vps-manager API",
    version="1.0.0",
    description="Local-only VPS management toolkit. Loopback bound (D2).",
)


@app.get("/health", tags=["health"])
async def health() -> JSONResponse:
    """Unauthenticated liveness probe. No state details leaked."""
    return JSONResponse(content={"status": "ok"}, status_code=200)


# Register all route groups. Auth dependency is declared per-router in each file.
app.include_router(bootstrap.router)
app.include_router(sites.router)
app.include_router(databases.router)
app.include_router(deploy.router)
app.include_router(backups.router)
app.include_router(services.router)


@app.on_event("startup")
async def _startup() -> None:
    # D2: surface the bind address prominently in logs.
    log.info("vps-manager API starting on %s:%d (loopback only)",
             settings.api_host, settings.api_port)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "api.main:app",
        host=settings.api_host,
        port=settings.api_port,
        log_level="info",
    )
