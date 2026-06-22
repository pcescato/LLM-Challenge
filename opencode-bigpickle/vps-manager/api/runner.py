import subprocess
import shlex
from typing import Tuple


def run_script(script_path: str, args: list[str] = None, env: dict = None) -> Tuple[int, str, str]:
    cmd = [script_path]
    if args:
        cmd.extend(args)
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


def exit_to_http(exit_code: int) -> int:
    mapping = {
        0: 200,
        1: 400,
        2: 404,
        3: 409,
        4: 422,
        5: 500,
    }
    return mapping.get(exit_code, 500)
