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

    # App-level CSS — Applied globally to every screen and widget in the DOM.
    # Defined here (not on MainScreen) so it affects all named widget types
    # (EdgePanel, AzurePanel, ConfigPanel, etc.) which require app-scope to render.
    CSS = """
/* ─── App shell ──────────────────────────────────────────────────────────── */

Screen {
    layout: vertical;
    background: $background;
}

/* ─── Three-panel row ────────────────────────────────────────────────────── */

#panels {
    height: 3fr;
    layout: horizontal;
    padding: 0;
}

/* Each panel takes equal horizontal space */
EdgePanel, AzurePanel, ConfigPanel {
    width: 1fr;
    height: 100%;
    padding: 1 2;
    overflow-y: auto;
}

EdgePanel {
    border: round $primary;
}

AzurePanel {
    border: round $warning;
}

ConfigPanel {
    border: round $success;
    layout: vertical;
    overflow-y: hidden;
}

/* DataTable section list — shrinks to fit content */
#cfg-tabs {
    height: auto;
}

/* cfg-tabs panes auto-size */
.cfg-tabpane {
    height: auto;
    padding: 0 1;
}

/* ─── Panel internals ────────────────────────────────────────────────────── */

.panel-title {
    text-style: bold;
    margin-bottom: 1;
}

.section-header {
    color: $text-disabled;
    margin-top: 1;
}

.status-connected {
    color: $success;
}

.status-disconnected {
    color: $error;
}

.status-unknown {
    color: $text-disabled;
}

.action-buttons {
    margin-top: 1;
    layout: vertical;
}

Button {
    width: 100%;
    margin-bottom: 1;
}

Checkbox {
    margin: 0;
    padding: 0;
}

/* ─── Edge panel — step rows ────────────────────────────────────────────── */

EdgeStepRow {
    height: 1;
    layout: horizontal;
    margin-bottom: 0;
}

.edge-step-icon {
    width: 3;
    content-align: center middle;
}

.edge-step-label {
    padding: 0 1;
    height: 1;
}

.edge-step-icon--idle    { color: $text-disabled; }
.edge-step-icon--running { color: $warning; }
.edge-step-icon--pass    { color: $success; }
.edge-step-icon--fail    { color: $error; }

/* ─── Legacy check rows ──────────────────────────────────────────────────── */

.section-hint {
    color: $text-disabled;
    text-style: italic;
    margin-bottom: 1;
}

.check-row-top {
    height: auto;
    layout: horizontal;
}

.check-btn {
    width: 1fr;
    margin-bottom: 0;
}

.check-icon {
    width: 3;
    content-align: center middle;
    margin-left: 1;
}

.check-icon--idle    { color: $text-disabled; }
.check-icon--running { color: $warning; }
.check-icon--pass    { color: $success; }
.check-icon--fail    { color: $error; }

.check-btn--running {
    background: $warning 20%;
    border: tall $warning;
    color: $warning;
}

.check-btn--pass {
    background: $success 20%;
    border: tall $success;
    color: $success;
}

.check-btn--fail {
    background: $error 20%;
    border: tall $error;
    color: $error;
}

.check-message {
    height: auto;
    margin: 0 1 1 1;
    padding: 0 1;
}

.check-message--pass {
    color: $success;
}

.check-message--fail {
    color: $warning;
    background: $error 10%;
    border-left: thick $error;
    padding: 1;
}

.log-btn {
    margin-top: 1;
    min-width: 14;
    padding: 0 2;
    background: $surface;
    color: $text;
    border: tall $warning 60%;
}
.log-btn:hover {
    background: $warning 20%;
    color: $warning;
    border: tall $warning;
}

.run-all-btn {
    margin-top: 1;
}

.readiness-banner {
    margin-top: 1;
    padding: 1;
    text-align: center;
    text-style: bold;
    height: auto;
}

.readiness-banner--hint   { color: $text-disabled; }
.readiness-banner--ready  { color: $success; background: $success 10%; }
.readiness-banner--issues { color: $error;   background: $error 10%; }

/* ─── Log area ───────────────────────────────────────────────────────────── */

#log-area {
    height: 1fr;
    border: round $surface;
    padding: 0;
}

#log-toolbar {
    height: 3;
    align: right middle;
    padding: 0 1;
    background: $surface;
    border-bottom: solid $surface-lighten-1;
}

.log-toolbar-btn {
    height: 1;
    width: auto;
    min-width: 18;
    margin-left: 1;
    background: $surface-lighten-2;
    color: $text-muted;
    border: none;
}

#log {
    height: 1fr;
    scrollbar-size: 1 1;
}

/* ─── Azure panel — step rows ────────────────────────────────────────────── */

.step-label {
    padding: 0 1;
    height: 1;
}

.step-icon--idle    { color: $text-disabled; }
.step-icon--running { color: $warning; }
.step-icon--success { color: $success; }
.step-icon--failed  { color: $error; }

.azure-status-line {
    color: $text-muted;
    margin-top: 1;
    text-style: italic;
}
"""

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

    def on_exception(self, error: Exception) -> None:
        """Write any unhandled Textual exception to the crash log so blackscreen is diagnosable."""
        import traceback
        import pathlib
        if getattr(sys, "frozen", False):
            p = pathlib.Path(sys.executable).parent / "aio_manager_crash.log"
        else:
            p = pathlib.Path(__file__).parent.parent / "aio_manager_crash.log"
        try:
            with open(p, "a", encoding="utf-8") as f:
                f.write(traceback.format_exc() + "\n")
        except Exception:
            pass


if __name__ == "__main__":
    import traceback
    import pathlib

    # Resolve crash log path: next to the exe when frozen, or repo root in dev
    if getattr(sys, "frozen", False):
        _crash_log = pathlib.Path(sys.executable).parent / "aio_manager_crash.log"
    else:
        _crash_log = pathlib.Path(__file__).parent.parent / "aio_manager_crash.log"

    try:
        # Enable Textual's internal log so we can see CSS/compose errors
        import os
        os.environ.setdefault("TEXTUAL_LOG", str(_crash_log.with_suffix(".textual.log")))
        AIOManagerApp().run()
    except Exception:
        _crash_log.write_text(traceback.format_exc(), encoding="utf-8")
        raise
