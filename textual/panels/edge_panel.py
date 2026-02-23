"""
Edge Panel — Phase 3 verification.

Single "Check Edge Deployment" button triggers all seven checks sequentially.
Each check is displayed as a StepRow (○/⟳/✓/✗) mirroring the Azure panel.
Remediation text for failed checks is posted to the log pane via ResultReady.

Config values (cluster_name, resource_group, kubeconfig_path) are injected
by MainScreen via set_check_config() after aio_config.json is loaded.
"""

from __future__ import annotations

import asyncio
from typing import Awaitable, Callable, Optional
from textual import work
from textual.app import ComposeResult
from textual.message import Message
from textual.widget import Widget
from textual.widgets import Button, Label, Static

from workers.check_worker import CheckResult


# ── EdgeStepRow ───────────────────────────────────────────────────────────────

class EdgeStepRow(Widget):
    """One check displayed as: [icon]  Label text      (mirrors Azure StepRow)."""

    _ICONS = {"idle": "○", "running": "⟳", "pass": "✓", "fail": "✗"}
    _CSS   = {
        "idle":    "edge-step-icon--idle",
        "running": "edge-step-icon--running",
        "pass":    "edge-step-icon--pass",
        "fail":    "edge-step-icon--fail",
    }

    DEFAULT_CSS = """
    EdgeStepRow {
        height: 1;
        margin-bottom: 0;
        layout: horizontal;
    }
    """

    class ResultReady(Message):
        """Posted when a check finishes."""
        def __init__(self, check_id: str, passed: bool, detail: str, remediation: str) -> None:
            super().__init__()
            self.check_id    = check_id
            self.passed      = passed
            self.detail      = detail
            self.remediation = remediation

    def __init__(self, check_id: str, label: str) -> None:
        super().__init__(id=f"step-{check_id}")
        self.check_id   = check_id
        self._label     = label
        self._check_fn: Optional[Callable[[], Awaitable[CheckResult]]] = None
        self._state     = "idle"

    def compose(self) -> ComposeResult:
        yield Label(
            self._ICONS["idle"],
            id=f"icon-{self.check_id}",
            classes="edge-step-icon edge-step-icon--idle",
        )
        yield Static(self._label, id=f"lbl-{self.check_id}", classes="edge-step-label")

    def set_check_fn(self, fn: Callable[[], Awaitable[CheckResult]]) -> None:
        self._check_fn = fn

    # ── State transitions ─────────────────────────────────────────────────────

    def set_running(self) -> None:
        self._state = "running"
        self._icon().update(self._ICONS["running"])
        self._icon().set_classes(f"edge-step-icon {self._CSS['running']}")

    def set_result(self, result: CheckResult) -> None:
        state = "pass" if result.passed else "fail"
        self._state = state
        self._icon().update(self._ICONS[state])
        self._icon().set_classes(f"edge-step-icon {self._CSS[state]}")
        self.post_message(
            self.ResultReady(self.check_id, result.passed, result.detail, result.remediation)
        )

    def reset(self) -> None:
        self._state = "idle"
        self._icon().update(self._ICONS["idle"])
        self._icon().set_classes(f"edge-step-icon {self._CSS['idle']}")

    def _icon(self) -> Label:
        return self.query_one(f"#icon-{self.check_id}", Label)


# ── CheckRow shim ─────────────────────────────────────────────────────────────
# main_screen.py imports CheckRow; keep it resolvable.

class CheckRow:
    """Backward-compat namespace so `from panels.edge_panel import CheckRow` still works."""
    ResultReady = EdgeStepRow.ResultReady


# ── EdgePanel ─────────────────────────────────────────────────────────────────

