"""
Async check workers for Phase 3 edge verification.

Verification 1 — Azure Arc connectivity (az CLI, runs locally)
Verification 2 — Kubernetes RBAC (kubectl, uses kubeconfig_base64 from config)

Each function is a standalone async coroutine that returns a CheckResult.
"""

from __future__ import annotations

import asyncio
import functools
import json
import logging
import os
import pathlib
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable

# On Windows, launch subprocesses in their own process group so that
# Ctrl+C (CTRL_C_EVENT) sent to the terminal does NOT kill child processes.
_SUBPROCESS_FLAGS = subprocess.CREATE_NEW_PROCESS_GROUP if sys.platform == "win32" else 0

# ── File logger ───────────────────────────────────────────────────────────────

def _find_repo_root() -> pathlib.Path:
    if getattr(sys, "frozen", False):
        return pathlib.Path(sys.executable).parent
    return pathlib.Path(__file__).parent.parent.parent

_REPO_ROOT = _find_repo_root()
_LOG_PATH = _REPO_ROOT / "aio_manager_checks.log"

_file_handler = logging.FileHandler(_LOG_PATH, encoding="utf-8")
_file_handler.setFormatter(
    logging.Formatter("%(asctime)s  %(levelname)-5s  %(message)s", datefmt="%Y-%m-%d %H:%M:%S")
)

_check_log = logging.getLogger("aio_manager.checks")
_check_log.setLevel(logging.DEBUG)
_check_log.addHandler(_file_handler)
_check_log.propagate = False  # don't bleed into Textual's root logger


# ── UI log bridge ──────────────────────────────────────────────────────────

class UILogHandler(logging.Handler):
    """Routes check log records to a UI callback (e.g. MainScreen.log_edge)."""
    def __init__(self, callback: Callable[[str], None]) -> None:
        super().__init__()
        self._callback = callback

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self._callback(self.format(record))
        except Exception:
            pass


def register_ui_handler(callback: Callable[[str], None]) -> UILogHandler:
    """Add a UI handler to the check logger; returns it so it can be removed on unmount."""
    handler = UILogHandler(callback)
    handler.setFormatter(
        logging.Formatter("%(asctime)s  %(message)s", datefmt="%H:%M:%S")
    )
    _check_log.addHandler(handler)
    return handler


def log_check(fn):
    """Decorator: logs check name on entry, then full result detail/remediation on exit."""
    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        _check_log.info("CHECK  %s", fn.__name__)
        result: CheckResult = await fn(*args, **kwargs)
        if result.passed:
            _check_log.info("PASS   %s  |  %s", fn.__name__, result.detail)
        else:
            _check_log.warning(
                "FAIL   %s  |  %s",
                fn.__name__,
                result.remediation.replace("\n", " ").strip()[:300],
            )
        return result
    return wrapper


@dataclass
class CheckResult:
    passed: bool
    detail: str       # short summary shown beside the button on pass
    remediation: str  # instruction text shown below the button on fail


# ── Subprocess helpers ───────────────────────────────────────────────────────

async def _run(args: list[str], env: dict | None = None) -> tuple[int, str, str]:
    """Run a subprocess and return (returncode, stdout, stderr).
    Resolves the command via shutil.which so that Windows .cmd wrappers
    (e.g. az.cmd, kubectl.cmd) are found correctly."""
    # Resolve the executable — critical on Windows where az/kubectl are .cmd files
    resolved = shutil.which(args[0])
    if resolved is None:
        return -1, "", f"Command not found: {args[0]}"
    full_args = [resolved] + args[1:]
    try:
        proc = await asyncio.create_subprocess_exec(
            *full_args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
            creationflags=_SUBPROCESS_FLAGS,
        )
        stdout, stderr = await proc.communicate()
        return (
            proc.returncode,
            stdout.decode(errors="replace").strip(),
            stderr.decode(errors="replace").strip(),
        )
    except OSError as e:
        return -1, "", str(e)


async def _logged_run(args: list[str], env: dict | None = None) -> tuple[int, str, str]:
    """Run a subprocess, log the command and outcome to aio_manager_checks.log."""
    cmd_str = " ".join(args)
    _check_log.info("RUN  %s", cmd_str)
    code, out, err = await _run(args, env)
    if code != 0:
        summary = (err or out).splitlines()[0][:120] if (err or out) else "(no output)"
        _check_log.warning("FAIL rc=%d  %s", code, summary)
    return code, out, err


# ── Verification 1 — Azure Arc (az CLI) ──────────────────────────────────────

