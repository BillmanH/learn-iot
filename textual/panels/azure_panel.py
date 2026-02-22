"""
Azure Panel — shows Azure resource deployment steps and script action buttons.
"""

from __future__ import annotations
from textual.app import ComposeResult
from textual.widget import Widget
from textual.widgets import Label, Button, Checkbox, Static
from textual.containers import Vertical

from models.state import AzureState, StepState


class AzurePanel(Widget):
    """Middle panel: Azure resource deployment status and actions."""

    DEFAULT_CSS = """
    AzurePanel {
        border: round $warning;
    }
    """

    def compose(self) -> ComposeResult:
        yield Label("AZURE SETUP", classes="panel-title")

        yield Label("Resources", classes="section-header")
        yield Checkbox("Key Vault",         id="step-kv",     disabled=True)
        yield Checkbox("Storage Account",   id="step-storage", disabled=True)
        yield Checkbox("Schema Registry",   id="step-schema",  disabled=True)
        yield Checkbox("IoT Operations",    id="step-iot",     disabled=True)
        yield Checkbox("Role Assignments",  id="step-roles",   disabled=True)

        yield Label("Actions", classes="section-header")
        with Vertical(classes="action-buttons"):
            yield Button("grant_entra_id_roles.ps1",  id="btn-grant-roles",  variant="default")
            yield Button("External-Configurator.ps1", id="btn-ext-config",   variant="primary")

    def refresh_state(self, state: AzureState) -> None:
        """Update all widgets from the current AzureState."""
        mapping = {
            "#step-kv":      state.key_vault,
            "#step-storage": state.storage_account,
            "#step-schema":  state.schema_registry,
            "#step-iot":     state.iot_operations,
            "#step-roles":   state.role_assignments,
        }
        for selector, step_state in mapping.items():
            self.query_one(selector, Checkbox).value = (step_state == StepState.SUCCESS)
