"""
Main screen — composes the three panels and the log pane into a single layout.
"""

from __future__ import annotations
import logging
import pathlib
import re
from typing import Optional

from textual import work
from textual.app import ComposeResult
from textual.screen import Screen
from textual.widgets import Header, Footer, Button, TextArea
from textual.containers import Horizontal, Vertical

from panels.edge_panel import EdgePanel, CheckRow, EdgeStepRow
from panels.azure_panel import AzurePanel
from panels.config_panel import ConfigPanel
from models.state import AppState, StepState
from models.config_loader import load_config, DEFAULT_CONFIG_PATH
from screens.create_config_modal import CreateConfigModal, write_config
from screens.oid_input_modal import OIDInputModal
from workers.ps_worker import run_powershell
from workers.check_worker import UILogHandler, register_ui_handler
from workers.azure_build_worker import build_azure_resources

# ── Strip Rich markup so the TextArea receives clean, selectable plain text ───────────
# Removes [green], [/blue], [dim], [bold], [#abc123] — but NOT [EDGE], [OK], [ERROR]
# (uppercase / mixed-case labels are preserved as literal bracket text).
_MARKUP_RE = re.compile(r'\[/?(?:[a-z][a-z0-9_ ]*(?:\s+on\s+[a-z]+)?|#[0-9a-fA-F]{3,6})\]')


def _strip(text: str) -> str:
    return _MARKUP_RE.sub('', text)

# ── Phase 4 constants ─────────────────────────────────────────────────────────

_REPO_ROOT  = pathlib.Path(__file__).parent.parent.parent
_SCRIPT_DIR = _REPO_ROOT / "external_configuration"

# Regex patterns: (pattern string, step_id)
# Matched against each line streamed from External-Configurator.ps1.
_INFRA_SUCCESS_PATTERNS: list[tuple[str, str]] = [
    (r"ARM deployment completed: keyVault",                          "kv"),
    (r"SUCCESS: Key Vault verified",                                 "kv"),
    (r"ARM deployment completed: storageAccount",                    "storage"),
    (r"SUCCESS: Storage account verified",                           "storage"),
    (r"ARM deployment completed: schemaRegistry",                    "schema"),
    (r"SUCCESS: Azure IoT Operations deployed",                      "iot"),
    (r"SUCCESS: Azure IoT Operations instance .* already exists",    "iot"),
    (r"SUCCESS: IoT Operations verified",                            "iot"),
]