async def check_arc_all(
    cluster_name: str,
    resource_group: str,
) -> list[tuple[str, "CheckResult"]]:
    """Run az connectedk8s show ONCE and derive all three Arc check results.

    Returns a list of (check_id, CheckResult) in this fixed order:
        arc-connected, custom-locations, workload-identity
    """
    _check_log.info(
        "CHECK  arc-connected + custom-locations + workload-identity (combined az call)"
    )
    code, out, err = await _logged_run([
        "az", "connectedk8s", "show",
        "--name", cluster_name,
        "--resource-group", resource_group,
        "--output", "json",
    ])

    if code != 0:
        msg = (err or "unknown error").strip()
        fix = (
            f"az command failed: {msg}. "
            "Make sure 'az login' has been run and that cluster_name / resource_group "
            "in aio_config.json match what was created by arc_enable.ps1."
        )
        _check_log.warning("FAIL  arc-connected  |  %s", msg[:200])
        return [
            ("arc-connected",        CheckResult(False, "", fix)),
            ("custom-locations",     CheckResult(False, "", "Fix Arc Connected first.")),
            ("workload-identity",    CheckResult(False, "", "Fix Arc Connected first.")),
        ]

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        bad = CheckResult(False, "", "Could not parse az output. Check that Azure CLI is logged in.")
        return [("arc-connected", bad), ("custom-locations", bad), ("workload-identity", bad)]

    # ── Arc Connected ─────────────────────────────────────────────────────────
    status = data.get("connectivityStatus", "unknown")
    if status.lower() == "connected":
        r_connected = CheckResult(True, f"connectivityStatus: {status}", "")
        _check_log.info("PASS   arc-connected  |  connectivityStatus: %s", status)
    else:
        r_connected = CheckResult(
            False, f"connectivityStatus: {status}",
            "Cluster is not Connected to Azure Arc. "
            "Re-run arc_enable.ps1 on the edge device and wait for all pods in the "
            "azure-arc namespace to reach Running state before re-checking.",
        )
        _check_log.warning("FAIL   arc-connected  |  connectivityStatus: %s", status)

    # ── Custom Locations ───────────────────────────────────────────────────
    sdv = data.get("systemDefaultValues") or {}
    cl  = sdv.get("customLocations") or {}
    cl_enabled = cl.get("enabled", False)
    if cl_enabled:
        r_cl = CheckResult(True, "customLocations.enabled: true", "")
        _check_log.info("PASS   custom-locations  |  customLocations.enabled: true")
    else:
        r_cl = CheckResult(
            False, f"customLocations.enabled: {cl_enabled}",
            "Custom Locations not enabled in the cluster. "
            "Known issue: Az.ConnectedKubernetes only registers this with ARM but does "
            "not run the required helm upgrade. On the edge device run: "
            "helm upgrade azure-arc azurearcmcp/azure-arc-k8sagents "
            "-n azure-arc-release --reuse-values "
            "--set systemDefaultValues.customLocations.enabled=true "
            "--set systemDefaultValues.customLocations.oid=<oid> "
            "(See arc_enable.ps1 for the full helm upgrade step.)",
        )
        _check_log.warning("FAIL   custom-locations  |  customLocations.enabled: %s", cl_enabled)

    # ── Workload Identity ────────────────────────────────────────────────
    wi         = data.get("workloadIdentity") or {}
    wi_enabled = wi.get("enabled", False)
    if wi_enabled:
        r_wi = CheckResult(True, "workloadIdentity.enabled: true", "")
        _check_log.info("PASS   workload-identity  |  workloadIdentity.enabled: true")
    else:
        r_wi = CheckResult(
            False, f"workloadIdentity.enabled: {wi_enabled}",
            f"Workload Identity not enabled in the cluster. "
            "Known issue: Setting WorkloadIdentityEnabled in New-AzConnectedKubernetes "
            "only registers the feature with ARM but does NOT deploy the webhook pods. "
            f"On the edge device run: az connectedk8s update "
            f"--name {cluster_name} --resource-group {resource_group} "
            "--enable-workload-identity "
            "(Without this, Key Vault secret sync will fail with AADSTS700211.)",
        )
        _check_log.warning("FAIL   workload-identity  |  workloadIdentity.enabled: %s", wi_enabled)

    return [
        ("arc-connected",     r_connected),
        ("custom-locations",  r_cl),
        ("workload-identity", r_wi),
    ]


