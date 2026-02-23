"""
OIDInputModal — asks the user for an Entra ID Object ID before running
grant_entra_id_roles.ps1.

Dismisses with the OID string on confirm, or None on cancel.
"""

from __future__ import annotations

from textual.app import ComposeResult
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label, Static
from textual.containers import Vertical, Horizontal


class OIDInputModal(ModalScreen[str | None]):
    """Modal that collects an Entra ID Object ID from the user."""

    DEFAULT_CSS = """
    OIDInputModal {
        align: center middle;
    }

    OIDInputModal > Vertical {
        width: 70;
        height: auto;
        background: $surface;
        border: round $warning;
        padding: 1 2;
    }

    OIDInputModal .modal-title {
        text-style: bold;
        color: $warning;
        margin-bottom: 1;
    }

    OIDInputModal .modal-body {
        margin-bottom: 1;
        color: $text-muted;
    }

    OIDInputModal .oid-hint {
        color: $text-disabled;
        margin-bottom: 1;
    }

    OIDInputModal Input {
        margin-bottom: 1;
    }

    OIDInputModal .button-row {
        align-horizontal: right;
        height: auto;
    }

    OIDInputModal .button-row Button {
        margin-left: 1;
    }
    """

    def compose(self) -> ComposeResult:
        with Vertical():
            yield Label("Grant Entra ID Permissions", classes="modal-title")
            yield Static(
                "Enter the Object ID (OID) of the user or service principal that "
                "should receive permissions.",
                classes="modal-body",
            )
            yield Static(
                "Get your OID with:  az ad signed-in-user show --query id -o tsv",
                classes="oid-hint",
            )
            yield Input(
                placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
                id="oid-input",
            )
            with Horizontal(classes="button-row"):
                yield Button("Cancel", id="btn-cancel", variant="default")
                yield Button("Run", id="btn-run", variant="warning")

    def on_mount(self) -> None:
        self.query_one("#oid-input", Input).focus()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-run":
            oid = self.query_one("#oid-input", Input).value.strip()
            self.dismiss(oid if oid else None)
        elif event.button.id == "btn-cancel":
            self.dismiss(None)

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Allow pressing Enter in the input to confirm."""
        oid = event.value.strip()
        self.dismiss(oid if oid else None)
