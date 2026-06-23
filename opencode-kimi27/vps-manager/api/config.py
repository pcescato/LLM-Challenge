from pathlib import Path
from typing import Dict


_RUNTIME_CFG = Path("/etc/vpsmgr/vpsmgr.conf")


def _project_root() -> Path:
    # api/config.py -> ../../
    return Path(__file__).resolve().parent.parent


def load_config() -> Dict[str, str]:
    if _RUNTIME_CFG.exists():
        cfg_path = _RUNTIME_CFG
    else:
        cfg_path = _project_root() / "config" / "vpsmgr.conf"

    settings: Dict[str, str] = {}
    for raw in cfg_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip('"').strip("'")
        settings[key.strip()] = value
    return settings


SETTINGS = load_config()
