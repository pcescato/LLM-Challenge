import os
from fastapi import FastAPI
from starlette.responses import JSONResponse

from api.routes import bootstrap, sites, databases, deploy, backups, services

app = FastAPI(
    title="VPS Manager API",
    description="Minimal FastAPI wrapper around the vpsmgr shell toolkit",
    version="1.0.0",
)

app.include_router(bootstrap.router)
app.include_router(sites.router)
app.include_router(databases.router)
app.include_router(deploy.router)
app.include_router(backups.router)
app.include_router(services.router)


@app.get("/health")
def health():
    return {"status": "ok", "root": os.environ.get("VPSMGR_ROOT", "unknown")}
