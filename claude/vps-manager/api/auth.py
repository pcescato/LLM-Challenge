"""
VPS Manager API authentication
Token-based authentication (Bearer tokens)
"""
import os
import hmac
import hashlib
from typing import Optional
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthCredentials

# Security configuration
API_TOKEN_FILE = "/etc/vpsmgr/api.token"
API_TOKEN_ENV = "VPSMGR_API_TOKEN"

security = HTTPBearer()


def get_configured_token() -> Optional[str]:
    """
    Get configured API token from file or environment
    Design: Token stored in /etc/vpsmgr/api.token (600 perms, root-owned)
    Fallback to environment variable for development
    """
    # Try token file first
    if os.path.exists(API_TOKEN_FILE):
        try:
            with open(API_TOKEN_FILE, 'r') as f:
                token = f.read().strip()
                if token:
                    return token
        except (IOError, OSError):
            pass

    # Fallback to environment variable
    return os.getenv(API_TOKEN_ENV)


def verify_token(token: str) -> bool:
    """Verify API token matches configured token"""
    configured_token = get_configured_token()

    if not configured_token:
        # No token configured, authentication disabled
        return True

    # Use constant-time comparison to prevent timing attacks
    return hmac.compare_digest(token, configured_token)


async def verify_api_token(credentials: HTTPAuthCredentials = Depends(security)) -> str:
    """
    Dependency for protecting routes
    Validates Bearer token
    """
    token = credentials.credentials

    if not verify_token(token):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API token",
            headers={"WWW-Authenticate": "Bearer"},
        )

    return token


def generate_token(length: int = 32) -> str:
    """
    Generate a random API token
    Returns hex-encoded random bytes
    """
    import secrets
    return secrets.token_hex(length // 2)


def write_token_file(token: str) -> None:
    """
    Write token to /etc/vpsmgr/api.token with proper permissions
    Must be run as root
    """
    os.makedirs(os.path.dirname(API_TOKEN_FILE), exist_ok=True)

    # Write token
    with open(API_TOKEN_FILE, 'w') as f:
        f.write(token)

    # Set restrictive permissions (owner read/write only)
    os.chmod(API_TOKEN_FILE, 0o600)


def get_token_for_bearer(token: str) -> str:
    """
    Format token for use in Authorization header
    """
    return f"Bearer {token}"
