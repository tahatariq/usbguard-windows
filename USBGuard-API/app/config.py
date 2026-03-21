"""
Configuration loader for USBGuard API.
Reads settings from appsettings.json in the project root.
"""

import json
import os
from dataclasses import dataclass, field
from typing import List


@dataclass
class Settings:
    bigfix_server: str
    bigfix_username: str
    bigfix_password: str
    bigfix_port: int = 52311
    api_keys: List[str] = field(default_factory=list)


def load_settings(config_path: str = None) -> Settings:
    """
    Load settings from appsettings.json.

    Args:
        config_path: Optional explicit path to appsettings.json.
                     Defaults to appsettings.json in the project root
                     (two directories up from this file).

    Returns:
        A populated Settings dataclass.

    Raises:
        FileNotFoundError: If appsettings.json cannot be found.
        KeyError: If a required field is missing from the config file.
        ValueError: If a field contains an invalid value.
    """
    if config_path is None:
        # Resolve relative to this file: app/ -> project root
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        config_path = os.path.join(project_root, "appsettings.json")

    with open(config_path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    bigfix_server = data["bigfix_server"]
    bigfix_username = data["bigfix_username"]
    bigfix_password = data["bigfix_password"]
    bigfix_port = int(data.get("bigfix_port", 52311))
    api_keys = list(data.get("api_keys", []))

    return Settings(
        bigfix_server=bigfix_server,
        bigfix_port=bigfix_port,
        bigfix_username=bigfix_username,
        bigfix_password=bigfix_password,
        api_keys=api_keys,
    )
