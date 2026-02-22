"""
Central reactive state model for AIO Manager.
All panels read from and write to this shared object.
"""

from __future__ import annotations
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Optional


class StepState(Enum):
    NOT_STARTED = auto()
    RUNNING = auto()
    SUCCESS = auto()
    FAILED = auto()


STEP_ICONS = {
    StepState.NOT_STARTED: "[ ]",
    StepState.RUNNING:     "[~]",
    StepState.SUCCESS:     "[x]",
    StepState.FAILED:      "[!]",
}


@dataclass
class EdgeState:
    """Config values used by the Edge panel check workers.
    Populated from aio_config.json by MainScreen after config loads."""
    cluster_name: Optional[str] = None
    resource_group: Optional[str] = None
    kubeconfig_path: Optional[str] = None


@dataclass
class AzureState:
    key_vault: StepState = StepState.NOT_STARTED
    storage_account: StepState = StepState.NOT_STARTED
    schema_registry: StepState = StepState.NOT_STARTED
    iot_operations: StepState = StepState.NOT_STARTED
    role_assignments: StepState = StepState.NOT_STARTED


@dataclass
class ConfigState:
    """Holds the result of the last config load. Populated by MainScreen on mount."""
    loaded: Optional[object] = None  # models.config_loader.LoadedConfig


@dataclass
class AppState:
    edge: EdgeState = field(default_factory=EdgeState)
    azure: AzureState = field(default_factory=AzureState)
    config: ConfigState = field(default_factory=ConfigState)