@log_check
async def check_arc_connected(cluster_name: str, resource_group: str) -> CheckResult:
    code, out, err = await _logged_run([
        "az", "connectedk8s", "show",
        "--name", cluster_name,
        "--resource-group", resource_group,
        "--output", "json",
    ])
    if code != 0:
        return CheckResult(
            False, "",
            f"az command failed: {err or 'unknown error'}. "
            "Fix: Make sure 'az login' has been run and that cluster_name / "
            "resource_group in aio_config.json match what was created by arc_enable.ps1. "
            "Then re-run arc_enable.ps1 on the edge device and wait for agent pods to "
            "reach Running state.",
        )
    try:
        data = json.loads(out)
        status = data.get("connectivityStatus", "unknown")
        if status.lower() == "connected":
            return CheckResult(True, f"connectivityStatus: {status}", "")
        return CheckResult(
            False, f"connectivityStatus: {status}",
            "Cluster is not Connected to Azure Arc. "
            "Re-run arc_enable.ps1 on the edge device and wait for all pods in the "
            "azure-arc namespace to reach Running state before re-checking.",
        )
    except json.JSONDecodeError:
        return CheckResult(
            False, "",
            "Could not parse az output. Check that Azure CLI is logged in (az login).",
        )


@log_check
async def check_custom_locations(cluster_name: str, resource_group: str) -> CheckResult:
    code, out, err = await _logged_run([
        "az", "connectedk8s", "show",
        "--name", cluster_name,
        "--resource-group", resource_group,
        "--output", "json",
    ])
    if code != 0:
        return CheckResult(
            False, "",
            f"az command failed: {err or 'unknown error'}. Run 'Check Arc Connected' first.",
        )
    try:
        data = json.loads(out)
        sdv = data.get("systemDefaultValues") or {}
        cl = sdv.get("customLocations") or {}
        enabled = cl.get("enabled", False)
        if enabled:
            return CheckResult(True, "customLocations.enabled: true", "")
        return CheckResult(
            False, f"customLocations.enabled: {enabled}",
            "Custom Locations not enabled in the cluster. "
            "Known issue: Az.ConnectedKubernetes only registers this with ARM but does "
            "not run the required helm upgrade. On the edge device run: "
            "helm upgrade azure-arc azurearcmcp/azure-arc-k8sagents "
            "-n azure-arc-release --reuse-values "
            "--set systemDefaultValues.customLocations.enabled=true "
            "--set systemDefaultValues.customLocations.oid=<oid> "
            "(See arc_enable.ps1 for the full helm upgrade step.)",
        )
    except json.JSONDecodeError:
        return CheckResult(False, "", "Could not parse az output.")


@log_check
async def check_workload_identity(cluster_name: str, resource_group: str) -> CheckResult:
    code, out, err = await _logged_run([
        "az", "connectedk8s", "show",
        "--name", cluster_name,
        "--resource-group", resource_group,
        "--output", "json",
    ])
    if code != 0:
        return CheckResult(
            False, "",
            f"az command failed. Run 'Check Arc Connected' first.",
        )
    try:
        data = json.loads(out)
        wi = data.get("workloadIdentity") or {}
        enabled = wi.get("enabled", False)
        if enabled:
            return CheckResult(True, "workloadIdentity.enabled: true", "")
        return CheckResult(
            False, f"workloadIdentity.enabled: {enabled}",
            f"Workload Identity not enabled in the cluster. "
            "Known issue: Setting WorkloadIdentityEnabled in New-AzConnectedKubernetes "
            "only registers the feature with ARM but does NOT deploy the webhook pods. "
            f"On the edge device run: "
            f"az connectedk8s update --name {cluster_name} --resource-group {resource_group} --enable-workload-identity "
            "(Without this, Key Vault secret sync will fail with AADSTS700211.)",
        )
    except json.JSONDecodeError:
        return CheckResult(False, "", "Could not parse az output.")


# ── Verification 2 — kubectl ──────────────────────────────────────────────────

def _make_kubectl_env(kubeconfig_path: str) -> dict | None:
    """Expand the kubeconfig path and return an env dict with KUBECONFIG set.
    Returns None if the path is empty or the file does not exist."""
    if not kubeconfig_path:
        return None
    expanded = os.path.expanduser(kubeconfig_path)
    if not os.path.isfile(expanded):
        return None
    return {**os.environ, "KUBECONFIG": expanded}


