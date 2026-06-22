"""Pydantic models for vpsmgr API request/response validation."""

from __future__ import annotations

import re
from datetime import datetime
from enum import Enum
from typing import Optional

from pydantic import BaseModel, Field, field_validator


class SiteType(str, Enum):
    STATIC = "static"
    PHP = "php"
    PROXY = "proxy"


class DatabaseEngine(str, Enum):
    MARIADB = "mariadb"
    POSTGRESQL = "postgresql"


class ArchiveType(str, Enum):
    TAR_GZ = "tar.gz"
    ZIP = "zip"


class ServiceAction(str, Enum):
    START = "start"
    STOP = "stop"
    RESTART = "restart"
    RELOAD = "reload"
    STATUS = "status"


class ServiceComponent(str, Enum):
    CADDY = "caddy"
    PHP_FPM = "php-fpm"
    MARIADB = "mariadb"
    POSTGRESQL = "postgresql"
    ALL = "all"


# --- Request schemas ---

class BootstrapRequest(BaseModel):
    pass


class SiteCreateRequest(BaseModel):
    domain: str = Field(..., min_length=4, max_length=253)
    type: SiteType
    proxy_target: Optional[str] = Field(None, max_length=2048)
    php_version: Optional[str] = Field(None, pattern=r"^\d+\.\d+$")

    @field_validator("domain")
    @classmethod
    def validate_domain(cls, v: str) -> str:
        domain_re = r"^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$"
        if not re.match(domain_re, v):
            raise ValueError(f"Invalid domain: {v}")
        return v.lower()

    @field_validator("proxy_target")
    @classmethod
    def check_proxy_target(cls, v: Optional[str], info) -> Optional[str]:
        if info.data.get("type") == SiteType.PROXY and not v:
            raise ValueError("proxy_target is required for proxy site type")
        return v


class SiteDeleteRequest(BaseModel):
    confirm: Optional[str] = None


class DatabaseCreateRequest(BaseModel):
    engine: DatabaseEngine = DatabaseEngine.MARIADB
    db_name: Optional[str] = Field(None, pattern=r"^[a-z][a-z0-9_]{0,63}$")


class DeployRequest(BaseModel):
    source: str = Field(..., min_length=1, max_length=4096)
    archive: Optional[ArchiveType] = None
    backup_before: bool = False


class BackupRequest(BaseModel):
    domain: Optional[str] = None
    all: bool = False
    post_hook: Optional[str] = Field(None, max_length=2048)

    @field_validator("domain")
    @classmethod
    def check_domain_or_all(cls, v: Optional[str], info) -> Optional[str]:
        if not v and not info.data.get("all"):
            raise ValueError("Either domain or all=true must be specified")
        return v.lower() if v else v


# --- Response schemas ---

class ScriptResult(BaseModel):
    exit_code: int
    stdout: str
    stderr: str
    http_status: int


class SiteInfo(BaseModel):
    domain: str
    type: str
    sftp_user: str
    webroot: str
    php_version: Optional[str] = None
    php_pool: Optional[str] = None
    caddy_block: Optional[str] = None
    databases: list[dict] = []
    proxy_target: Optional[str] = None
    created_at: Optional[str] = None


class DatabaseCredentials(BaseModel):
    db_name: str
    db_user: str
    db_host: str
    db_port: int = 3306
    db_engine: str


class ServiceStatus(BaseModel):
    service: str
    status: str


class ServiceStatusList(BaseModel):
    services: list[ServiceStatus]


class HealthResponse(BaseModel):
    status: str = "ok"
    timestamp: str = Field(default_factory=lambda: datetime.utcnow().isoformat() + "Z")


class ErrorResponse(BaseModel):
    detail: str
    status_code: int