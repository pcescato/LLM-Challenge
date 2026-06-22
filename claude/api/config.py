"""
VPS Manager API configuration
Loads from /etc/vpsmgr/vpsmgr.conf or config/vpsmgr.conf
"""
import os
from typing import Optional
from pathlib import Path


class Config:
    """API configuration"""

    # Configuration file locations (in order of precedence)
    CONFIG_PATHS = [
        "/etc/vpsmgr/vpsmgr.conf",
        Path(__file__).parent.parent / "config" / "vpsmgr.conf",
    ]

    # Runtime paths
    CONFIG_DIR: str = "/etc/vpsmgr"
    LOG_DIR: str = "/var/log/vpsmgr"
    STATE_DIR: str = "/var/lib/vpsmgr/sites"
    BACKUP_DIR: str = "/var/backups/vpsmgr"
    CADDY_CONFIG_DIR: str = "/etc/caddy/sites"
    SCRIPTS_DIR: str = "/usr/local/lib/vpsmgr/scripts"

    # API configuration
    API_BIND_HOST: str = "127.0.0.1"
    API_BIND_PORT: int = 8000
    API_WORKERS: int = 4
    API_TIMEOUT: int = 300  # 5 minutes for long operations

    # Version
    API_VERSION: str = "1.0.0"
    API_TITLE: str = "VPS Manager API"
    API_DESCRIPTION: str = "REST API for managing VPS sites, databases, and deployments"

    # Feature flags (v1 baseline)
    FEATURE_ASYNC_JOBS: bool = False
    FEATURE_OFFSITE_BACKUPS: bool = False
    FEATURE_BACKUP_ENCRYPTION: bool = False

    # Backup retention
    BACKUP_RETENTION_DAYS: int = 30

    def __init__(self):
        """Load configuration from file"""
        self._load_config()

    def _load_config(self):
        """Parse configuration file"""
        config_file = self._find_config_file()

        if not config_file:
            # Use defaults if no config file found
            return

        try:
            with open(config_file, 'r') as f:
                for line in f:
                    line = line.strip()
                    # Skip comments and empty lines
                    if not line or line.startswith('#'):
                        continue

                    # Parse key=value pairs (with quotes)
                    if '=' in line:
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip().strip('"\'')

                        # Set attribute if it exists and is uppercase (config var)
                        if hasattr(self, key) and key.isupper():
                            # Type conversion
                            current_type = type(getattr(self, key))
                            if current_type == bool:
                                setattr(self, key, value.lower() in ('true', '1', 'yes'))
                            elif current_type == int:
                                try:
                                    setattr(self, key, int(value))
                                except ValueError:
                                    pass
                            else:
                                setattr(self, key, value)
        except (IOError, OSError):
            pass  # Use defaults if file can't be read

    def _find_config_file(self) -> Optional[str]:
        """Find first existing configuration file"""
        for path in self.CONFIG_PATHS:
            if isinstance(path, Path):
                path = str(path)
            if os.path.exists(path):
                return path
        return None

    def ensure_directories(self):
        """Ensure required directories exist"""
        dirs = [
            self.CONFIG_DIR,
            self.LOG_DIR,
            self.STATE_DIR,
            self.BACKUP_DIR,
            self.CADDY_CONFIG_DIR,
        ]

        for dir_path in dirs:
            try:
                os.makedirs(dir_path, exist_ok=True)
            except OSError:
                # May not have permissions outside of /var/log, etc.
                pass

    def get_script_path(self, script_name: str) -> str:
        """Get full path to a script"""
        # Try system path first
        script_paths = [
            f"/usr/local/lib/vpsmgr/scripts/{script_name}",
            f"/usr/lib/vpsmgr/scripts/{script_name}",
            Path(__file__).parent.parent / "scripts" / script_name,
        ]

        for path in script_paths:
            if isinstance(path, Path):
                path = str(path)
            if os.path.exists(path):
                return path

        # Fallback to working directory scripts
        return f"./scripts/{script_name}"


# Global config instance
config = Config()
