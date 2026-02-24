"""
Config loader — reads aio_config.json, flattens sections into typed ConfigField
objects, and annotates each field with its description from the 'comments' block.
"""

from __future__ import annotations
import json
import pathlib
from dataclasses import dataclass, field
from typing import Any, Optional

# Sections the UI shows as separate tabs
SECTIONS = ("azure", "cluster", "deployment", "optional_tools")

# Fields that must not be empty for the config to be considered valid
REQUIRED_FIELDS: dict[str, list[str]] = {
    "azure": ["subscription_id", "resource_group", "location", "cluster_name"],
    "cluster": ["node_ip", "kube_server"],
    "deployment": ["deployment_mode"],
    "optional_tools": [],
}

# Locate config relative to this file in dev mode, or next to the .exe when frozen.
import sys as _sys

def _find_repo_root() -> pathlib.Path:
    if getattr(_sys, "frozen", False):
        return pathlib.Path(_sys.executable).parent
    return pathlib.Path(__file__).parent.parent.parent

_REPO_ROOT = _find_repo_root()
DEFAULT_CONFIG_PATH = _REPO_ROOT / "config" / "aio_config.json"


@dataclass
class ConfigField:
    section: str
    key: str
    value: Any
    description: str
    required: bool

    @property
    def is_empty(self) -> bool:
        v = self.value
        return v is None or v == "" or v == {}

    @property
    def status(self) -> str:
        if self.required and self.is_empty:
            return "MISSING"
        if isinstance(self.value, bool):
            return "ON" if self.value else "OFF"
        if self.is_empty:
            return "--"
        return "OK"

    @property
    def display_value(self) -> str:
        if isinstance(self.value, bool):
            return str(self.value).lower()
        if self.value is None or self.value == "":
            return ""
        return str(self.value)


@dataclass
class LoadedConfig:
    path: pathlib.Path
    data: dict
    fields: list[ConfigField]
    errors: list[str]

    @property
    def is_valid(self) -> bool:
        return len(self.errors) == 0

    def fields_for(self, section: str) -> list[ConfigField]:
        return [f for f in self.fields if f.section == section]


def _get_description(comments: dict, section: str, key: str) -> str:
    """Pull description from the nested comments dict."""
    section_comments = comments.get(section, {})
    if isinstance(section_comments, dict):
        desc = section_comments.get(key, "")
        if desc:
            return str(desc)
    # Fall back to top-level comments key
    return str(comments.get(key, ""))


def load_config(path: pathlib.Path = DEFAULT_CONFIG_PATH) -> LoadedConfig:
    errors: list[str] = []

    try:
        raw = path.read_text(encoding="utf-8")
        data = json.loads(raw)
    except FileNotFoundError:
        return LoadedConfig(path=path, data={}, fields=[], errors=[f"File not found: {path}"])
    except json.JSONDecodeError as e:
        return LoadedConfig(path=path, data={}, fields=[], errors=[f"JSON parse error: {e}"])

    comments: dict = data.get("comments", {})
    fields: list[ConfigField] = []

    for section in SECTIONS:
        section_data = data.get(section, {})
        if not isinstance(section_data, dict):
            continue
        required_keys = REQUIRED_FIELDS.get(section, [])
        for key, value in section_data.items():
            if key.startswith("_"):   # skip internal/note keys
                continue
            description = _get_description(comments, section, key)
            required = key in required_keys
            f = ConfigField(
                section=section,
                key=key,
                value=value,
                description=description,
                required=required,
            )
            fields.append(f)
            if required and f.is_empty:
                errors.append(f"[{section}] '{key}' is required but empty")

    return LoadedConfig(path=path, data=data, fields=fields, errors=errors)
