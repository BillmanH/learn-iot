"""
Edge Panel — Phase 3 verification.

Seven clickable check buttons verify the edge device is ready:
  Verification 1 (az CLI, local): Arc Connected | Custom Locations | Workload Identity
  Verification 2 (kubectl, local): Arc Pods | RBAC Bindings | Operator Permissions | Device Registry CRDs

Each button turns green on pass or shows remediation text on fail.
Config values (cluster_name, resource_group, kubeconfig_base64) are injected
by MainScreen via set_check_config() after aio_config.json is loaded.
"""

from __future__ import annotations

import asyncio
import os
from typing import Awaitable, Callable, Optional

from textual import work
from textual.app import ComposeResult
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Button, Label, Static
from textual.containers import Horizontal

from workers.check_worker import CheckResult, _LOG_PATH


# ── CheckRow ──────────────────────────────────────────────────────────────────

class CheckRow(Widget):
    """One verifiable check: a button that runs an async check and shows the result."""

    DEFAULT_CSS = """
    CheckRow {
        height: auto;
        margin-bottom: 1;
    }
    """

    class Started(Message):
        """Posted just before a check begins running — lets EdgePanel close other rows."""
        def __init__(self, check_id: str) -> None:
            super().__init__()
            self.check_id = check_id

    class ResultReady(Message):
        """Posted to the parent when a check completes."""
        def __init__(self, check_id: str, passed: bool) -> None:
            super().__init__()
            self.check_id = check_id
            self.passed = passed

    def __init__(self, check_id: str, label: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self.check_id = check_id
        self._label = label
        self._check_fn: Optional[Callable[[], Awaitable[CheckResult]]] = None
        self._state = "idle"  # idle | running | pass | fail

    def compose(self) -> ComposeResult:
        with Horizontal(classes="check-row-top"):
            yield Button(self._label, id=f"btn-{self.check_id}", classes="check-btn")
            yield Label("○", id=f"icon-{self.check_id}", classes="check-icon check-icon--idle")
        yield Static("", id=f"msg-{self.check_id}", classes="check-message")
        log_btn = Button("Open Logs", id=f"log-btn-{self.check_id}", classes="log-btn")
        log_btn.display = False
        yield log_btn

    def set_check_fn(self, fn: Callable[[], Awaitable[CheckResult]]) -> None:
        """Wire up the async check function. Called by EdgePanel.set_check_config()."""
        self._check_fn = fn

    # ── Button press ──────────────────────────────────────────────────────────

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == f"log-btn-{self.check_id}":
            event.stop()
            os.startfile(str(_LOG_PATH))
            return
        if event.button.id != f"btn-{self.check_id}":
            return
        event.stop()
        if self._check_fn is None:
            self._set_message(
                "Config not loaded. Ensure cluster_name, resource_group, and "
                "kubeconfig_path are filled in aio_config.json, then reload config.",
                fail=True,
            )
            return
        self.post_message(self.Started(self.check_id))
        self._set_running()
        self._do_run()

    @work(exclusive=True)
    async def _do_run(self) -> None:
        assert self._check_fn is not None
        result = await self._check_fn()
        self._set_result(result)
        self.post_message(self.ResultReady(self.check_id, result.passed))

    # ── State transitions ─────────────────────────────────────────────────────

    def _set_running(self) -> None:
        self._state = "running"
        btn = self.query_one(f"#btn-{self.check_id}", Button)
        btn.label = f"⟳  {self._label}"
        btn.set_classes("check-btn check-btn--running")
        icon = self.query_one(f"#icon-{self.check_id}", Label)
        icon.update("⟳")
        icon.set_classes("check-icon check-icon--running")
        self.query_one(f"#msg-{self.check_id}", Static).update("")
        self.query_one(f"#log-btn-{self.check_id}", Button).display = False

    def _set_result(self, result: CheckResult) -> None:
        btn = self.query_one(f"#btn-{self.check_id}", Button)
        icon = self.query_one(f"#icon-{self.check_id}", Label)
        msg = self.query_one(f"#msg-{self.check_id}", Static)
        if result.passed:
            self._state = "pass"
            btn.label = f"✓  {self._label}"
            btn.set_classes("check-btn check-btn--pass")
            icon.update("✓")
            icon.set_classes("check-icon check-icon--pass")
            msg.update(result.detail)
            msg.set_classes("check-message check-message--pass")
        else:
            self._state = "fail"
            btn.label = f"✗  {self._label}"
            btn.set_classes("check-btn check-btn--fail")
            icon.update("✗")
            icon.set_classes("check-icon check-icon--fail")
            msg.update(result.remediation)
            msg.set_classes("check-message check-message--fail")
            self.query_one(f"#log-btn-{self.check_id}", Button).display = True

    def _set_message(self, text: str, fail: bool = False) -> None:
        msg = self.query_one(f"#msg-{self.check_id}", Static)
        msg.update(text)
        cls = "check-message--fail" if fail else "check-message--pass"
        msg.set_classes(f"check-message {cls}")

    def clear_message(self) -> None:
        """Hide the result/error text below this row without changing the button state."""
        msg = self.query_one(f"#msg-{self.check_id}", Static)
        msg.update("")
        msg.set_classes("check-message")
        self.query_one(f"#log-btn-{self.check_id}", Button).display = False

    def reset(self) -> None:
        """Reset to idle state (used by Run All before re-running)."""
        self._state = "idle"
        btn = self.query_one(f"#btn-{self.check_id}", Button)
        btn.label = self._label
        btn.set_classes("check-btn")
        icon = self.query_one(f"#icon-{self.check_id}", Label)
        icon.update("○")
        icon.set_classes("check-icon check-icon--idle")
        self.query_one(f"#msg-{self.check_id}", Static).update("")
        self.query_one(f"#log-btn-{self.check_id}", Button).display = False


# ── EdgePanel ─────────────────────────────────────────────────────────────────

class EdgePanel(Widget):
    """Left panel: edge device Arc/RBAC verification checks."""

    _ALL_CHECKS = [
        "arc-connected",
        "custom-locations",
        "workload-identity",
        "arc-pods",
        "rbac-bindings",
        "operator-permissions",
        "device-registry-crds",
    ]

    def compose(self) -> ComposeResult:
        yield Label("EDGE VERIFICATION", classes="panel-title")

        yield Label("Verification 1 — Azure Arc (az CLI)", classes="section-header")
        yield Static(
            "Reads cluster_name + resource_group from aio_config.json.",
            classes="section-hint",
        )
        yield CheckRow("arc-connected",    "Check Arc Connected",    id="check-arc-connected")
        yield CheckRow("custom-locations", "Check Custom Locations",  id="check-custom-locations")
        yield CheckRow("workload-identity","Check Workload Identity", id="check-workload-identity")

        yield Label("Verification 2 — Kubernetes RBAC (kubectl)", classes="section-header")
        yield Static(
            "Uses kubeconfig_path from aio_config.json cluster section.",
            classes="section-hint",
        )
        yield CheckRow("arc-pods",            "Check Arc Pods",            id="check-arc-pods")
        yield CheckRow("rbac-bindings",       "Check RBAC Bindings",       id="check-rbac-bindings")
        yield CheckRow("operator-permissions","Check Operator Permissions", id="check-operator-permissions")
        yield CheckRow("device-registry-crds","Check Device Registry CRDs",id="check-device-registry-crds")

        yield Button("Run All Checks", id="btn-run-all", variant="primary", classes="run-all-btn")
        yield Static("", id="readiness-banner", classes="readiness-banner")

    # ── Config wiring ─────────────────────────────────────────────────────────

    def set_check_config(
        self,
        cluster_name: str,
        resource_group: str,
        kubeconfig_path: str,
    ) -> None:
        """Called by MainScreen after aio_config.json loads.
        Wires each CheckRow to its async check function."""
        import workers.check_worker as cw

        self.query_one("#check-arc-connected",     CheckRow).set_check_fn(
            lambda: cw.check_arc_connected(cluster_name, resource_group)
        )
        self.query_one("#check-custom-locations",  CheckRow).set_check_fn(
            lambda: cw.check_custom_locations(cluster_name, resource_group)
        )
        self.query_one("#check-workload-identity", CheckRow).set_check_fn(
            lambda: cw.check_workload_identity(cluster_name, resource_group)
        )
        self.query_one("#check-arc-pods",          CheckRow).set_check_fn(
            lambda: cw.check_arc_pods(kubeconfig_path)
        )
        self.query_one("#check-rbac-bindings",     CheckRow).set_check_fn(
            lambda: cw.check_rbac_bindings(kubeconfig_path)
        )
        self.query_one("#check-operator-permissions", CheckRow).set_check_fn(
            lambda: cw.check_operator_permissions(kubeconfig_path)
        )
        self.query_one("#check-device-registry-crds", CheckRow).set_check_fn(
            lambda: cw.check_device_registry_crds(kubeconfig_path)
        )

        banner = self.query_one("#readiness-banner", Static)
        banner.update("Config loaded — click a check or Run All Checks.")
        banner.set_classes("readiness-banner readiness-banner--hint")

    # ── Run All ───────────────────────────────────────────────────────────────

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-run-all":
            event.stop()
            self._run_all()

    @work(exclusive=True)
    async def _run_all(self) -> None:
        """Trigger every check in sequence."""
        banner = self.query_one("#readiness-banner", Static)
        banner.update("Running all checks…")
        banner.set_classes("readiness-banner readiness-banner--hint")

        for check_id in self._ALL_CHECKS:
            row = self.query_one(f"#check-{check_id}", CheckRow)
            row.reset()
            row._set_running()
            if row._check_fn is not None:
                result = await row._check_fn()
                row._set_result(result)
                row.post_message(CheckRow.ResultReady(row.check_id, result.passed))
            await asyncio.sleep(0.05)  # let the UI repaint between checks

        self._update_banner()

    # ── Banner logic ──────────────────────────────────────────────────────────

    def on_check_row_started(self, event: CheckRow.Started) -> None:
        """When any check starts, clear the message area of every OTHER row."""
        for row in self.query(CheckRow):
            if row.check_id != event.check_id:
                row.clear_message()

    def on_check_row_result_ready(self, event: CheckRow.ResultReady) -> None:
        """Re-evaluate the banner whenever any individual check finishes."""
        self._update_banner()

    def _update_banner(self) -> None:
        rows = list(self.query(CheckRow))
        states = [r._state for r in rows]
        if any(s in ("idle", "running") for s in states):
            return  # not all done yet
        failed = sum(1 for s in states if s == "fail")
        banner = self.query_one("#readiness-banner", Static)
        if failed == 0:
            banner.update("✓  All checks passed — Ready for Azure Setup (Phase 4)")
            banner.set_classes("readiness-banner readiness-banner--ready")
        else:
            noun = "issue" if failed == 1 else "issues"
            banner.update(f"✗  {failed} {noun} detected — review failed checks above")
            banner.set_classes("readiness-banner readiness-banner--issues")

    # ── Backward compat ───────────────────────────────────────────────────────

    def refresh_state(self, state) -> None:
        """No-op: config is wired via set_check_config()."""
        pass
