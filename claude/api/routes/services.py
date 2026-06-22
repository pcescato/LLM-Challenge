"""
Service management endpoints
POST /services/{component}/{action} - Service action
GET /services - Service status snapshot
"""
from fastapi import APIRouter, Depends, HTTPException
from datetime import datetime
import json

from auth import verify_api_token
from schemas import ServiceActionRequest, ScriptResponse, AllServicesStatus, ServiceStatus
from runner import runner

router = APIRouter(prefix="/services", tags=["services"])


@router.get(
    "",
    response_model=AllServicesStatus,
    summary="Get service status"
)
async def get_services_status(
    token: str = Depends(verify_api_token)
) -> AllServicesStatus:
    """
    Get status of all system services

    Returns status snapshot including:
    - caddy: Web server
    - php*: PHP-FPM (one entry per installed version)
    - mariadb: MySQL-compatible database
    - postgresql: PostgreSQL database

    Status values:
    - active: Service is running and enabled
    - inactive (enabled): Service is installed but not running
    - inactive (disabled): Service is not enabled
    - unknown: Service status could not be determined
    """
    exit_code, stdout, stderr, http_status = runner.service_action("all", "status")

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Failed to get service status"
        )

    # Parse stdout into service list
    services = []
    for line in stdout.strip().split('\n'):
        if ':' in line:
            parts = line.split(':', 1)
            if len(parts) == 2:
                service_name = parts[0].strip()
                status_str = parts[1].strip()
                services.append(ServiceStatus(
                    service=service_name,
                    status=status_str
                ))

    return AllServicesStatus(
        timestamp=datetime.utcnow().isoformat() + "Z",
        services=services
    )


@router.post(
    "/{component}/{action}",
    response_model=ScriptResponse,
    summary="Service management action"
)
async def service_action(
    component: str,
    action: str,
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Perform service management action

    Components:
    - caddy: Web server
    - php: PHP-FPM (all installed versions)
    - mariadb: MySQL-compatible database
    - postgresql: PostgreSQL database
    - all: All services

    Actions:
    - start: Start service
    - stop: Stop service
    - restart: Restart service
    - reload: Reload configuration (graceful)
    - status: Show service status

    Examples:
    POST /services/caddy/restart      - Restart Caddy
    POST /services/php/reload          - Reload all PHP-FPM versions
    POST /services/mariadb/stop        - Stop MariaDB
    POST /services/all/status          - Status of all services

    Notes:
    - reload is graceful (no service downtime)
    - restart stops and then starts service
    - status returns current state (active/inactive)
    """
    exit_code, stdout, stderr, http_status = runner.service_action(component, action)

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or f"Service {action} failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )
