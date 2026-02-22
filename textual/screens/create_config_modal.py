"""
CreateConfigModal — shown when aio_config.json is missing on startup.
Returns one of: "blank" | "defaults" | None (exit).
"""

from __future__ import annotations
import json
import pathlib
from datetime import datetime, timezone

from textual.app import ComposeResult
from textual.screen import ModalScreen
from textual.widgets import Label, Button, Static
from textual.containers import Vertical, Horizontal


# ---------------------------------------------------------------------------
# Config templates
# ---------------------------------------------------------------------------

def _blank_config() -> dict:
    """All structure present, every user-specific field left empty."""
    return {
        "config_type": "quickstart",
        "azure": {
            "subscription_id": "",
            "subscription_name": "",
            "resource_group": "",
            "location": "",
            "cluster_name": "",
            "key_vault_name": "",
            "enable_arc_on_install": False,
            "deploy_iot_operations": False,
        },
        "cluster": {
            "node_name": "",
            "node_ip": "",
            "kube_server": "",
            "kubernetes_version": "",
            "node_os": "Linux",
            "kubeconfig_path": "~/.kube/config",
            "arc_connected": False,
            "custom_locations_enabled": False,
            "workload_identity_enabled": False,
            "deployment_type": "standard_k3s",
            "generated_at": "",
            "ready_for_arc": False,
            "installer_version": "",
        },
        "deployment": {
            "skip_system_update": False,
            "deployment_mode": "test",
        },
        "optional_tools": {
            "k9s": False,
            "mqtt-viewer": False,
            "ssh": False,
        },
        "comments": _comments_block(),
    }


def _defaults_config() -> dict:
    """Sensible defaults pre-filled; user-specific fields use placeholder text."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "config_type": "quickstart",
        "azure": {
            "subscription_id": "",
            "subscription_name": "",
            "resource_group": "aio-resource-group",
            "location": "eastus",
            "cluster_name": "aio-cluster",
            "key_vault_name": "aio-keyvault",
            "enable_arc_on_install": True,
            "deploy_iot_operations": True,
        },
        "cluster": {
            "node_name": "edge-device",
            "node_ip": "192.168.1.100",
            "kube_server": "https://192.168.1.100:6443",
            "kubernetes_version": "",
            "node_os": "Linux",
            "kubeconfig_path": "~/.kube/config",
            "arc_connected": False,
            "custom_locations_enabled": False,
            "workload_identity_enabled": False,
            "deployment_type": "standard_k3s",
            "generated_at": now,
            "ready_for_arc": False,
            "installer_version": "",
        },
        "deployment": {
            "skip_system_update": False,
            "deployment_mode": "test",
        },
        "optional_tools": {
            "k9s": True,
            "mqtt-viewer": True,
            "ssh": True,
        },
        "comments": _comments_block(),
    }


def _comments_block() -> dict:
    return {
        "_note": (
            "cluster_info.json is still written by installer.sh for backward compatibility "
            "with PowerShell scripts. The 'cluster' section here is the canonical source for the UI."
        ),
        "config_type": (
            "Quickstart mode: automated setup with Arc enablement and IoT Operations deployment "
            "using sensible defaults; Advanced mode: manual control with selective automation and skip flags."
        ),
        "subscription_id": "Leave empty to use current logged-in subscription, or provide your Azure subscription GUID",
        "subscription_name": "Leave empty to use current logged-in subscription, or provide subscription display name",
        "resource_group": "Name of Azure resource group (will be created if it doesn't exist)",
        "location": "Azure region (e.g., eastus, westus2, westeurope, northeurope)",
        "cluster_name": "Name for your Arc-enabled Kubernetes cluster",
        "key_vault_name": (
            "Name for your Azure Key Vault (3-24 chars, alphanumeric and hyphens only, "
            "must be globally unique). Used for AIO secret sync."
        ),
        "enable_arc_on_install": "Set to true to Arc-enable cluster during installation (requires Azure CLI and login)",
        "deploy_iot_operations": "Set to true to deploy Azure IoT Operations automatically with default settings",
        "deployment_mode": "Options: 'test' for development, 'secure' for production (future)",
        "skip_system_update": "Set to true to skip apt update/upgrade for faster runs",
        "optional_tools": {
            "k9s": "Terminal UI for Kubernetes cluster management. Recommended for quickstart.",
            "mqtt-viewer": "Installs mosquitto-clients (mosquitto_sub, mosquitto_pub) for MQTT debugging.",
            "ssh": "Secure remote shell access. Set to true if you need remote management.",
        },
        "cluster": {
            "node_name": "Hostname of the Linux edge device running K3s.",
            "node_ip": "IP address of the edge device — used for SSH and as the K3s API server address.",
            "kube_server": "Full URL of the Kubernetes API server (e.g., https://<node_ip>:6443).",
            "kubernetes_version": "K3s version string reported by the node. Populated by installer.sh.",
            "node_os": "Operating system of the edge node (always Linux for AIO).",
            "kubeconfig_path": "Path to kubeconfig on the edge device. Default: ~/.kube/config.",
            "arc_connected": "True once arc_enable.ps1 has successfully connected the cluster to Azure Arc.",
            "custom_locations_enabled": "True once the custom-locations Arc feature is enabled (required for AIO).",
            "workload_identity_enabled": "True once workload identity webhook pods are running (required for Key Vault sync).",
            "deployment_type": "Type of K3s deployment — e.g., 'windows_aks_edge' or 'standard_k3s'.",
            "generated_at": "ISO 8601 timestamp of when installer.sh last wrote this cluster info.",
            "ready_for_arc": "Set to true by installer.sh when the cluster is ready to be Arc-enabled.",
            "installer_version": "Version of the installer or AKS Edge Essentials that was used.",
        },
    }


def write_config(path: pathlib.Path, template: str) -> None:
    """Write the chosen config template to *path*, creating parent dirs if needed."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = _defaults_config() if template == "defaults" else _blank_config()
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


