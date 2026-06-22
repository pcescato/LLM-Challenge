import configparser
import os


def load_config(path: str = "/etc/vpsmgr/vpsmgr.conf") -> dict:
    config = configparser.ConfigParser()
    config.optionxform = str
    if os.path.exists(path):
        config.read(path)
        return dict(config["DEFAULT"]) if "DEFAULT" in config.sections() else _parse_flat(path)
    return _default_config()


def _parse_flat(path: str) -> dict:
    result = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, val = line.split("=", 1)
                result[key.strip()] = val.strip()
    return result


def _default_config() -> dict:
    return {
        "state_dir": "/var/lib/vpsmgr/sites",
        "log_dir": "/var/log/vpsmgr",
        "backup_dir": "/var/backups/vpsmgr",
        "webroot_base": "/home",
        "caddy_sites_dir": "/etc/caddy/sites",
        "api_host": "127.0.0.1",
        "api_port": "8000",
        "api_token": "",
        "php_default_version": "",
        "db_root_user": "root",
        "db_root_password": "",
        "backup_retention_days": "30",
    }
