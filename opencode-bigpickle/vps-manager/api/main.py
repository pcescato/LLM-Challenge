import os
import sys
import uvicorn
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import load_config
from auth import verify_token
from routes.bootstrap import router as bootstrap_router
from routes.sites import router as sites_router
from routes.databases import router as databases_router
from routes.deploy import router as deploy_router
from routes.backups import router as backups_router
from routes.services import router as services_router

app = FastAPI(title="VPS Manager API", version="1.0.0")

CONFIG_PATH = os.environ.get("VPSMGR_CONFIG", "/etc/vpsmgr/vpsmgr.conf")


@app.on_event("startup")
async def startup():
    app.state.config = load_config(CONFIG_PATH)


@app.middleware("http")
async def auth_middleware(request: Request, call_next):
    try:
        verify_token(request)
    except Exception as e:
        return JSONResponse(
            status_code=getattr(e, "status_code", 500),
            content={"detail": str(e)},
        )
    return await call_next(request)


@app.get("/health")
async def health():
    return {"status": "ok"}


app.include_router(bootstrap_router)
app.include_router(sites_router)
app.include_router(databases_router)
app.include_router(deploy_router)
app.include_router(backups_router)
app.include_router(services_router)


def main():
    config = load_config(CONFIG_PATH)
    host = config.get("api_host", "127.0.0.1")
    port = int(config.get("api_port", "8000"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    main()
