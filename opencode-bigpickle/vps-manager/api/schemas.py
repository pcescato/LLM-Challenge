from pydantic import BaseModel, Field
from typing import Optional, Any


class ScriptResponse(BaseModel):
    exit_code: int
    stdout: str
    stderr: str
    http_status: int


class BootstrapRequest(BaseModel):
    php_version: Optional[str] = None
    api_token: Optional[str] = None
    db_root_password: Optional[str] = None


class SiteCreateRequest(BaseModel):
    domain: str
    type: str = "static"
    php_version: Optional[str] = None
    proxy_target: Optional[str] = None


class SiteDeleteRequest(BaseModel):
    confirm: str


class DatabaseCreateRequest(BaseModel):
    engine: str = "mariadb"
    prefix: Optional[str] = None


class DeployRequest(BaseModel):
    source: Optional[str] = None


class BackupRequest(BaseModel):
    domain: Optional[str] = None
    all: bool = False
    post_hook: Optional[str] = None


class ServiceActionRequest(BaseModel):
    component: str = "all"
    action: str = "status"
