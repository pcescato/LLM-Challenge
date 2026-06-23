"""
Backup endpoints
POST /backups - Create backup(s)
"""
from fastapi import APIRouter, Depends, HTTPException, Query
from typing import Optional

from auth import verify_api_token
from schemas import BackupRequest, ScriptResponse
from runner import runner

router = APIRouter(prefix="/backups", tags=["backups"])


@router.post(
    "",
    response_model=ScriptResponse,
    summary="Create backup(s)"
)
async def create_backup(
    request: Optional[BackupRequest] = None,
    domain: Optional[str] = Query(None),
    all: bool = Query(False),
    post_hook: Optional[str] = Query(None),
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Create backup(s) of sites and databases

    Parameters:
    - domain: Backup specific site (exclusive with all=true)
    - all: Backup all sites (exclusive with domain)
    - post_hook: Shell command to run after backup (e.g., for offsite sync)

    Features:
    - Backs up webroot files (tar.xz format)
    - Backs up all databases associated with site
    - Preserves with chmod 600 for security
    - Automatic pruning of old backups (> 30 days by default)
    - Post-hook support for offsite replication (design decision D3)

    Backup files stored at:
    - /var/backups/vpsmgr/{domain}-files-{timestamp}.tar.xz
    - /var/backups/vpsmgr/{domain}-{db_name}-{timestamp}.sql.xz

    Examples:
    # Backup single site
    POST /backups?domain=example.com

    # Backup all sites
    POST /backups?all=true

    # Backup with post-hook (e.g., S3 sync)
    POST /backups?domain=example.com&post_hook=aws+s3+sync+/var/backups/vpsmgr+s3://my-bucket/backups/

    Design Decision D3: Local backups only in v1. Post-hook for offsite replication.
    Design Decision D8: No encryption in v1 (encryption key would be another secret).
    """
    # Merge request body and query parameters
    backup_domain = None
    backup_all = all
    backup_hook = post_hook

    if request:
        if request.domain:
            backup_domain = request.domain
        if request.all:
            backup_all = request.all
        if request.post_hook:
            backup_hook = request.post_hook

    # Override with query params if provided
    if domain:
        backup_domain = domain
    if all:
        backup_all = all
    if post_hook:
        backup_hook = post_hook

    # Validation
    if backup_all and backup_domain:
        raise HTTPException(
            status_code=400,
            detail="Cannot specify both domain and all=true"
        )

    if not backup_all and not backup_domain:
        raise HTTPException(
            status_code=400,
            detail="Either domain or all=true is required"
        )

    exit_code, stdout, stderr, http_status = runner.backup(
        domain=backup_domain,
        all_sites=backup_all,
        post_hook=backup_hook
    )

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Backup failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )
