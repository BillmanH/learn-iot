"""
AIO Manager -- entry point.
Run with: uv run --extra ui textual/aio_manager.py
"""
from __future__ import annotations
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from textual.app import App
from models.state import AppState
from screens.main_screen import MainScreen


class AIOManagerApp(App):
    """AIO Manager - Azure IoT Operations TUI."""

    TITLE = "AIO Manager"
    SUB_TITLE = "Azure IoT Operations"

    BINDINGS = [
        ("q", "quit", "Quit"),
        ("f1", "action_show_help", "Help"),
    ]

    def on_mount(self) -> None:
        self.push_screen(MainScreen(AppState()))

    def action_show_help(self) -> None:
        self.notify(
            "Q: Quit  |  F1: Help  |  Tab/Click: switch log tabs",
            title="Key Bindings",
            timeout=5,
        )


if __name__ == "__main__":
    AIOManagerApp().run()
