"""
AIO Manager -- entry point.
Run with: uv run --extra ui textual/aio_manager.py
"""
from __future__ import annotations
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from textual.app import App
from textual.binding import Binding
from textual.worker import Worker, WorkerState
from models.state import AppState
from screens.main_screen import MainScreen


class AIOManagerApp(App):
    """AIO Manager - Azure IoT Operations TUI."""

    TITLE = "AIO Manager"
    SUB_TITLE = "Azure IoT Operations"
    ENABLE_COMMAND_PALETTE = False

    BINDINGS = [
        Binding("q", "quit", "Quit"),
    ]

    def on_mount(self) -> None:
        self.push_screen(MainScreen(AppState()))

    def on_worker_state_changed(self, event: Worker.StateChanged) -> None:
        """Catch worker crashes so they show as a notification rather than exiting."""
        if event.state == WorkerState.ERROR:
            exc = event.worker.error
            self.notify(
                f"Worker error: {exc}",
                title="Background Task Failed",
                severity="error",
                timeout=10,
            )


if __name__ == "__main__":
    AIOManagerApp().run()
