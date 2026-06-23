"""
VPS Manager API
FastAPI application for managing VPS sites, databases, and deployments
"""
import logging
from fastapi import FastAPI, status, HTTPException, Depends
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

# Import configuration
from config import config

# Import authentication
from auth import verify_api_token, get_configured_token

# Import schemas
from schemas import HealthResponse, ErrorResponse

# Import routers
from routes.bootstrap import router as bootstrap_router
from routes.sites import router as sites_router
from routes.databases import router as databases_router
from routes.deploy import router as deploy_router
from routes.backups import router as backups_router
from routes.services import router as services_router

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format=config.API_DESCRIPTION or "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger(__name__)

# Create FastAPI app
app = FastAPI(
    title=config.API_TITLE,
    description=config.API_DESCRIPTION,
    version=config.API_VERSION,
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json"
)

# CORS middleware (localhost only, design decision D2)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["127.0.0.1", "localhost", "http://localhost"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Exception handler for HTTP exceptions
@app.exception_handler(HTTPException)
async def http_exception_handler(request, exc):
    """Custom HTTP exception handler"""
    return JSONResponse(
        status_code=exc.status_code,
        content=ErrorResponse(
            error=exc.detail,
            detail=getattr(exc, 'detail', None)
        ).dict()
    )


# Health check endpoint (no auth required)
@app.get(
    "/health",
    response_model=HealthResponse,
    summary="Health check",
    tags=["health"]
)
async def health() -> HealthResponse:
    """
    Health check endpoint
    No authentication required
    Used for readiness probes and monitoring
    """
    return HealthResponse(
        status="ok",
        version=config.API_VERSION
    )


# Include routers
app.include_router(bootstrap_router)
app.include_router(sites_router)
app.include_router(databases_router)
app.include_router(deploy_router)
app.include_router(backups_router)
app.include_router(services_router)


# Startup event
@app.on_event("startup")
async def startup_event():
    """Application startup"""
    logger.info(f"Starting {config.API_TITLE} v{config.API_VERSION}")

    # Check if authentication is configured
    if get_configured_token():
        logger.info("API authentication enabled (token from file or environment)")
    else:
        logger.warning("API authentication disabled (no token configured)")

    # Ensure directories exist
    config.ensure_directories()

    # Log API binding
    logger.info(f"API binding to {config.API_BIND_HOST}:{config.API_BIND_PORT}")


# Shutdown event
@app.on_event("shutdown")
async def shutdown_event():
    """Application shutdown"""
    logger.info(f"Shutting down {config.API_TITLE}")


# Root endpoint
@app.get(
    "/",
    summary="API root",
    tags=["root"]
)
async def root():
    """
    VPS Manager API root
    See /docs for interactive documentation
    See /redoc for ReDoc documentation
    """
    return {
        "name": config.API_TITLE,
        "version": config.API_VERSION,
        "docs": "/docs",
        "redoc": "/redoc",
        "health": "/health"
    }


# Uvicorn configuration
if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host=config.API_BIND_HOST,
        port=config.API_BIND_PORT,
        workers=config.API_WORKERS,
        log_level="info"
    )
