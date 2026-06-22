"""vpsmgr API — FastAPI application.

Bind: 127.0.0.1:8000 only. No external exposure.
"""

from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from api.config import API_HOST, API_PORT
from api.routes import backups, bootstrap, databases, deploy, services, sites
from api.schemas import HealthResponse


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield


app = FastAPI(
    title="VPS Manager API",
    version="1.0.0",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    return JSONResponse(
        status_code=500,
        content={
            "exit_code": 5,
            "stdout": "",
            "stderr": f"Internal server error: {exc}",
            "http_status": 500,
        },
    )


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    return HealthResponse()


# Register routers
app.include_router(bootstrap.router)
app.include_router(sites.router)
app.include_router(databases.router)
app.include_router(deploy.router)
app.include_router(backups.router)
app.include_router(services.router)


def main() -> None:
    import uvicorn
    uvicorn.run(
        "api.main:app",
        host=API_HOST,
        port=API_PORT,
        log_level="info",
        access_log=False,
    )


if __name__ == "__main__":
    main()