class EdgePanel(Widget):
    """Left panel: edge device Arc/RBAC verification — single-button, step-row display."""

    _CHECKS: list[tuple[str, str]] = [
        ("arc-connected",        "Arc Connected"),
        ("custom-locations",     "Custom Locations"),
        ("workload-identity",    "Workload Identity"),
        ("arc-pods",             "Arc Pods"),
        ("rbac-bindings",        "RBAC Bindings"),
        ("operator-permissions", "Operator Permissions"),
        ("device-registry-crds", "Device Registry CRDs"),
    ]

    def compose(self) -> ComposeResult:
        yield Label("EDGE VERIFICATION", classes="panel-title")
        for check_id, label in self._CHECKS:
            yield EdgeStepRow(check_id, label)
        yield Button(
            "Check Edge Deployment",
            id="btn-check-edge",
            variant="primary",
            classes="run-all-btn",
        )
        yield Static("", id="readiness-banner", classes="readiness-banner")

    # ── Config wiring ─────────────────────────────────────────────────────────

    def set_check_config(
        self,
        cluster_name: str,
        resource_group: str,
        kubeconfig_path: str,
    ) -> None:
        """Wire each step to its check function. Called by MainScreen after config loads."""
        import workers.check_worker as cw

        # Store for use by _run_all (arc checks share a single az call)
        self._cluster_name    = cluster_name
        self._resource_group  = resource_group
        self._kubeconfig_path = kubeconfig_path

        # kubectl checks still use individual _check_fn (each runs a different command)
        self.query_one("#step-arc-pods",             EdgeStepRow).set_check_fn(
            lambda: cw.check_arc_pods(kubeconfig_path))
        self.query_one("#step-rbac-bindings",        EdgeStepRow).set_check_fn(
            lambda: cw.check_rbac_bindings(kubeconfig_path))
        self.query_one("#step-operator-permissions", EdgeStepRow).set_check_fn(
            lambda: cw.check_operator_permissions(kubeconfig_path))
        self.query_one("#step-device-registry-crds", EdgeStepRow).set_check_fn(
            lambda: cw.check_device_registry_crds(kubeconfig_path))

        banner = self.query_one("#readiness-banner", Static)
        banner.update("Config loaded — click Check Edge Deployment to verify.")
        banner.set_classes("readiness-banner readiness-banner--hint")

    # ── Button press ──────────────────────────────────────────────────────────

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-check-edge":
            event.stop()
            self._run_all()

    @work(exclusive=True)
    async def _run_all(self) -> None:
        """Run every check — arc checks share one az call, kubectl checks run individually."""
        import workers.check_worker as cw

        banner = self.query_one("#readiness-banner", Static)
        banner.update("Running checks…")
        banner.set_classes("readiness-banner readiness-banner--hint")

        btn = self.query_one("#btn-check-edge", Button)
        btn.disabled = True

        # ── Arc checks: single az connectedk8s show call ─────────────────────────
        arc_ids = ["arc-connected", "custom-locations", "workload-identity"]
        for check_id in arc_ids:
            self.query_one(f"#step-{check_id}", EdgeStepRow).reset()
            self.query_one(f"#step-{check_id}", EdgeStepRow).set_running()

        cluster_name   = getattr(self, "_cluster_name",    "")
        resource_group = getattr(self, "_resource_group",  "")
        arc_results = await cw.check_arc_all(cluster_name, resource_group)

        for check_id, result in arc_results:
            self.query_one(f"#step-{check_id}", EdgeStepRow).set_result(result)
            await asyncio.sleep(0.05)

        # ── kubectl checks: each runs its own command ───────────────────────────
        kubectl_ids = ["arc-pods", "rbac-bindings", "operator-permissions", "device-registry-crds"]
        for check_id in kubectl_ids:
            step = self.query_one(f"#step-{check_id}", EdgeStepRow)
            step.reset()
            step.set_running()
            if step._check_fn is not None:
                result = await step._check_fn()
                step.set_result(result)
            await asyncio.sleep(0.05)

        btn.disabled = False
        self._update_banner()

    # ── Banner ────────────────────────────────────────────────────────────────

    def on_edge_step_row_result_ready(self, _: EdgeStepRow.ResultReady) -> None:
        self._update_banner()

    def _update_banner(self) -> None:
        steps  = list(self.query(EdgeStepRow))
        states = [s._state for s in steps]
        if any(st in ("idle", "running") for st in states):
            return
        failed = sum(1 for st in states if st == "fail")
        banner = self.query_one("#readiness-banner", Static)
        if failed == 0:
            banner.update("✓  All checks passed — Ready for Azure Setup")
            banner.set_classes("readiness-banner readiness-banner--ready")
        else:
            noun = "issue" if failed == 1 else "issues"
            banner.update(f"✗  {failed} {noun} detected — see log for details")
            banner.set_classes("readiness-banner readiness-banner--issues")

    # ── Backward compat ───────────────────────────────────────────────────────

    def refresh_state(self, state) -> None:
        pass