# ---------------------------------------------------------------------------
# Modal widget
# ---------------------------------------------------------------------------

class CreateConfigModal(ModalScreen[str | None]):
    """
    Displayed when aio_config.json is not found.
    Dismisses with:
      "blank"    — create a blank config skeleton
      "defaults" — create a config with sensible defaults pre-filled
      None       — exit the application
    """

    DEFAULT_CSS = """
    CreateConfigModal {
        align: center middle;
    }

    #modal-container {
        width: 64;
        height: auto;
        border: double $warning;
        padding: 1 2;
        background: $surface;
    }

    #modal-title {
        text-align: center;
        text-style: bold;
        color: $warning;
        margin-bottom: 1;
    }

    #modal-body {
        text-align: center;
        color: $text;
        margin-bottom: 1;
    }

    #modal-path {
        text-align: center;
        color: $text-muted;
        text-style: italic;
        margin-bottom: 1;
    }

    #modal-hint {
        text-align: center;
        color: $text-muted;
        margin-bottom: 1;
    }

    #btn-row {
        align: center middle;
        height: auto;
        margin-top: 1;
    }

    #btn-row Button {
        margin: 0 1;
    }

    #btn-blank {
        width: 18;
    }

    #btn-defaults {
        width: 22;
    }

    #btn-exit {
        width: 10;
    }
    """

    def __init__(self, config_path: pathlib.Path) -> None:
        super().__init__()
        self._config_path = config_path

    def compose(self) -> ComposeResult:
        with Vertical(id="modal-container"):
            yield Static("Configuration File Not Found", id="modal-title")
            yield Static(
                "aio_config.json could not be located.\n"
                "Would you like to create one now?",
                id="modal-body",
            )
            yield Static(str(self._config_path), id="modal-path")
            yield Static(
                "Blank: all fields empty, ready to fill in.\n"
                "Defaults: common values pre-filled as a starting point.",
                id="modal-hint",
            )
            with Horizontal(id="btn-row"):
                yield Button("Create Blank",    id="btn-blank",    variant="primary")
                yield Button("Create Defaults", id="btn-defaults", variant="success")
                yield Button("Exit",            id="btn-exit",     variant="error")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-blank":
            self.dismiss("blank")
        elif event.button.id == "btn-defaults":
            self.dismiss("defaults")
        elif event.button.id == "btn-exit":
            self.dismiss(None)
