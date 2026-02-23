"""
Azure Panel — Phase 4.

Displays:
  * Five StepRows showing deployment state per resource (not started / running / success / failed)
  * "Build Azure Resources" button  — runs External-Configurator.ps1 via ps_worker
  * "Grant Entra ID Permissions" button — opens OID popup then runs grant_entra_id_roles.ps1

On mount, deployment_summary.json is parsed to pre-populate any already-deployed resources.
Step states are then updated live by MainScreen as it parses script output.
"""

from __future__ import annotations

import json
import pathlib

from textual.app import ComposeResult
from textual.widget import Widget
from textual.widgets import Label, Button, Static
from textual.containers import Vertical

from models.state import AzureState, StepState


# Path to the deployment summary produced by External-Configurator.ps1
_SUMMARY_PATH = (
    pathlib.Path(__file__).parent.parent.parent / "config" / "deployment_summary.json"
)

# Ordered steps: (id, display label)
_STEPS: list[tuple[str, str]] = [
    ("kv",      "Key Vault"),
    ("storage", "Storage Account"),
    ("schema",  "Schema Registry"),
    ("iot",     "IoT Operations"),
    ("roles",   "Role Assignments"),
]

# Keys in deployment_summary["deployed_resources"] -> step id
_SUMMARY_KEY_MAP: dict[str, str] = {
    "keyVault":       "kv",
    "storageAccount": "storage",
    "schemaRegistry": "schema",
}


# ── StepRow ───────────────────────────────────────────────────────────────────

class StepRow(Widget):
    """One deployment step: coloured icon + label that reflects StepState."""

    _ICONS: dict[StepState, str] = {
        StepState.NOT_STARTED: "○",
        StepState.RUNNING:     "⟳",
        StepState.SUCCESS:     "✓",
        StepState.FAILED:      "✗",
    }
    _CSS: dict[StepState, str] = {
        StepState.NOT_STARTED: "step-icon--idle",
        StepState.RUNNING:     "step-icon--running",
        StepState.SUCCESS:     "step-icon--success",
        StepState.FAILED:      "step-icon--failed",
    }

    DEFAULT_CSS = """
    StepRow {
        height: 1;
        margin-bottom: 0;
    }
    """

    def __init__(self, step_id: str, label: str) -> None:
        super().__init__()
        self._step_id = step_id
        self._label   = label
        self._state   = StepState.NOT_STARTED

    def compose(self) -> ComposeResult:
        yield Static(
            f"  ○  {self._label}",
            id=f"step-{self._step_id}",
            classes="step-label step-icon--idle",
        )

    def set_state(self, state: StepState) -> None:
        self._state = state
        icon = self._ICONS[state]
        css  = self._CSS[state]
        row  = self.query_one(f"#step-{self._step_id}", Static)
        row.update(f"  {icon}  {self._label}")
        row.set_classes(f"step-label {css}")


# ── AzurePanel ────────────────────────────────────────────────────────────────

class AzurePanel(Widget):
    """Middle panel: Azure resource deployment status and action buttons."""

    DEFAULT_CSS = """
    AzurePanel {
        border: round $warning;
    }
    """

    def compose(self) -> ComposeResult:
        yield Label("AZURE SETUP", classes="panel-title")

        yield Label("Resources", classes="section-header")
        for step_id, label in _STEPS:
            yield StepRow(step_id, label)

        yield Label("Actions", classes="section-header")
        with Vertical(classes="action-buttons"):
            yield Button(
                "Check Azure Resources",
                id="btn-check-azure",
                variant="default",
            )
            yield Button(
                "Grant Entra ID Permissions",
                id="btn-grant-roles",
                variant="default",
            )
            yield Button(
                "Build Azure Resources",
                id="btn-ext-config",
                variant="primary",
            )

        yield Static("", id="azure-status", classes="azure-status-line")

    def on_mount(self) -> None:
        self._load_summary()

    # ── Summary pre-population ────────────────────────────────────────────────

    def _load_summary(self) -> None:
        """Read deployment_summary.json and mark already-deployed steps as SUCCESS."""
        if not _SUMMARY_PATH.exists():
            return
        try:
            data: dict = json.loads(_SUMMARY_PATH.read_text(encoding="utf-8"))
        except Exception:
            return

        deployed: list[str] = data.get("deployed_resources", [])

        for key, step_id in _SUMMARY_KEY_MAP.items():
            if key in deployed:
                self.set_step_state(step_id, StepState.SUCCESS)

        # IoT Operations is stored as "IoTOperationsInstance:<name>"
        if any(r.startswith("IoTOperationsInstance:") for r in deployed):
            self.set_step_state("iot", StepState.SUCCESS)

    # ── Public API called by MainScreen ──────────────────────────────────────

    def set_step_state(self, step_id: str, state: StepState) -> None:
        """Update one step row to the given state."""
        try:
            for row in self.query(StepRow):
                if row._step_id == step_id:
                    row.set_state(state)
                    return
        except Exception:
            pass

    def set_all_infra_running(self) -> None:
        """Mark the four infrastructure steps RUNNING when External-Configurator starts."""
        for step_id in ("kv", "storage", "schema", "iot"):
            self.set_step_state(step_id, StepState.RUNNING)

    def set_roles_running(self) -> None:
        self.set_step_state("roles", StepState.RUNNING)

    def get_running_steps(self) -> list[str]:
        """Return step_ids currently in RUNNING state."""
        return [
            row._step_id
            for row in self.query(StepRow)
            if row._state == StepState.RUNNING
        ]

    def get_step_states(self) -> dict[str, StepState]:
        """Return a snapshot of all step states keyed by step_id."""
        return {row._step_id: row._state for row in self.query(StepRow)}

    def set_buttons_enabled(self, enabled: bool) -> None:
        self.query_one("#btn-check-azure", Button).disabled = not enabled
        self.query_one("#btn-grant-roles", Button).disabled = not enabled
        self.query_one("#btn-ext-config",  Button).disabled = not enabled

    def set_status(self, message: str) -> None:
        """Update the one-line status text below the buttons."""
        self.query_one("#azure-status", Static).update(message)

    def refresh_state(self, state: AzureState) -> None:
        """Called on mount by MainScreen for compatibility (summary JSON is used instead)."""
        pass
