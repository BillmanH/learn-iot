"""
Config Panel — shows config fields per section (Azure | Cluster | Deployment | Tools)
in a DataTable with values and status. The description from the config 'comments'
block is shown at the bottom when a row is highlighted.
"""

from __future__ import annotations
import os
import subprocess
from textual.app import ComposeResult
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Label, Button, DataTable, TabbedContent, TabPane
from textual.containers import Vertical

from models.config_loader import LoadedConfig, SECTIONS, ConfigField

_TAB_LABELS = {
    "azure": "Azure",
    "cluster": "Cluster",
    "deployment": "Deployment",
    "optional_tools": "Tools",
}


def _status_cell(f: ConfigField) -> str:
    s = f.status
    if s == "MISSING":  return f"[red]{s}[/red]"
    if s == "OK":       return f"[green]{s}[/green]"
    if s in ("ON", "OFF"): return f"[cyan]{s}[/cyan]"
    return s


class ConfigPanel(Widget):
    """Right panel: config fields with descriptions, tabbed by section."""

    class ReloadRequested(Message):
        """Posted when the user clicks Reload. MainScreen handles the actual load."""

    DEFAULT_CSS = """
    ConfigPanel {
        border: round $success;
    }
    """

    _config: LoadedConfig | None = None

    def compose(self) -> ComposeResult:
        yield Label("CONFIG", classes="panel-title")

        with TabbedContent(id="cfg-tabs"):
            for section in SECTIONS:
                label = _TAB_LABELS.get(section, section)
                with TabPane(label, id=f"tab-cfg-{section}", classes="cfg-tabpane"):
                    yield DataTable(
                        id=f"tbl-{section}",
                        cursor_type="row",
                        zebra_stripes=True,
                    )

        with Vertical(classes="action-buttons"):
            yield Button("Validate",       id="btn-validate",    variant="default")
            yield Button("Open in Editor", id="btn-open-editor", variant="default")
            yield Button("Reload",         id="btn-reload",      variant="default")

    def on_mount(self) -> None:
        for section in SECTIONS:
            tbl = self.query_one(f"#tbl-{section}", DataTable)
            tbl.add_column("Field",  key="field",  width=24)
            tbl.add_column("Value",  key="value",  width=26)
            tbl.add_column("Status", key="status", width=8)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-reload":
            self.post_message(self.ReloadRequested())
        elif event.button.id == "btn-open-editor":
            if self._config is None:
                self.app.notify("No config loaded yet.", severity="warning")
                return
            path = str(self._config.path)
            # Try VS Code first, fall back to Windows default app association
            try:
                subprocess.Popen(["code", path], shell=True)
            except Exception:
                os.startfile(path)
        elif event.button.id == "btn-validate":
            if self._config is None:
                self.app.notify("No config loaded yet.", severity="warning")
                return
            if self._config.is_valid:
                self.app.notify("Config is valid — all required fields present.", severity="information")
            else:
                self.app.notify(
                    "\n".join(self._config.errors),
                    title="Validation errors",
                    severity="error",
                    timeout=8,
                )

    def refresh_config(self, config: LoadedConfig) -> None:
        """Populate all section tables from a freshly loaded config."""
        self._config = config
        for section in SECTIONS:
            tbl = self.query_one(f"#tbl-{section}", DataTable)
            tbl.clear()
            rows = config.fields_for(section)
            for f in rows:
                tbl.add_row(
                    f.key,
                    f.display_value,
                    _status_cell(f),
                    key=f"{section}:{f.key}",
                )
            # Size the table to exactly its content — header row + data rows + 1 padding
            tbl.styles.height = len(rows) + 2
        if config.is_valid:
            self.app.notify(
                f"Loaded: {config.path.name}  \u2014  all required fields present",
                severity="information",
                timeout=4,
            )
        else:
            errs = "  |  ".join(config.errors[:3])
            self.app.notify(f"Config errors: {errs}", severity="error", timeout=6)
