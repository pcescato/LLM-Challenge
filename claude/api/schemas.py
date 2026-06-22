"""
Pydantic request/response schemas for VPS Manager API
"""
from typing import Optional, List
from datetime import datetime
from pydantic import BaseModel, Field, validator


class HealthResponse(BaseModel):
    status: str = "ok"
    version: str = "1.0.0"


class ScriptResponse(BaseModel):
    """Standard script execution response"""
    exit_code: int
    stdout: str
    stderr: str
    http_status: int


class BootstrapRequest(BaseModel):
    """Bootstrap system initialization (idempotent)"""
    pass


class CreateSiteRequest(BaseModel):
    """Create a new site"""
    domain: str
    type: str = Field(default="static", regex="^(static|php|proxy)$")
    php_version: Optional[str] = None
    proxy_target: Optional[str] = None

    @validator('domain')
    def validate_domain(cls, v):
        if not v or len(v) < 3:
            raise ValueError('Invalid domain')
        return v.lower()


class SiteMetadata(BaseModel):
    """Site metadata from state file"""
    domain: str
    type: str
    sftp_user: str
    webroot: str
    php_version: Optional[str] = None
    php_pool: Optional[str] = None
    caddy_block: str
    databases: List[dict] = []
    proxy_target: Optional[str] = None
    created_at: str


class ListSitesResponse(BaseModel):
    """List of all sites"""
    sites: List[SiteMetadata]
    count: int


class DeleteSiteRequest(BaseModel):
    """Delete a site"""
    skip_backup: bool = False
    confirm: Optional[str] = None


class CreateDatabaseRequest(BaseModel):
    """Create database for a site"""
    engine: str = Field(default="mariadb", regex="^(mariadb|postgresql)$")
    install_wordpress: bool = False


class DatabaseCredentials(BaseModel):
    """Database credentials (printed once)"""
    engine: str
    database: str
    username: str
    password: str


class DeployRequest(BaseModel):
    """Deploy code to a site"""
    source: str = Field(..., description="Server-local path to deploy from")

    @validator('source')
    def validate_source(cls, v):
        if not v or len(v) < 1:
            raise ValueError('Source path required')
        return v


class BackupRequest(BaseModel):
    """Create backup(s)"""
    domain: Optional[str] = None
    all: bool = False
    post_hook: Optional[str] = None


class ServiceActionRequest(BaseModel):
    """Service management action"""
    component: str = Field(..., regex="^(caddy|php|mariadb|postgresql|all)$")
    action: str = Field(..., regex="^(start|stop|restart|reload|status)$")


class ServiceStatus(BaseModel):
    """Service status information"""
    service: str
    status: str  # active, inactive, unknown


class AllServicesStatus(BaseModel):
    """Status of all system services"""
    timestamp: str
    services: List[ServiceStatus]


class ErrorResponse(BaseModel):
    """Error response"""
    error: str
    detail: Optional[str] = None
    exit_code: Optional[int] = None


class TokenResponse(BaseModel):
    """Token information"""
    token: str
    type: str = "bearer"
    expires_in: Optional[int] = None
