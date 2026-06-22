"""Configuration for vpsmgr API."""

from __future__ import annotations

import os

# Resolve paths relative to this package
API_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(API_DIR)

# Paths
SCRIPT_DIR = os.path.join(PROJECT_ROOT, "scripts")
CONFIG_DIR = os.path.join(PROJECT_ROOT, "config")
STATE_DIR = os.environ.get("VPSMGR_STATE_DIR", "/var/lib/vpsmgr/sites")
API_TOKEN_FILE = os.environ.get("VPSMGR_API_TOKEN_FILE", "/etc/vpsmgr/api.token")

# Script paths
BOOTSTRAP_SCRIPT = os.path.join(SCRIPT_DIR, "bootstrap.sh")
SITE_CREATE_SCRIPT = os.path.join(SCRIPT_DIR, "site-create.sh")
SITE_DELETE_SCRIPT = os.path.join(SCRIPT_DIR, "site-delete.sh")
DB_CREATE_SCRIPT = os.path.join(SCRIPT_DIR, "db-create.sh")
DEPLOY_SCRIPT = os.path.join(SCRIPT_DIR, "deploy.sh")
BACKUP_SCRIPT = os.path.join(SCRIPT_DIR, "backup.sh")
SERVICE_SCRIPT = os.path.join(SCRIPT_DIR, "service.sh")

# Server
API_HOST = os.environ.get("VPSMGR_API_HOST", "127.0.0.1")
API_PORT = int(os.environ.get("VPSMGR_API_PORT", "8000"))

# Ensure scripts are executable
def ensure_executables() -> None:
    script_paths = [
        BOOTSTRAP_SCRIPT,
        SITE_CREATE_SCRIPT,
        SITE_DELETE_SCRIPT,
        DB_CREATE_SCRIPT,
        DEPLOY_SCRIPT,
        BACKUP_SCRIPT,
        SERVICE_SCRIPT,
    ]
    for path in script_paths:
        if os.path.exists(path):
            os.chmod(path, 0o755)

ensure_executables()