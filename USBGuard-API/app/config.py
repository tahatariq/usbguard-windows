"""
Configuration loader for USBGuard API.
Reads settings from appsettings.json in the project root.
"""

import json
import logging
import os
from dataclasses import dataclass, field
from typing import List, Union

logger = logging.getLogger("usbguard.config")


@dataclass
class Settings:
    bigfix_server: str
    bigfix_username: str
    bigfix_password: str
    bigfix_port: int = 52311
    bigfix_ca_cert: str = ""
    api_keys: List[Union[str, dict]] = field(default_factory=list)


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
        ValueError: If a field contains an invalid value or api_keys is empty.
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
    bigfix_ca_cert = data.get("bigfix_ca_cert", "")
    api_keys = list(data.get("api_keys", []))

    if not api_keys:
        raise ValueError(
            "api_keys must contain at least one key in appsettings.json. "
            "Run generate_api_key.py to create one."
        )

    if bigfix_ca_cert:
        logger.info("BigFix TLS: using CA certificate from %s", bigfix_ca_cert)
    else:
        logger.warning(
            "BigFix TLS: bigfix_ca_cert not configured — SSL verification disabled. "
            "Set bigfix_ca_cert in appsettings.json for production use."
        )

    return Settings(
        bigfix_server=bigfix_server,
        bigfix_port=bigfix_port,
        bigfix_username=bigfix_username,
        bigfix_password=bigfix_password,
        bigfix_ca_cert=bigfix_ca_cert,
        api_keys=api_keys,
    )
