from typing import Literal, Optional
from pydantic import BaseModel, Field


class ScriptResult(BaseModel):
    exit_code: int
    stdout: str
    stderr: str
    http_status: int


class CreateSiteRequest(BaseModel):
    domain: str = Field(..., min_length=1)
    type: Literal["static", "php", "wordpress", "reverse_proxy"]
    php_version: Optional[str] = None
    database: Optional[bool] = False
    db_engine: Optional[Literal["mariadb", "postgres"]] = None
    proxy_target: Optional[str] = None


class DeleteSiteRequest(BaseModel):
    confirm: Optional[str] = None


class CreateDatabaseRequest(BaseModel):
    engine: Optional[Literal["mariadb", "postgres"]] = None


class DeployRequest(BaseModel):
    source: str = Field(..., min_length=1)


class BackupRequest(BaseModel):
    domain: Optional[str] = None
    all: Optional[bool] = False


class ServiceActionRequest(BaseModel):
    component: str
    action: Literal["start", "stop", "restart", "reload", "status"]
