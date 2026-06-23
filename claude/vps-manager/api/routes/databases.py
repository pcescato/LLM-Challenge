"""
Database management endpoints
POST /sites/{domain}/databases - Create database
"""
from fastapi import APIRouter, Depends, HTTPException, status

from auth import verify_api_token
from schemas import CreateDatabaseRequest, ScriptResponse
from runner import runner

router = APIRouter(prefix="/sites", tags=["databases"])


@router.post(
    "/{domain}/databases",
    response_model=ScriptResponse,
    summary="Create database for site"
)
async def create_database(
    domain: str,
    request: CreateDatabaseRequest,
    token: str = Depends(verify_api_token)
) -> ScriptResponse:
    """
    Create a database for a site

    Parameters:
    - engine: mariadb (default) or postgresql
    - install_wordpress: Set to true to install WordPress with this database

    Returns:
    - Database credentials printed once in stdout (wrapped in <<<CREDENTIALS>>> markers)
    - If install_wordpress=true, WordPress is installed and admin credentials are printed

    Design Decision D1: Database password printed once wrapped in markers, never stored
    Design Decision D6: WordPress is single-site only (no multisite support)

    Example:
    POST /sites/example.com/databases
    {
        "engine": "mariadb",
        "install_wordpress": false
    }

    Response includes credentials in stdout:
    <<<CREDENTIALS>>>
    Engine: mariadb
    Database: ex_example_com_mar
    Username: ex_example_com_user
    Password: <random-24-char-password>
    <<<CREDENTIALS>>>
    """
    exit_code, stdout, stderr, http_status = runner.create_database(
        domain=domain,
        engine=request.engine,
        install_wordpress=request.install_wordpress
    )

    if http_status >= 400:
        raise HTTPException(
            status_code=http_status,
            detail=stderr or "Database creation failed"
        )

    return ScriptResponse(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status
    )