@log_check
async def check_arc_pods(kubeconfig_path: str) -> CheckResult:
    env = _make_kubectl_env(kubeconfig_path)
    if env is None:
        return CheckResult(
            False, "",
            f"kubeconfig not found at: {kubeconfig_path}. "
            "Check the cluster.kubeconfig_path value in aio_config.json. "
            "The file should exist on this Windows machine (e.g. copied from the edge device "
            "or generated by installer.sh).",
        )
    code, out, err = await _logged_run(
        ["kubectl", "get", "pods", "-n", "azure-arc", "--no-headers"], env=env
    )
    if code != 0:
        return CheckResult(
            False, "",
            f"kubectl failed: {err or 'unknown error'}. "
            "Fix: Check that kubeconfig_path in aio_config.json points to a valid kubeconfig "
            "and that kubectl is installed and on PATH (kubectl version --client).",
        )
    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        return CheckResult(
            False, "0 pods found",
            "No pods found in azure-arc namespace. Azure Arc may not be installed yet. "
            "Re-run arc_enable.ps1 on the edge device.",
        )
    not_running = [l for l in lines if "Running" not in l and "Completed" not in l]
    if not_running:
        bad = ", ".join(l.split()[0] for l in not_running[:3] if l.split())
        return CheckResult(
            False, f"{len(not_running)}/{len(lines)} pods not Running",
            f"Pods not yet Running: {bad}. "
            "Wait for pods to stabilise: kubectl get pods -n azure-arc. "
            "If stuck, check node resources: kubectl describe node",
        )
    return CheckResult(True, f"{len(lines)} pods Running", "")


@log_check
async def check_rbac_bindings(kubeconfig_path: str) -> CheckResult:
    env = _make_kubectl_env(kubeconfig_path)
    if env is None:
        return CheckResult(False, "", f"kubeconfig not found at: {kubeconfig_path}")
    code, out, err = await _logged_run(
        ["kubectl", "get", "clusterrolebindings", "--no-headers"], env=env
    )

    if code != 0:
        return CheckResult(False, "", f"kubectl failed: {err or 'unknown error'}")
    arc_bindings = [l for l in out.splitlines() if "azure-arc" in l.lower()]
    if arc_bindings:
        return CheckResult(True, f"{len(arc_bindings)} azure-arc bindings found", "")
    return CheckResult(
        False, "0 azure-arc bindings found",
        "Expected Azure Arc RBAC cluster role bindings are missing. "
        "Re-run arc_enable.ps1 — the Arc extension may not have installed cleanly.",
    )


@log_check
async def check_operator_permissions(kubeconfig_path: str) -> CheckResult:
    env = _make_kubectl_env(kubeconfig_path)
    if env is None:
        return CheckResult(False, "", f"kubeconfig not found at: {kubeconfig_path}")
    code, out, err = await _logged_run([
        "kubectl", "auth", "can-i", "list", "pods",
        "--namespace", "azure-arc",
        "--as", "system:serviceaccount:azure-arc:azure-arc-operator",
    ], env=env)

    if code != 0:
        return CheckResult(False, "", f"kubectl auth check failed: {err or 'unknown error'}")
    if out.strip().lower() == "yes":
        return CheckResult(True, "operator can list pods: yes", "")
    return CheckResult(
        False, f"operator can-i result: {out.strip() or 'no'}",
        "Arc operator service account lacks expected permissions. This may indicate "
        "the Arc extension is in a partial state. "
        "Try: az iot ops upgrade --name <instance> -g <resource_group> -y",
    )


@log_check
async def check_device_registry_crds(kubeconfig_path: str) -> CheckResult:
    env = _make_kubectl_env(kubeconfig_path)
    if env is None:
        return CheckResult(False, "", f"kubeconfig not found at: {kubeconfig_path}")
    code, out, err = await _logged_run(
        ["kubectl", "get", "crd", "--no-headers"], env=env
    )

    if code != 0:
        return CheckResult(False, "", f"kubectl failed: {err or 'unknown error'}")
    dr_crds = [l.split()[0] for l in out.splitlines() if "deviceregistry" in l.lower()]
    if dr_crds:
        names = ", ".join(dr_crds[:2])
        extra = f" (+{len(dr_crds) - 2} more)" if len(dr_crds) > 2 else ""
        return CheckResult(True, f"Found: {names}{extra}", "")
    return CheckResult(
        False, "No deviceregistry CRDs found",
        "Device Registry CRDs not found. In AIO v1.2+ these are bundled with the "
        "IoT Operations extension — they appear after Azure Setup (Phase 4) completes. "
        "If Azure Setup is done and CRDs are still missing, run: "
        "kubectl get crd | grep -i iot "
        "and: kubectl get extensions -n azure-arc",
    )