class MainScreen(Screen):
    """Single-screen layout: three panels above a selectable log pane."""

    CSS_PATH = "../styles/app.tcss"

    def __init__(self, state: AppState) -> None:
        super().__init__()
        self.state = state
        self._ui_log_handler: Optional[UILogHandler] = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal(id="panels"):
            yield ConfigPanel(id="panel-config")
            yield EdgePanel(id="panel-edge")
            yield AzurePanel(id="panel-azure")

        with Vertical(id="log-area"):
            yield TextArea("", id="log", read_only=True)
        yield Footer()

    async def on_mount(self) -> None:
        self.query_one("#panel-azure", AzurePanel).refresh_state(self.state.azure)
        # Route check_worker log records (CHECK/RUN/PASS/FAIL) into the UI log pane
        self._ui_log_handler = register_ui_handler(self.log_edge)
        self.log_all("AIO Manager started.")
        self._load_config()

    def on_unmount(self) -> None:
        """Remove the UI log handler to avoid dangling references."""
        from workers.check_worker import _check_log
        if self._ui_log_handler:
            _check_log.removeHandler(self._ui_log_handler)

    @work
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
                    f"[CONFIG] Created {DEFAULT_CONFIG_PATH.name} ({choice} template)"
                )
            except Exception as exc:
                self.log_all(f"[CONFIG] Failed to create config: {exc}")
                return

        config = load_config()
        self.state.config.loaded = config
        self.query_one("#panel-config", ConfigPanel).refresh_config(config)
        if config.is_valid:
            self.log_all(f"[CONFIG] Loaded {config.path.name} — OK")
        else:
            for err in config.errors:
                self.log_all(f"[CONFIG] {err}")

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
            self.log_edge("cluster_name / resource_group missing — edge checks cannot run")

    async def on_config_panel_reload_requested(self, _: ConfigPanel.ReloadRequested) -> None:
        """Re-read aio_config.json from disk and refresh both config and edge panels."""
        self.log_all("[CONFIG] Reloading...")
        self._load_config()

    def on_edge_step_row_result_ready(self, event: EdgeStepRow.ResultReady) -> None:
        """Log every edge check result; include remediation text on failure."""
        icon = "✓" if event.passed else "✗"
        detail = f" — {event.detail}" if event.passed and event.detail else ""
        self.log_edge(f"{icon} {event.check_id}{detail}")
        if not event.passed and event.remediation:
            self.log_edge(f"  FIX: {event.remediation}")

    # ── Logging helpers ────────────────────────────────────────────────────

    def _write_log(self, line: str) -> None:
        """Append one plain-text line to the TextArea.

        insert(text, location=document.end) appends without moving the cursor,
        so any text selection the user has made is never disturbed and Ctrl+C
        copy works correctly during streaming output.

        We only scroll to the bottom when there is no active selection —
        i.e. the user is passively watching, not trying to copy something.
        """
        try:
            ta = self.query_one("#log", TextArea)
            has_selection = ta.selection.start != ta.selection.end

            ta.read_only = False
            try:
                ta.insert(line + "\n", location=ta.document.end)
            finally:
                ta.read_only = True  # ALWAYS restore, even on exception

            if not has_selection:
                ta.scroll_end(animate=False)
        except Exception:
            pass  # Never propagate — a log write must not kill the app

    def log_all(self, message: str) -> None:
        self._write_log(_strip(message))

    def log_edge(self, message: str) -> None:
        self._write_log(f"[EDGE] {_strip(message)}")

    def log_azure(self, message: str) -> None:
        self._write_log(f"[AZURE] {_strip(message)}")

    # ── Azure panel button handlers ────────────────────────────────────────

    def on_button_pressed(self, event: Button.Pressed) -> None:
        """Dispatch Azure action buttons that bubble up from AzurePanel."""
        if event.button.id == "btn-check-azure":
            event.stop()
            self._run_check_azure()
        elif event.button.id == "btn-grant-roles":
            event.stop()
            self._run_grant_entra_id()
        elif event.button.id == "btn-ext-config":
            event.stop()
            self._run_build_azure()

    @work
    async def _run_check_azure(self) -> None:
        """Run az CLI checks for each deployed resource and update step states."""
        import asyncio
        import json as _json
        import shutil

        panel = self.query_one("#panel-azure", AzurePanel)
        panel.set_buttons_enabled(False)
        self.log_azure("Checking Azure resources...")

        # ── Resolve az executable path once ──────────────────────────────────
        az_exe = (
            shutil.which("az")
            or shutil.which("az.cmd")
            or shutil.which("az.exe")
        )
        if az_exe is None:
            self.log_azure("[ERROR] 'az' not found on PATH — install Azure CLI and re-run.")
            panel.set_buttons_enabled(True)
            return

        # ── Resolve resource names ────────────────────────────────────────────
        summary_path = _REPO_ROOT / "config" / "deployment_summary.json"
        summary: dict = {}
        if summary_path.exists():
            try:
                summary = _json.loads(summary_path.read_text(encoding="utf-8"))
            except Exception:
                pass

        config_data: dict = {}
        if self.state.config.loaded is not None:
            config_data = getattr(self.state.config.loaded, "data", {})
        azure_cfg = config_data.get("azure", {})

        resource_group = (
            summary.get("resource_group")
            or azure_cfg.get("resource_group", "")
        )
        key_vault      = summary.get("key_vault") or azure_cfg.get("key_vault_name", "")
        storage        = summary.get("storage_account", "")
        schema         = summary.get("schema_registry", "")
        iot_instance   = summary.get("iot_operations_instance", "")

        if not resource_group:
            self.log_azure("[ERROR] resource_group not found in config — cannot check.")
            panel.set_buttons_enabled(True)
            return

        # ── Helper: run one az command ────────────────────────────────────────
        async def az_check(step_id: str, label: str, cmd: list[str]) -> None:
            # Replace the "az" placeholder with the resolved executable
            resolved_cmd = [az_exe if c == "az" else c for c in cmd]

            # Skip if a required resource name arg is empty
            if not any(c for c in resolved_cmd if c):
                self.log_azure(f"  ○ {label} — skipped (name not in config/summary)")
                return

            cmd_str = " ".join(resolved_cmd)
            self.log_azure(f"  > {cmd_str}")
            panel.set_step_state(step_id, StepState.RUNNING)
            try:
                proc = await asyncio.create_subprocess_exec(
                    *resolved_cmd,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                _, stderr_bytes = await proc.communicate()
                rc = proc.returncode if proc.returncode is not None else -1
            except Exception as exc:
                self.log_azure(f"  ✗ {label} — failed to launch: {exc}")
                panel.set_step_state(step_id, StepState.FAILED)
                self._set_azure_step(step_id, StepState.FAILED)
                return

            if rc == 0:
                self.log_azure(f"  ✓ {label} — exists")
                self._set_azure_step(step_id, StepState.SUCCESS)
            else:
                err = stderr_bytes.decode("utf-8", errors="replace").strip().splitlines()
                detail = err[0] if err else f"exit code {rc}"
                self.log_azure(f"  ✗ {label} — not found ({detail})")
                self._set_azure_step(step_id, StepState.FAILED)

        # ── Run checks sequentially ───────────────────────────────────────────
        await az_check("kv", "Key Vault",
            ["az", "keyvault", "show", "--name", key_vault, "-g", resource_group, "--output", "none"])

        await az_check("storage", "Storage Account",
            ["az", "storage", "account", "show", "--name", storage, "-g", resource_group, "--output", "none"])

        await az_check("schema", "Schema Registry",
            ["az", "iot", "ops", "schema", "registry", "show", "--name", schema, "-g", resource_group, "--output", "none"])

        await az_check("iot", "IoT Operations",
            ["az", "iot", "ops", "show", "--name", iot_instance, "-g", resource_group, "--output", "none"])

        self.log_azure("Azure resource check complete.")
        panel.set_buttons_enabled(True)

    @work
    async def _run_grant_entra_id(self) -> None:
        """Show OID popup then stream grant_entra_id_roles.ps1 to the Azure log."""
        oid = await self.app.push_screen_wait(OIDInputModal())
        if not oid:
            self.log_azure("Grant Entra ID Permissions cancelled.")
            return

        panel = self.query_one("#panel-azure", AzurePanel)
        panel.set_buttons_enabled(False)
        panel.set_roles_running()
        self.log_azure(f"Starting Grant Entra ID Permissions (OID: {oid})...")

        script = _SCRIPT_DIR / "grant_entra_id_roles.ps1"

        def on_line(line: str) -> None:
            self.log_azure(line)
            self._apply_azure_line(line, panel, for_roles=True)

        exit_code = await run_powershell(str(script), ["-AddUser", oid], on_line)

        if exit_code == 0:
            self.log_azure("Grant Entra ID Permissions completed successfully.")
            self._set_azure_step("roles", StepState.SUCCESS)
        else:
            self.log_azure(f"Grant Entra ID Permissions FAILED (exit code {exit_code}).")
            for step_id in panel.get_running_steps():
                self._set_azure_step(step_id, StepState.FAILED)

        panel.set_buttons_enabled(True)

    @work
    async def _run_build_azure(self) -> None:
        """Idempotently build Azure resources using ARM templates where available.

        For each resource step:
          1. Skip if it is already marked SUCCESS from the last Check run.
          2. Check whether the resource exists in Azure via az show → skip if found.
          3. Deploy via ARM template (KV / Storage / Schema Registry) or az CLI (IoT Ops).
          4. Continue to the next step even if one fails.
          5. Emit a summary at the end recommending the user review logs.
        """
        import json as _json

        panel = self.query_one("#panel-azure", AzurePanel)
        panel.set_buttons_enabled(False)
        self.log_azure("Starting Build Azure Resources (idempotent)...")

        # Gather config and summary
        config_data: dict = {}
        if self.state.config.loaded is not None:
            config_data = getattr(self.state.config.loaded, "data", {})

        summary: dict = {}
        summary_path = _REPO_ROOT / "config" / "deployment_summary.json"
        if summary_path.exists():
            try:
                summary = _json.loads(summary_path.read_text(encoding="utf-8"))
            except Exception:
                pass

        arm_dir = _REPO_ROOT / "arm_templates"
        current_states = panel.get_step_states()

        def on_line(line: str) -> None:
            self.log_azure(line)

        def on_step_state(step_id: str, state: StepState) -> None:
            self._set_azure_step(step_id, state)

        await build_azure_resources(
            config_data    = config_data,
            summary        = summary,
            current_states = current_states,
            arm_dir        = arm_dir,
            on_line        = on_line,
            on_step_state  = on_step_state,
        )

        panel.set_buttons_enabled(True)

    # ── Azure step helpers ────────────────────────────────────────────────────

    def _apply_azure_line(self, line: str, panel: AzurePanel, for_roles: bool) -> None:
        """Parse one streamed script line and update step states via regex."""
        # Error lines — mark every currently RUNNING step as FAILED
        if re.search(r"\] ERROR:|^\[ERROR\]", line):
            for step_id in panel.get_running_steps():
                self._set_azure_step(step_id, StepState.FAILED)
            return

        if for_roles:
            # grant_entra_id_roles.ps1 final line: "Completed: <date>"
            if re.search(r"^Completed: ", line):
                self._set_azure_step("roles", StepState.SUCCESS)
            return

        # External-Configurator.ps1 per-resource success patterns
        for pattern, step_id in _INFRA_SUCCESS_PATTERNS:
            if re.search(pattern, line):
                self._set_azure_step(step_id, StepState.SUCCESS)

    _AZURE_STEP_ATTR: dict[str, str] = {
        "kv":      "key_vault",
        "storage": "storage_account",
        "schema":  "schema_registry",
        "iot":     "iot_operations",
        "roles":   "role_assignments",
    }

    def _set_azure_step(self, step_id: str, state: StepState) -> None:
        """Update both AzureState model and the panel widget for one step."""
        attr = self._AZURE_STEP_ATTR.get(step_id)
        if attr:
            setattr(self.state.azure, attr, state)
        try:
            self.query_one("#panel-azure", AzurePanel).set_step_state(step_id, state)
        except Exception:
            pass
