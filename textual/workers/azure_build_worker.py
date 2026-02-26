"""
Idempotent Azure resource builder — azure_build_worker.py

Deploys Key Vault, Storage Account, and Schema Registry via ARM templates,
and IoT Operations via Azure CLI.  For each step:

  1. Skip entirely if the step is already SUCCESS (from a previous Check run).
  2. Run az show to see if the resource already exists → mark SUCCESS and skip.
  3. Deploy via ARM template (or az CLI for IoT Ops) if not yet present.
  4. Continue to the next step even if one fails.
  5. Emit a summary at the end recommending the user check the logs.

ARM template deployments use ``az deployment group create`` with
``--mode Incremental`` which is idempotent — safe to run multiple times.
"""

from __future__ import annotations

import asyncio
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
from typing import Callable

from models.state import StepState

# ── Type aliases ──────────────────────────────────────────────────────────────
OnLine = Callable[[str], None]
OnState = Callable[[str, StepState], None]


# ── Public entry point ────────────────────────────────────────────────────────

async def build_azure_resources(
    config_data: dict,
    summary: dict,
    current_states: dict[str, StepState],
    arm_dir: pathlib.Path,
    on_line: OnLine,
    on_step_state: OnState,
) -> None:
    """
    Build all Azure resources, skipping those already known to exist.

    Parameters
    ----------
    config_data     : parsed aio_config.json content
    summary         : parsed deployment_summary.json content (may be empty)
    current_states  : mapping of step_id -> StepState from the last Check run
    arm_dir         : absolute path to the arm_templates/ directory
    on_line         : log callback (one message per call, no trailing newline)
    on_step_state   : step-state callback (step_id, new StepState)
    """
    ctx = _BuildContext(config_data, summary, current_states, arm_dir, on_line, on_step_state)
    await ctx.run()


# ── Internal build context ────────────────────────────────────────────────────

