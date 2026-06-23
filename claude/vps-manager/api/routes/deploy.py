"""
Code deployment endpoint
POST /sites/{domain}/deploy - Deploy code to site
"""
from fastapi import APIRouter, Depends, HTTPException

from auth import verify_api_token
from schemas import DeployRequest, ScriptResponse
from runner import runner

router = APIRouter(prefix="/sites", tags=["deploy"])


@router.post(
    "/{domain}/deploy",
    response_model=ScriptResponse,
    summary="Deploy code to site"
)
async def deploy(
    domain: str,
    request: DeployRequest,
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Deploy application files to a site

    Parameters:
    - source: Server-local path to deploy from
      * Can be directory (contents copied)
      * Can be archive file (tar, tar.gz, tar.xz, tar.bz2, zip — auto-extracted)
      * Must be accessible from the API server

    Features:
    - Creates pre-deployment backup (kept for 3 releases)
    - Sets proper permissions for site user
    - For PHP/WordPress sites: checks syntax and reloads PHP-FPM cache
    - Restores from backup if deployment fails

    Example:
    POST /sites/example.com/deploy
    {
        "source": "/tmp/myapp.tar.xz"
    }

    Security:
    - Source must be on the same server (no remote URLs)
    - Files deployed are owned by site user, readable by www-data
    - Backup of previous deployment kept for rollback
    """
    exit_code, stdout, stderr, http_status = runner.deploy(
        domain=domain,
        source=request.source
    )

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Deployment failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )
