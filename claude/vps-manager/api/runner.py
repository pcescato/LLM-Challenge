"""
Script runner for executing VPS Manager shell scripts
Handles subprocess execution, output capture, and exit code mapping
"""
import subprocess
import shlex
import logging
from typing import Dict, Tuple, Optional
from pathlib import Path

from config import config

logger = logging.getLogger(__name__)


class ScriptRunner:
    """Execute scripts and capture output"""

    # Exit code to HTTP status mapping (documented in architecture)
    EXIT_CODE_MAP = {
        0: 200,    # Success
        1: 400,    # Usage / invalid input
        2: 404,    # Not found
        3: 409,    # Conflict / already exists
        4: 422,    # Dependency missing
        5: 500,    # Internal error
    }

    def __init__(self, scripts_dir: Optional[str] = None):
        """Initialize runner with scripts directory"""
        self.scripts_dir = scripts_dir or config.get_script_path("")
        self.timeout = config.API_TIMEOUT

    def run_script(
        self,
        script_name: str,
        *args,
        env: Optional[Dict[str, str]] = None,
        cwd: Optional[str] = None
    ) -> Tuple[int, str, str, int]:
        """
        Execute a script and return (exit_code, stdout, stderr, http_status)

        Args:
            script_name: Name of script to execute (e.g., 'site-create.sh')
            *args: Arguments to pass to script (key=value format)
            env: Environment variables to pass
            cwd: Working directory

        Returns:
            Tuple of (exit_code, stdout, stderr, http_status)
        """
        # Find script path
        script_path = self._find_script(script_name)
        if not script_path:
            logger.error(f"Script not found: {script_name}")
            return 1, "", f"Script not found: {script_name}", 404

        # Build command
        cmd = ["/bin/bash", script_path] + list(args)
        cmd_str = " ".join(shlex.quote(str(c)) for c in cmd)
        logger.info(f"Executing: {cmd_str[:100]}")

        try:
            # Execute script
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.timeout,
                cwd=cwd or "/root",
                env=env
            )

            exit_code = result.returncode
            stdout = result.stdout
            stderr = result.stderr

            # Log execution
            if exit_code != 0:
                logger.warning(
                    f"Script exited with code {exit_code}: {script_name}\n"
                    f"stderr: {stderr[:500]}"
                )
            else:
                logger.debug(f"Script succeeded: {script_name}")

            # Map exit code to HTTP status
            http_status = self.EXIT_CODE_MAP.get(exit_code, 500)

            return exit_code, stdout, stderr, http_status

        except subprocess.TimeoutExpired:
            logger.error(f"Script timeout ({self.timeout}s): {script_name}")
            return 5, "", f"Script execution timeout after {self.timeout}s", 500

        except (OSError, subprocess.SubprocessError) as e:
            logger.error(f"Failed to execute script: {e}")
            return 5, "", f"Script execution error: {str(e)}", 500

    def _find_script(self, script_name: str) -> Optional[str]:
        """Find script in scripts directory"""
        # Search paths (in order of precedence)
        search_paths = [
            f"/usr/local/lib/vpsmgr/scripts/{script_name}",
            f"/usr/lib/vpsmgr/scripts/{script_name}",
            Path(__file__).parent.parent / "scripts" / script_name,
            f"{self.scripts_dir}/{script_name}",
        ]

        for path in search_paths:
            if isinstance(path, Path):
                path = str(path)

            if Path(path).exists() and Path(path).is_file():
                logger.debug(f"Found script: {path}")
                return path

        logger.debug(f"Script not found in any path: {script_name}")
        return None

    def bootstrap(self) -> Tuple[int, str, str, int]:
        """Execute bootstrap.sh"""
        return self.run_script("bootstrap.sh")

    def create_site(self, domain: str, site_type: str = "static",
                   php_version: Optional[str] = None) -> Tuple[int, str, str, int]:
        """Execute site-create.sh"""
        args = [
            f"domain={domain}",
            f"type={site_type}",
        ]
        if php_version:
            args.append(f"php_version={php_version}")
        return self.run_script("site-create.sh", *args)

    def delete_site(self, domain: str, skip_backup: bool = False,
                   confirm: Optional[str] = None) -> Tuple[int, str, str, int]:
        """Execute site-delete.sh"""
        args = [
            f"domain={domain}",
            f"skip_backup={str(skip_backup).lower()}",
        ]
        if confirm:
            args.append(f"confirm={confirm}")
        return self.run_script("site-delete.sh", *args)

    def create_database(self, domain: str, engine: str = "mariadb",
                       install_wordpress: bool = False) -> Tuple[int, str, str, int]:
        """Execute db-create.sh"""
        args = [
            f"domain={domain}",
            f"engine={engine}",
            f"install_wordpress={str(install_wordpress).lower()}",
        ]
        return self.run_script("db-create.sh", *args)

    def deploy(self, domain: str, source: str) -> Tuple[int, str, str, int]:
        """Execute deploy.sh"""
        args = [
            f"domain={domain}",
            f"source={source}",
        ]
        return self.run_script("deploy.sh", *args)

    def backup(self, domain: Optional[str] = None, all_sites: bool = False,
              post_hook: Optional[str] = None) -> Tuple[int, str, str, int]:
        """Execute backup.sh"""
        args = []
        if domain:
            args.append(f"domain={domain}")
        if all_sites:
            args.append("all=true")
        if post_hook:
            args.append(f"post_hook={shlex.quote(post_hook)}")
        return self.run_script("backup.sh", *args)

    def service_action(self, component: str, action: str) -> Tuple[int, str, str, int]:
        """Execute service.sh"""
        return self.run_script("service.sh", component, action)


# Global runner instance
runner = ScriptRunner()
