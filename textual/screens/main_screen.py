"""
Main screen — composes the three panels and the log pane into a single layout.
"""

from __future__ import annotations
from textual.app import ComposeResult
from textual.screen import Screen
from textual.widgets import Header, Footer, TabbedContent, TabPane, RichLog
from textual.containers import Horizontal, Vertical

from panels.edge_panel import EdgePanel, CheckRow
from panels.azure_panel import AzurePanel
from panels.config_panel import ConfigPanel
from models.state import AppState
from models.config_loader import load_config, DEFAULT_CONFIG_PATH
from screens.create_config_modal import CreateConfigModal, write_config


class MainScreen(Screen):
    """Single-screen layout: three panels above a tabbed log pane."""

    CSS_PATH = "../styles/app.tcss"

    def __init__(self, state: AppState) -> None:
        super().__init__()
        self.state = state

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="panels"):
            yield ConfigPanel(id="panel-config")
            yield EdgePanel(id="panel-edge")
            yield AzurePanel(id="panel-azure")

        with Vertical(id="log-area"):
            with TabbedContent(id="log-tabs"):
                with TabPane("All", id="tab-all"):
                    yield RichLog(id="log-all", highlight=True, markup=True)
                with TabPane("Edge", id="tab-edge"):
                    yield RichLog(id="log-edge", highlight=True, markup=True)
                with TabPane("Azure", id="tab-azure"):
                    yield RichLog(id="log-azure", highlight=True, markup=True)
        yield Footer()

    async def on_mount(self) -> None:
        self.query_one("#panel-azure", AzurePanel).refresh_state(self.state.azure)
        self.log_all("[dim]AIO Manager started.[/dim]")
        await self._load_config()

    async def _load_config(self) -> None:
        """Load aio_config.json and push it into the config panel and edge panel.

        If the file does not exist, show the CreateConfigModal so the user can
        create a blank or defaults config before proceeding.
        """
        if not DEFAULT_CONFIG_PATH.exists():
            choice = await self.app.push_screen_wait(
                CreateConfigModal(DEFAULT_CONFIG_PATH)
            )
            if choice is None:
                # User chose Exit
                self.app.exit()
                return
            try:
                write_config(DEFAULT_CONFIG_PATH, choice)
                self.log_all(
                    f"[green][CONFIG][/green] Created {DEFAULT_CONFIG_PATH.name} "
                    f"({choice} template)"
                )
            except Exception as exc:
                self.log_all(f"[red][CONFIG][/red] Failed to create config: {exc}")
                return

        config = load_config()
        self.state.config.loaded = config
        self.query_one("#panel-config", ConfigPanel).refresh_config(config)
        if config.is_valid:
            self.log_all(f"[green][CONFIG][/green] Loaded {config.path.name} — OK")
        else:
            for err in config.errors:
                self.log_all(f"[red][CONFIG][/red] {err}")

        # Wire edge verification checks from config values
        azure = config.data.get("azure", {})
        cluster = config.data.get("cluster", {})
        cluster_name   = azure.get("cluster_name", "")
        resource_group = azure.get("resource_group", "")
        kubeconfig_path = cluster.get("kubeconfig_path", "~/.kube/config")

        self.state.edge.cluster_name    = cluster_name
        self.state.edge.resource_group  = resource_group
        self.state.edge.kubeconfig_path = kubeconfig_path

        edge_panel = self.query_one("#panel-edge", EdgePanel)
        if cluster_name and resource_group:
            edge_panel.set_check_config(cluster_name, resource_group, kubeconfig_path)
        else:
            self.log_edge("[yellow]cluster_name / resource_group missing — edge checks cannot run[/yellow]")

    async def on_config_panel_reload_requested(self, _: ConfigPanel.ReloadRequested) -> None:
        """Re-read aio_config.json from disk and refresh both config and edge panels."""
        self.log_all("[dim][CONFIG] Reloading...[/dim]")
        await self._load_config()

    def on_check_row_result_ready(self, event: CheckRow.ResultReady) -> None:
        """Log every check result to the EDGE log tab."""
        icon = "✓" if event.passed else "✗"
        color = "green" if event.passed else "red"
        self.log_edge(f"[{color}]{icon} {event.check_id}[/{color}]")

    # ── Logging helpers ────────────────────────────────────────────────────

    def log_all(self, message: str) -> None:
        self.query_one("#log-all", RichLog).write(message)

    def log_edge(self, message: str) -> None:
        self.query_one("#log-edge", RichLog).write(message)
        self.log_all(f"[blue][EDGE][/blue] {message}")

    def log_azure(self, message: str) -> None:
        self.query_one("#log-azure", RichLog).write(message)
        self.log_all(f"[yellow][AZURE][/yellow] {message}")
