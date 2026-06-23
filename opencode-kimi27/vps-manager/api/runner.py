import os
import subprocess
from pathlib import Path
from typing import List, Dict, Any


def _project_root() -> Path:
    return Path(__file__).resolve().parent.parent


def _http_status_for_exit_code(code: int) -> int:
    mapping = {
        0: 200,
        1: 400,
        2: 404,
        3: 409,
        4: 422,
        5: 500,
    }
    return mapping.get(code, 500)


def run_script(script: str, args: List[str], timeout: int = 600) -> Dict[str, Any]:
    root = _project_root()
    script_path = root / "scripts" / script

    if os.geteuid() == 0:
        cmd = [str(script_path)] + args
    else:
        cmd = ["sudo", "-n", str(script_path)] + args

    env = os.environ.copy()
    env.setdefault("VPSMGR_ROOT", str(root))
    env.setdefault("NONINTERACTIVE", "1")

    proc = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        cwd=str(root),
        env=env,
        timeout=timeout,
    )

    return {
        "exit_code": proc.returncode,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
        "http_status": _http_status_for_exit_code(proc.returncode),
    }
