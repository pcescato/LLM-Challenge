"""
Site management endpoints
GET /sites - List sites
GET /sites/{domain} - Get site details
POST /sites - Create site
DELETE /sites/{domain} - Delete site
"""
import json
from fastapi import APIRouter, Depends, HTTPException, status, Query
from pathlib import Path

from auth import verify_api_token
from schemas import (
    CreateSiteRequest, SiteMetadata, ListSitesResponse,
    DeleteSiteRequest, ScriptResponse
)
from runner import runner
from config import config

router = APIRouter(prefix="/sites", tags=["sites"])


def _read_site_state(domain: str) -> dict:
    """Read site state from JSON file"""
    state_file = Path(config.STATE_DIR) / f"{domain}.json"

    if not state_file.exists():
        raise HTTPException(status_code=404, detail=f"Site not found: {domain}")

    try:
        with open(state_file, 'r') as f:
            return json.load(f)
    except (IOError, json.JSONDecodeError):
        raise HTTPException(status_code=500, detail="Failed to read site state")


def _state_to_metadata(state: dict) -> SiteMetadata:
    """Convert state dict to SiteMetadata"""
    return SiteMetadata(**state)


@router.get("", response_model=ListSitesResponse, summary="List all sites")
async def list_sites(
    token: str = Depends(verify_api_token)
) -> ListSitesResponse:
    """
    List all sites
    Returns metadata for each configured site
    """
    sites_data = []

    state_dir = Path(config.STATE_DIR)
    if not state_dir.exists():
        return ListSitesResponse(sites=[], count=0)

    for state_file in state_dir.glob("*.json"):
        try:
            with open(state_file, 'r') as f:
                state = json.load(f)
                sites_data.append(_state_to_metadata(state))
        except (IOError, json.JSONDecodeError):
            continue  # Skip invalid files

    return ListSitesResponse(
        sites=sites_data,
        count=len(sites_data)
    )


@router.get("/{domain}", response_model=SiteMetadata, summary="Get site details")
async def get_site(
    domain: str,
    token: str = Depends(verify_api_token)
) -> SiteMetadata:
    """
    Get details for a specific site
    Returns site metadata including type, webroot, databases, etc.
    """
    state = _read_site_state(domain)
    return _state_to_metadata(state)


@router.post("", response_model=ScriptResponse, summary="Create new site")
async def create_site(
    request: CreateSiteRequest,
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Create a new site

    Supported types:
    - static: Static HTML/CSS/JS site
    - php: PHP application (requires PHP-FPM)
    - proxy: Reverse proxy to upstream target (proxy_target required)

    Design Decision D6: WordPress is CLI-only (use db-create.sh after site creation)
    Design Decision D7: SFTP password generated in memory, printed once
    Design Decision D1: Credentials never stored in toolkit state

    Returns:
    - Site metadata with SFTP credentials (password printed once in stdout)
    """
    exit_code, stdout, stderr, http_status = runner.create_site(
        domain=request.domain,
        site_type=request.type,
        php_version=request.php_version
    )

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Site creation failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )


@router.delete("/{domain}", response_model=ScriptResponse, summary="Delete site")
async def delete_site(
    domain: str,
    request: DeleteSiteRequest,
    skip_backup: bool = Query(False),
    confirm: str = Query(None),
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Delete a site

    Parameters:
    - skip_backup: Skip automatic backup before deletion (requires confirmation)
    - confirm: Confirmation string (must be "DELETE {domain}" if skip_backup=true)

    Design Decision: Backups are created automatically before any deletion
    Confirmation required only when skipping backup

    Example:
    DELETE /sites/example.com?skip_backup=true&confirm=DELETE+example.com
    """
    # Validate confirmation if skipping backup
    if skip_backup and confirm != f"DELETE {domain}":
        raise HTTPException(
            status_code=400,
            detail=f'Confirmation required: confirm="DELETE {domain}"'
        )

    exit_code, stdout, stderr, http_status = runner.delete_site(
        domain=domain,
        skip_backup=skip_backup,
        confirm=confirm
    )

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Site deletion failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )
