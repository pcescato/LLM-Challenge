"""Script runner — executes shell scripts and returns structured results."""

from __future__ import annotations

import subprocess
import shlex
from typing import Union

from api.schemas import ScriptResult


def build_command(script_path: str, args: list[Union[str, None]]) -> list[str]:
    cmd = [script_path]
    for arg in args:
        if arg is not None:
            cmd.append(shlex.quote(str(arg)))
    return cmd


def run_script(
    script_path: str,
    *args: Union[str, None],
    env: dict[str, str] | None = None,
    stdin_input: str | None = None,
    timeout: int = 600,
) -> ScriptResult:
    cmd = [script_path]

    # Build args, skipping None values
    for i, arg in enumerate(args):
        if arg is not None:
            # Boolean flags passed as "--flag" only (not key-value pairs)
            if isinstance(arg, str):
                cmd.append(arg)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            input=stdin_input,
        )
    except subprocess.TimeoutExpired:
        return ScriptResult(
            exit_code=5,
            stdout="",
            stderr=f"Script timed out after {timeout}s",
            http_status=500,
        )
    except FileNotFoundError:
        return ScriptResult(
            exit_code=4,
            stdout="",
            stderr=f"Script not found: {script_path}",
            http_status=422,
        )

    exit_code = result.returncode
    stdout = result.stdout
    stderr = result.stderr

    # Map exit codes to HTTP status
    http_status_map = {
        0: 200,
        1: 400,
        2: 404,
        3: 409,
        4: 422,
        5: 500,
    }
    http_status = http_status_map.get(exit_code, 500)
    if exit_code > 5:
        http_status = 500

    return ScriptResult(
        exit_code=exit_code,
        stdout=stdout,
        stderr=stderr,
        http_status=http_status,
    )