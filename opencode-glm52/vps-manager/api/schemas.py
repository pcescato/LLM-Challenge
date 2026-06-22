"""Pydantic schemas for the vps-manager API.

All operations are synchronous in v1 (D4). These schemas validate inbound
request bodies only — they never carry secrets in any persisted form.
Credential-bearing responses (e.g. db-create) are returned verbatim from
script stdout, wrapped in <<<CREDENTIALS>>> markers, and never logged.
"""
from __future__ import annotations

from typing import Optional, Literal
from pydantic import BaseModel, Field, field_validator, model_validator


# --- Bootstrap -------------------------------------------------------------

class BootstrapRequest(BaseModel):
    with_api: bool = Field(default=False, description="Install + enable the vpsmgr-api systemd unit.")
    no_caddy: bool = False
    no_php: bool = False
    no_db: bool = False
    no_wp: bool = False
    no_sftp_harden: bool = False


# --- Sites -----------------------------------------------------------------

SiteType = Literal["static", "php", "proxy", "wordpress"]


class SiteCreateRequest(BaseModel):
    domain: str = Field(..., min_length=3, max_length=253)
    type: SiteType
    proxy_target: Optional[str] = None
    php_version: Optional[str] = Field(default=None, pattern=r"^\d+\.\d+$")
    db_engine: Optional[Literal["mariadb", "postgresql"]] = None
    db_name: Optional[str] = None
    no_db: bool = False

    @field_validator("domain")
    @classmethod
    def _validate_domain(cls, v: str) -> str:
        import re
        v = v.strip().lower()
        if not re.fullmatch(
            r"([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?",
            v,
        ):
            raise ValueError("invalid domain")
        return v

    @field_validator("type")
    @classmethod
    def _reject_wordpress_via_api(cls, v: str) -> str:
        # D7/constraint: WordPress admin creds are TTY-only; API must reject.
        if v == "wordpress":
            raise ValueError(
                "wordpress site creation is CLI-only (interactive admin credentials) "
                "and cannot be performed via the API"
            )
        return v

    @model_validator(mode="after")
    def _require_proxy_target_for_proxy(self) -> "SiteCreateRequest":
        if self.type == "proxy" and not self.proxy_target:
            raise ValueError("proxy_target is required when type=proxy")
        return self


class SiteDeleteRequest(BaseModel):
    confirm: Optional[str] = Field(
        default=None,
        description='Required when skip_backup=true. Must equal "DELETE <domain>".',
    )
    skip_backup: bool = False


class DatabaseEntry(BaseModel):
    engine: Literal["mariadb", "postgresql"]
    name: str


class SiteState(BaseModel):
    domain: str
    type: SiteType
    sftp_user: str
    webroot: str
    php_version: Optional[str] = None
    php_pool: Optional[str] = None
    caddy_block: str
    databases: list[DatabaseEntry] = Field(default_factory=list)
    proxy_target: Optional[str] = None
    created_at: str


# --- Databases -------------------------------------------------------------

class DatabaseCreateRequest(BaseModel):
    engine: Literal["mariadb", "postgresql"] = "mariadb"
    name: Optional[str] = None


# --- Deploy ----------------------------------------------------------------

class DeployRequest(BaseModel):
    source: str = Field(..., description="Server-local path to deploy from.")
    rsync_args: Optional[str] = None

    @field_validator("source")
    @classmethod
    def _must_be_local_path(cls, v: str) -> str:
        v = v.strip()
        if v.startswith(("http://", "https://", "rsync://")) or "@" in v and ":" in v:
            raise ValueError("remote sources not supported; use a server-local path")
        return v


# --- Backups ---------------------------------------------------------------

class BackupRequest(BaseModel):
    domain: Optional[str] = None
    all: bool = Field(default=False, alias="all")
    post_hook: Optional[str] = Field(default=None, description="Escape hatch for off-site upload (D3).")

    model_config = {"populate_by_name": True}

    @field_validator("domain")
    @classmethod
    def _validate_domain(cls, v):
        if v is None:
            return v
        import re
        if not re.fullmatch(
            r"([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?",
            v.lower(),
        ):
            raise ValueError("invalid domain")
        return v.lower()

    @model_validator(mode="after")
    def _exactly_one_target(self) -> "BackupRequest":
        if self.all and self.domain:
            raise ValueError("provide either {domain} or {all: true}, not both")
        if not self.all and not self.domain:
            raise ValueError("either {domain} or {all: true} is required")
        return self


# --- Services --------------------------------------------------------------

ServiceComponent = Literal["caddy", "php", "mariadb", "postgresql", "all"]
ServiceAction = Literal["start", "stop", "restart", "reload", "status", "enable", "disable"]


class ServiceRequest(BaseModel):
    # Body is optional; path params may carry the values.
    component: Optional[ServiceComponent] = None
    action: Optional[ServiceAction] = None


# --- Generic script-result envelope ---------------------------------------

class ScriptResult(BaseModel):
    exit_code: int
    stdout: str
    stderr: str
    http_status: int