class _BuildContext:
    def __init__(
        self,
        config_data: dict,
        summary: dict,
        current_states: dict[str, StepState],
        arm_dir: pathlib.Path,
        on_line: OnLine,
        on_step_state: OnState,
    ) -> None:
        self._cfg    = config_data
        self._sum    = summary
        self._states = current_states
        self._arm    = arm_dir
        self._log    = on_line
        self._state  = on_step_state

        self._az: str | None = (
            shutil.which("az")
            or shutil.which("az.cmd")
            or shutil.which("az.exe")
        )

        azure_cfg = config_data.get("azure", {})
        cluster   = config_data.get("cluster",  {})

        # Only use deployment_summary values if the summary was written for the
        # same cluster as the current config.  If the cluster names differ the
        # summary is stale (left over from a previous deployment) and must be
        # ignored so we don't check/build the wrong resources.
        cfg_cluster = azure_cfg.get("cluster_name", "")
        sum_cluster = summary.get("cluster_name", "")
        _summary_matches = (sum_cluster == cfg_cluster) if sum_cluster else False

        self._rg       = (_summary_matches and summary.get("resource_group"))  or azure_cfg.get("resource_group", "")
        self._location = (_summary_matches and summary.get("location"))        or azure_cfg.get("location", "")
        self._sub_id   = azure_cfg.get("subscription_id", "")

        # Cluster name — prefer summary only when it matches config
        self._cluster  = (_summary_matches and sum_cluster) or cfg_cluster

        # Derive resource names following the same rules as External-Configurator.ps1
        cluster_clean = re.sub(r"[^a-z0-9]", "", self._cluster.lower())
        rg_clean      = re.sub(r"[^a-z0-9]", "", self._rg.lower())

        self._kv_name = (
            (_summary_matches and summary.get("key_vault"))
            or azure_cfg.get("key_vault_name", "")
            or ("kv" + rg_clean)[:24]
        )
        self._storage_name = (
            (_summary_matches and summary.get("storage_account"))
            or azure_cfg.get("storage_account_name", "")
            or (cluster_clean + "storage")[:24]
        )
        self._schema_name = (
            (_summary_matches and summary.get("schema_registry"))
            or f"{self._cluster}-schema-registry"
        )
        self._iot_instance = (
            (_summary_matches and summary.get("iot_operations_instance"))
            or f"{self._cluster}-aio"
        )

        self._failed: list[str] = []
        self._skipped: list[str] = []
        self._built: list[str] = []

    # ── Main sequence ──────────────────────────────────────────────────────────

    async def run(self) -> None:
        if not self._az:
            self._log("[ERROR] 'az' not found on PATH — install Azure CLI and retry.")
            return

        if not self._rg:
            self._log("[ERROR] resource_group not found in config — cannot build.")
            return

        self._log(f"Building Azure resources in: {self._rg} ({self._location})")
        self._log(f"  Key Vault     : {self._kv_name}")
        self._log(f"  Storage       : {self._storage_name}")
        self._log(f"  Schema Reg.   : {self._schema_name}")
        self._log(f"  IoT Ops       : {self._iot_instance}")
        self._log("")

        # ── 0. Ensure resource group exists ──────────────────────────────────
        await self._ensure_resource_group()

        # ── 1. Key Vault ──────────────────────────────────────────────────────
        await self._build_step(
            step_id  = "kv",
            label    = "Key Vault",
            check_cmd = ["az", "keyvault", "show",
                          "--name", self._kv_name,
                          "-g", self._rg,
                          "--output", "none"],
            deploy   = self._deploy_key_vault,
        )

        # ── 2. Storage Account ───────────────────────────────────────────────
        await self._build_step(
            step_id  = "storage",
            label    = "Storage Account",
            check_cmd = ["az", "storage", "account", "show",
                          "--name", self._storage_name,
                          "-g", self._rg,
                          "--output", "none"],
            deploy   = self._deploy_storage,
        )

        # ── 3. Schema Registry ───────────────────────────────────────────────
        await self._build_step(
            step_id  = "schema",
            label    = "Schema Registry",
            check_cmd = ["az", "iot", "ops", "schema", "registry", "show",
                          "--name", self._schema_name,
                          "-g", self._rg,
                          "--output", "none"],
            deploy   = self._deploy_schema_registry,
        )

        # ── 4. IoT Operations ────────────────────────────────────────────────
        await self._build_step(
            step_id  = "iot",
            label    = "IoT Operations",
            check_cmd = ["az", "iot", "ops", "show",
                          "--name", self._iot_instance,
                          "-g", self._rg,
                          "--output", "none"],
            deploy   = self._deploy_iot_operations,
        )

        # ── Summary ───────────────────────────────────────────────────────────
        self._log("")
        self._log("=" * 60)
        self._log("BUILD COMPLETE — Summary")
        self._log("=" * 60)
        if self._built:
            self._log(f"  Deployed  : {', '.join(self._built)}")
        if self._skipped:
            self._log(f"  Skipped   : {', '.join(self._skipped)} (already exist)")
        if self._failed:
            self._log(f"  Failed    : {', '.join(self._failed)}")
            self._log("")
            self._log("One or more steps failed.  Review the log output above")
            self._log("to identify the cause, then click 'Build Azure Resources'")
            self._log("again once the issue is resolved.")
            self._log("")
            self._log("Common causes:")
            self._log("  - Insufficient RBAC permissions -> run 'Grant Entra ID Permissions'")
            self._log("  - Arc cluster not connected     -> verify Edge panel checks pass")
            self._log("  - Name conflicts / soft-delete  -> check Azure portal")
        else:
            self._log("")
            self._log("All resources are ready.  Run 'Check Azure Resources' to verify.")
        self._log("=" * 60)

    # ── Per-step logic ─────────────────────────────────────────────────────────

    async def _build_step(
        self,
        step_id: str,
        label: str,
        check_cmd: list[str],
        deploy: Callable[[], asyncio.coroutines],  # type: ignore[type-arg]
    ) -> None:
        """Skip / check-exists / deploy for one step."""

        # 1. Already SUCCESS from prior Check run → skip
        if self._states.get(step_id) == StepState.SUCCESS:
            self._log(f"  ✓ {label} — already verified (skipping)")
            self._state(step_id, StepState.SUCCESS)
            self._skipped.append(label)
            return

        self._state(step_id, StepState.RUNNING)

        # 2. Check whether the resource already exists in Azure
        exists = await self._az_exists(check_cmd)
        if exists:
            self._log(f"  ✓ {label} — already exists in Azure (skipping deployment)")
            self._state(step_id, StepState.SUCCESS)
            self._skipped.append(label)
            return

        # 3. Deploy
        self._log(f"  ⟳ {label} — deploying...")
        try:
            ok = await deploy()
        except Exception as exc:
            self._log(f"  ✗ {label} — unexpected error: {exc}")
            ok = False

        if ok:
            self._log(f"  ✓ {label} — deployed successfully")
            self._state(step_id, StepState.SUCCESS)
            self._built.append(label)
        else:
            self._log(f"  ✗ {label} — FAILED (see log above for details)")
            self._state(step_id, StepState.FAILED)
            self._failed.append(label)

    # ── Resource group helper ──────────────────────────────────────────────────

    async def _ensure_resource_group(self) -> None:
        """Create the resource group if it does not exist."""
        rc = await self._run_az(["az", "group", "exists", "--name", self._rg], capture=True)
        if rc[0] == 0 and rc[1].strip() == "true":
            self._log(f"  ✓ Resource group '{self._rg}' — already exists")
            return

        self._log(f"  ⟳ Creating resource group '{self._rg}' in {self._location}...")
        cmd = [
            "az", "group", "create",
            "--name", self._rg,
            "--location", self._location,
            "--output", "none",
        ]
        rc2 = await self._run_az(cmd)
        if rc2 == 0:
            self._log(f"  ✓ Resource group '{self._rg}' created")
        else:
            self._log(f"  ✗ Failed to create resource group '{self._rg}'")

    # ── Individual deployers ───────────────────────────────────────────────────

    async def _deploy_key_vault(self) -> bool:
        template = self._arm / "keyVault.json"
        params = [
            f"keyVaultName={self._kv_name}",
            f"location={self._location}",
        ]
        return await self._arm_deploy("keyVault", template, params)

    async def _deploy_storage(self) -> bool:
        template = self._arm / "storageAccount.json"
        params = [
            f"storageAccountName={self._storage_name}",
            f"location={self._location}",
        ]
        return await self._arm_deploy("storageAccount", template, params)

    async def _deploy_schema_registry(self) -> bool:
        template = self._arm / "schemaRegistry.json"
        params = [
            f"schemaRegistryName={self._schema_name}",
            f"storageAccountName={self._storage_name}",
            f"location={self._location}",
        ]
        return await self._arm_deploy("schemaRegistry", template, params)

    async def _deploy_iot_operations(self) -> bool:
        """Deploy IoT Operations via Azure CLI (no ARM template available)."""
        if not self._cluster:
            self._log("  [ERROR] cluster_name not set — cannot deploy IoT Operations")
            return False

        # Get schema registry resource ID (needed by az iot ops create)
        sr_id = await self._get_schema_registry_id()

        # Step A: az iot ops init (idempotent — safe to re-run)
        # Runs in a new visible terminal window so progress can be watched live.
        self._log("    Running: az iot ops init  (opening terminal window — this takes ~3 min)")
        init_cmd = [
            "az", "iot", "ops", "init",
            "--cluster", self._cluster,
            "--resource-group", self._rg,
        ]
        if self._sub_id:
            init_cmd += ["--subscription", self._sub_id]

        rc_init = await self._run_az_visible(init_cmd, title="az iot ops init")
        if rc_init != 0:
            self._log(f"    [ERROR] az iot ops init failed (exit {rc_init})")
            return False
        self._log("    az iot ops init completed successfully")

        # Step B: az iot ops create
        self._log("    Running: az iot ops create  (opening terminal window)")
        create_cmd = [
            "az", "iot", "ops", "create",
            "--cluster", self._cluster,
            "--resource-group", self._rg,
            "--name", self._iot_instance,
        ]
        if sr_id:
            create_cmd += ["--sr-resource-id", sr_id]
        if self._sub_id:
            create_cmd += ["--subscription", self._sub_id]

        rc_create = await self._run_az_visible(create_cmd, title="az iot ops create")
        if rc_create != 0:
            self._log(f"    [ERROR] az iot ops create failed (exit {rc_create})")
            return False
        self._log("    az iot ops create completed successfully")

        return True

    async def _run_az_visible(self, cmd: list[str], title: str = "az") -> int:
        """
        Run an az CLI command in a new visible CMD window so the user can watch
        the live output (e.g. rich progress bars from az iot ops init/create).

        - Sets UTF-8 code page (chcp 65001) to avoid encoding crashes.
        - Writes the exit code to a temp file so we can retrieve it.
        - Pauses at the end so the user can read the output before the window closes.
        - Returns the command's numeric exit code (or -1 on error).
        """
        resolved = [self._az if c == "az" else c for c in cmd]

        # Quote any token that contains a space
        def _q(s: str) -> str:
            return f'"{s}"' if " " in s else s

        cmd_line = " ".join(_q(c) for c in resolved)

        # Temp files: batch script + exit-code sidecar
        fd_bat, bat_path = tempfile.mkstemp(suffix=".bat", prefix="aio_")
        exitcode_path = bat_path + ".rc"
        try:
            with os.fdopen(fd_bat, "w") as f:
                f.write("@echo off\n")
                f.write("chcp 65001 >nul\n")
                f.write(f"title {title}\n")
                f.write(f"{cmd_line}\n")
                # Capture ERRORLEVEL immediately before any echo resets it
                f.write("set _RC=%ERRORLEVEL%\n")
                f.write(f"echo %_RC% > \"{exitcode_path}\"\n")
                f.write("echo.\n")
                f.write("echo ================================================\n")
                f.write("if %_RC% NEQ 0 (\n")
                f.write("    echo   FAILED with exit code %_RC%\n")
                f.write("    echo   Scroll up to read the error output above.\n")
                f.write(") else (\n")
                f.write("    echo   Command completed successfully.\n")
                f.write(")\n")
                f.write("echo ================================================\n")
                f.write("echo.\n")
                f.write("pause\n")

            loop = asyncio.get_event_loop()
            proc = await loop.run_in_executor(
                None,
                lambda: subprocess.Popen(
                    ["cmd.exe", "/c", bat_path],
                    creationflags=subprocess.CREATE_NEW_CONSOLE,
                ),
            )
            # Wait for the window to be closed by the user
            await loop.run_in_executor(None, proc.wait)

            # Read exit code written by the batch file
            try:
                with open(exitcode_path, "r") as f:
                    return int(f.read().strip())
            except Exception:
                return proc.returncode if proc.returncode is not None else -1
        except Exception as exc:
            self._log(f"    [ERROR] Failed to open terminal window: {exc}")
            return -1
        finally:
            for p in (bat_path, exitcode_path):
                try:
                    os.unlink(p)
                except OSError:
                    pass

    # ── ARM template helper ────────────────────────────────────────────────────

    async def _arm_deploy(
        self,
        name: str,
        template: pathlib.Path,
        params: list[str],
    ) -> bool:
        """Run ``az deployment group create`` for *template* with *params*."""
        if not template.exists():
            self._log(f"    [ERROR] ARM template not found: {template}")
            return False

        import time
        deployment_name = f"{name}-{int(time.time())}"

        cmd = [
            "az", "deployment", "group", "create",
            "--resource-group", self._rg,
            "--name", deployment_name,
            "--template-file", str(template),
            "--mode", "Incremental",
            "--parameters",
            *params,
            "--output", "none",
        ]
        if self._sub_id:
            cmd += ["--subscription", self._sub_id]

        self._log(f"    az deployment group create --name {deployment_name} ({name})")
        rc = await self._run_az(cmd)
        return rc == 0

    # ── Utility helpers ────────────────────────────────────────────────────────

    async def _az_exists(self, cmd: list[str]) -> bool:
        """Return True if *cmd* exits with code 0 (resource found)."""
        if not cmd:
            return False
        resolved = [self._az if c == "az" else c for c in cmd]
        # filter accidental empties
        if any(not c for c in resolved):
            return False
        try:
            proc = await asyncio.create_subprocess_exec(
                *resolved,
                stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
            await proc.wait()
            return (proc.returncode or 0) == 0
        except Exception:
            return False

    async def _run_az(
        self,
        cmd: list[str],
        capture: bool = False,
    ) -> int | tuple[int, str]:
        """
        Run an az command, streaming output to the log callback.

        If *capture* is True, returns ``(exit_code, stdout_text)`` instead of
        just the exit code (stderr is still streamed to the log).
        """
        resolved = [self._az if c == "az" else c for c in cmd]
        try:
            proc = await asyncio.create_subprocess_exec(
                *resolved,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            assert proc.stdout is not None
            assert proc.stderr is not None

            stdout_lines: list[str] = []

            async def _drain_stream(stream: asyncio.StreamReader, prefix: str) -> list[str]:
                lines: list[str] = []
                async for raw in stream:
                    line = raw.decode("utf-8", errors="replace").rstrip()
                    lines.append(line)
                    if line:
                        self._log(f"    {prefix}{line}")
                return lines

            stdout_lines, _ = await asyncio.gather(
                _drain_stream(proc.stdout, ""),
                _drain_stream(proc.stderr, "[stderr] "),
            )
            await proc.wait()
            rc = proc.returncode if proc.returncode is not None else -1

            if capture:
                return rc, "\n".join(stdout_lines)
            return rc
        except Exception as exc:
            self._log(f"    [ERROR] Failed to run az command: {exc}")
            if capture:
                return -1, ""
            return -1

    async def _get_schema_registry_id(self) -> str:
        """Return the ARM resource ID for the schema registry, or empty string."""
        if not self._schema_name:
            return ""
        rc, stdout = await self._run_az(
            [
                "az", "iot", "ops", "schema", "registry", "show",
                "--name", self._schema_name,
                "-g", self._rg,
                "--query", "id",
                "-o", "tsv",
            ],
            capture=True,
        )
        if isinstance(stdout, str):
            return stdout.strip()
        return ""
