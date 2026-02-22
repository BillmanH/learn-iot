# AIO Manager - Textual UI Design Plan

A terminal-based management UI for Azure IoT Operations, built with the Python `textual` library. Runs on the Windows management machine and provides an end-to-end workflow covering edge device setup, Azure configuration, and live monitoring — all from a single screen.

---

## Vision

Replace the need to manually orchestrate four separate scripts across two machines by providing a guided, interactive TUI that:

- Tracks where you are in the installation process
- Surfaces relevant logs and status in real time
- Lets you view and edit config inline
- Makes troubleshooting faster by co-locating output and context

---

## Screen Layout

```
┌─────────────────────────────────────────────────────────────────────────┐
│  AIO Manager                                          [F1] Help  [Q] Quit│
├──────────────────────────┬──────────────────────────┬───────────────────┤
│  EDGE                    │  AZURE SETUP             │  CONFIG           │
│                          │                          │ Azure Clust Dep T │
│  Status: ● Connected     │  Status: ◌ Not started   │─────────────────  │
│  Host: 192.168.1.x       │                          │ Field   Value OK  │
│                          │  [ ] Key Vault           │ sub_id  abc… ✓    │
│  [ ] installer.sh        │  [ ] Storage Account     │ rg      my-r ✓    │
│  [ ] arc_enable.ps1      │  [ ] Schema Registry     │ location east ✓   │
│                          │  [ ] IoT Operations      │─────────────────  │
│  Pods (azure-arc):       │  [ ] Role Assignments    │ (row description) │
│  ● arc-agent  Running    │                          │─────────────────  │
│  ● config-agent Running  │  [ grant_entra_id_roles ]│ sub_id: abc123  ▲ │
│  ○ ...                   │  [ External-Configurator]│ rg: my-rg       │ │
│                          │                          │ location: eastus│ │
│                          │                          │ cluster: name   ▼ │
│                          │                          │[ Validate       ] │
│                          │                          │[ Open in Editor ] │
│                          │                          │[ Reload         ] │
├──────────────────────────┴──────────────────────────┴───────────────────┤
│  LOG OUTPUT                                                              │
│  [EDGE] [AZURE] [ALL]                                                    │
│  > 14:02:11 installer.sh - K3s installed successfully                   │
│  > 14:03:45 arc_enable.ps1 - Connecting cluster to Azure Arc...         │
└─────────────────────────────────────────────────────────────────────────┘
```


### Panels

| Panel | Purpose |
|---|---|
| **Edge** | SSH connection to the Ubuntu edge device, script execution status, pod health |
| **Azure Setup** | Step-by-step status of Azure resource deployment, action buttons |
| **Config** | Read/validate config files, inline JSON viewer, quick-edit shortcuts |
| **Log Output** | Unified log pane, filterable by source (edge / azure / all) |

---

## Environment Setup (UV)

The UI is managed as an optional dependency group within the existing repo `pyproject.toml`. No separate project or venv needed.

### 1. Install UV (if not already installed)

```powershell
# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -c "irm https://astral.sh/uv/install.ps1 | iex"
```

### 2. Add the UI dependencies

From the repo root:

```powershell
uv add --optional ui textual paramiko watchdog
```

This adds an `[project.optional-dependencies]` `ui` group to `pyproject.toml`.

### 3. Sync the environment with UI extras

```powershell
uv sync --extra ui
```

### 4. Run the app

```powershell
# From repo root
uv run --extra ui textual/aio_manager.py
```

All subsequent `uv run` commands in this doc assume `--extra ui` or that the environment was synced with `uv sync --extra ui`.

---

## Technical Approach

### Stack
- **[Textual](https://textual.textualize.io/)** - TUI framework (reactive widgets, CSS layout)
- **Paramiko** - SSH client for running commands on the edge device
- **subprocess / asyncio** - Running local PowerShell scripts non-blocking
- **watchdog** - File watching for live config reload
- **rich** - Already a Textual dependency; used for log formatting

### Entry Point
```
textual/
├── PLAN.md               ← this file
├── aio_manager.py        ← app entry point
├── screens/
│   └── main_screen.py    ← single-screen layout
├── panels/
│   ├── edge_panel.py
│   ├── azure_panel.py
│   └── config_panel.py
├── workers/
│   ├── ssh_worker.py     ← async SSH command runner
│   └── ps_worker.py      ← async PowerShell script runner
├── models/
│   └── state.py          ← reactive app state (connection, step progress)
└── styles/
    └── app.tcss          ← Textual CSS for layout
```

### State Model
A central reactive state object tracks:
- SSH connection status and host
- Checklist state for each deployment step (not started / running / success / failed)
- Contents of loaded config files
- Log stream per source

---

## Phases

### Phase 0 — Blank UI Proof of Concept
**Goal**: The smallest possible Textual app that proves the environment works and gives us something to look at and critique before committing to the layout.

- [ ] Add `textual` to `pyproject.toml` optional deps (see Environment Setup above)
- [ ] Create `textual/aio_manager.py` with a minimal `App` subclass
- [ ] Three placeholder panels arranged in a 3-column horizontal split
- [ ] A log pane below the panels (static placeholder text)
- [ ] Header showing app name and basic key bindings (Q to quit)
- [ ] No real data, no SSH, no scripts — purely structural

**Review checkpoint**: Run the app, evaluate the layout and colour scheme, update this spec with any changes before proceeding to Phase 1.

```powershell
uv run --extra ui textual/aio_manager.py
```

---

### Phase 1 — Shell and Layout
**Goal**: A running app with the correct 3-panel layout, no real functionality yet.

- [ ] Set up folder structure and `pyproject.toml` dependencies
- [ ] Create `aio_manager.py` with `App` subclass
- [ ] Implement `main_screen.py` with 3-column layout using Textual CSS
- [ ] Add placeholder widgets in each panel (static labels, dummy checklists)
- [ ] Add log pane at the bottom with tab switching (EDGE / AZURE / ALL)
- [ ] Header with app name and key bindings (F1 help, Q quit)

**Deliverable**: `python aio_manager.py` opens a working, navigable shell.

---

### Phase 2 — Config Panel
**Goal**: Real config file loading, field-by-field viewing with descriptions, and validation.

- [x] Merge `aio_config.json` and `cluster_info.json` into a single `aio_config.json` (cluster section added)
- [x] Create `models/config_loader.py` — loads file, maps `comments` block to field descriptions, validates required fields
- [x] Config panel shows 4 tabbed sections: Azure | Cluster | Deployment | Tools
- [x] Each section is a `DataTable` with columns: Field | Value | Status (OK / MISSING / ON / OFF)
- [x] Highlighting a row shows its description from the `comments` block at the bottom of the panel
- [x] Validation errors surface inline (red status + error bar)
- [x] Config auto-loaded on startup; errors written to log pane
- [x] "Reload" button wires up to re-run `load_config()` live
- [x] "Open in Editor" button opens `aio_config.json` in VS Code / notepad

**Note on single file**: `cluster_info.json` is still written by `installer.sh` for PowerShell script backward compatibility, but the UI treats `aio_config.json` (which now includes a `cluster` section) as the single source of truth.

**Deliverable**: Config panel fully functional and useful standalone.

---

### Phase 3 — Edge Panel (SSH)
**Goal**: Connect to the edge device and verify that installer.sh and arc_enable.ps1 have been run successfully by the user on the edge machine. This panel does **not** run those scripts — it validates their results.

**Assumption**: The user has already manually run `installer.sh` and `arc_enable.ps1` on the edge device before using this panel.

**No SSH required**: Both verifications run locally on the Windows machine. Azure CLI commands use the user's local `az` session; `kubectl` commands use the kubeconfig file path from `aio_config.json` (`cluster.kubeconfig_path`). SSH connection is deferred to a later phase if needed.

#### Verification 1 — Azure Arc connectivity (Azure CLI)
Runs locally on the Windows machine using `az` CLI commands. Each item is an individually clickable button. Clicking runs the check and updates the button color and status text inline.

- [ ] Button: **Check Arc Connected** — runs `az connectedk8s show --name <cluster> --resource-group <rg>`, checks `connectivityStatus == "Connected"`
  - Pass: button turns green, shows `Connected`
  - Fail: shows inline instruction — *"Cluster not found or not connected. Re-run arc_enable.ps1 on the edge device and wait for the agent pods to reach Running state."*
- [ ] Button: **Check Custom Locations** — queries `systemDefaultValues.customLocations.enabled` from `az connectedk8s show`
  - Pass: button turns green
  - Fail: shows inline instruction — *"Custom Locations not enabled. On the edge device run the helm upgrade step in arc_enable.ps1 to set customLocations.enabled=true."*
- [ ] Button: **Check Workload Identity** — queries `workloadIdentity.enabled` from `az connectedk8s show`
  - Pass: button turns green
  - Fail: shows inline instruction — *"Workload Identity not enabled. On the edge device run: az connectedk8s update --enable-workload-identity (see arc_enable.ps1 known issue workaround)."*

#### Verification 2 — Kubernetes RBAC (kubectl, local)
Runs `kubectl` locally by setting `KUBECONFIG` to the path from `cluster.kubeconfig_path` in `aio_config.json`. The kubeconfig must be accessible on the Windows machine. Each item is an individually clickable button.

- [ ] Button: **Check Arc Pods** — runs `kubectl get pods -n azure-arc`, checks all pods are `Running`
  - Pass: button turns green, shows pod count
  - Fail: shows inline instruction — *"One or more Arc pods are not Running. Wait for pods to stabilise (kubectl get pods -n azure-arc). If stuck, check node resources with kubectl describe node."*
- [ ] Button: **Check RBAC Bindings** — runs `kubectl get clusterrolebindings`, checks for expected `azure-arc-*` bindings
  - Pass: button turns green, shows count of bindings found
  - Fail: shows inline instruction — *"Expected Azure Arc RBAC bindings are missing. Re-run arc_enable.ps1 — the Arc extension may not have installed cleanly."*
- [ ] Button: **Check Operator Permissions** — runs `kubectl auth can-i list pods --namespace azure-arc --as system:serviceaccount:azure-arc:azure-arc-operator`
  - Pass: button turns green
  - Fail: shows inline instruction — *"Arc operator service account lacks expected permissions. This may indicate the Arc extension is in a partial state — try az iot ops upgrade or re-enable Arc."*
- [ ] Button: **Check Device Registry CRDs** — runs `kubectl get crd`, checks for `assets.deviceregistry.microsoft.com`
  - Pass: button turns green, shows CRD names found
  - Fail: shows inline instruction — *"Device Registry CRDs not found. In AIO v1.2+ these are bundled with the IoT Operations extension — run Azure Setup (Phase 4) before checking this."*

#### Summary
- [ ] **Run All Checks** button — triggers all 7 buttons above in sequence
- [ ] Overall readiness banner updates after all checks complete: green *"Ready for Azure Setup"* or amber *"Issues detected — see failed checks above"*
- [ ] Each failed check's instruction text is also written to the EDGE log pane for reference

**Deliverable**: Seven individually clickable check buttons that each run a targeted `az` or `kubectl` command, turn green on pass, or display specific remediation instructions on fail, with a "Run All Checks" shortcut and an overall readiness banner.

---

### Phase 4 — Azure Setup Panel
**Goal**: Run and monitor the Azure configuration scripts from the UI.

- [ ] Parse `deployment_summary.json` to show already-deployed resources
- [ ] Step checklist: Key Vault, Storage, Schema Registry, AIO, Role Assignments
- [ ] "Run grant_entra_id_roles.ps1" button — streams output to log pane
- [ ] "Run External-Configurator.ps1" button — streams output to log pane
- [ ] Detect step completion from script output patterns (regex matching)
- [ ] Auto-mark checklist items as complete when output confirms success
- [ ] Error detection: highlight failed steps with error excerpt and suggested fix
- [ ] "Re-run step" granular retry buttons per resource type

**Deliverable**: Full Azure setup flow runnable from the UI without touching PowerShell directly.

---

### Phase 5 — Monitoring Mode
**Goal**: Post-installation live monitoring.

- [ ] MQTT message counter (live via SSH + `kubectl logs`)
- [ ] Pod restarts and health rollup
- [ ] Dataflow status (list active dataflows via `kubectl get dataflow`)
- [ ] Switch between "Setup Mode" and "Monitor Mode" (keyboard toggle)
- [ ] Log streaming — tail azure-iot-operations and azure-arc logs live

**Deliverable**: App remains useful after installation as an operational dashboard.

---

### Phase 6 — Module Deployment
**Goal**: Deploy edge modules from the UI.

- [ ] Module picker — list modules from `modules/` directory
- [ ] Show current deployment status per module
- [ ] "Deploy" and "Remove" buttons per module
- [ ] Wraps `Deploy-EdgeModules.ps1` with module selection passed as parameters
- [ ] Display container image and version information

**Deliverable**: Full end-to-end app management without leaving the TUI.

---

### Phase 7 — Packaging as Standalone Executable
**Goal**: A single `aio-manager.exe` that runs on any Windows machine without requiring Python, uv, or any dependencies installed.

- [ ] Add `pyinstaller` to the `ui` optional dependency group
- [ ] Create `textual/aio_manager.spec` — PyInstaller spec file with:
  - `--onefile` for a single self-contained `.exe`
  - Include Textual's bundled CSS/asset data files (`textual` package data)
  - Set `console=True` (Textual needs a real console window, not a windowed app)
  - Set the exe name to `aio-manager`
- [ ] Add a `build` uv script to `pyproject.toml` for convenience
- [ ] Test the built exe in a clean environment (no Python on PATH)
- [ ] Document output path and distribution notes

**Build command** (once implemented):
```powershell
# From repo root
uv run --extra ui pyinstaller textual/aio_manager.spec
# Output: dist/aio-manager.exe
```

**Key PyInstaller notes for Textual**:
- Textual ships its default CSS as package data — must be collected with `--collect-data textual`
- Use `--onefile` for portability; expect ~15-25 MB output size
- `console=True` is required — Textual will not work in `--windowed` mode
- If using an SSH library (Phase 3+), `paramiko` and its cryptography backend need explicit hidden imports

**Deliverable**: `dist/aio-manager.exe` — copy anywhere, run from cmd or PowerShell, no installation required.

---

## Key Design Decisions

### Async Everything
Textual is async-native. All SSH calls and subprocess invocations must use `asyncio` workers to avoid blocking the UI thread. Use `app.run_worker()` for long-running tasks.

### kubectl from Windows via kubeconfig
Phase 3 verification runs `kubectl` locally on Windows by setting `KUBECONFIG` to the path from `cluster.kubeconfig_path` in `aio_config.json`. No SSH or base64 decoding needed — the kubeconfig file must be accessible on the Windows machine (copied from the edge device or generated locally). Full SSH-based remote execution (for live log streaming etc.) is deferred to Phase 5.

### Config as Single Source of Truth
The app reads from `config/aio_config.json` which now includes both the Azure settings and the cluster info (formerly in `cluster_info.json`) under a `cluster` section. `cluster_info.json` is still generated by `installer.sh` for backward compatibility with the PowerShell scripts. The `comments` block inside `aio_config.json` drives the field descriptions shown in the UI — no separate documentation needed.

### Safe Script Execution
Scripts are not re-implemented in Python. The TUI shells out to the existing `.ps1` and `.sh` scripts. This keeps the scripts as the authoritative source of behavior and reduces duplication.

---

## Open Questions

1. **SSH key management** — should the app store SSH credentials in Windows Credential Manager, a local `.env` file, or prompt each session?
2. **Multi-device support** — should the Edge panel support switching between multiple edge hosts, or is one-at-a-time sufficient for v1?
3. **Windows Terminal vs plain cmd** — Textual requires a terminal that supports 256 colors and mouse events. Should we detect and warn if the environment is inadequate?
4. **Packaging** — ~~distribute as a standalone `.exe` via PyInstaller, or keep as a Python script requiring `uv run`?~~ **Resolved**: bundle as a standalone `.exe` using PyInstaller (see Phase 7). Target: single file runnable from any Windows command line without Python or uv installed.

---

## Running the App (future)

```powershell
# From the repo root, once implemented
uv run textual/aio_manager.py

# Or with explicit config
uv run textual/aio_manager.py --config config/aio_config.json
```

---

## Dependencies

Add via uv (see Environment Setup section):

```powershell
uv add --optional ui textual paramiko watchdog pyinstaller
```

This will write the following into `pyproject.toml` automatically:

```toml
[project.optional-dependencies]
ui = [
    "textual>=0.70.0",
    "paramiko>=3.4.0",
    "watchdog>=4.0.0",
    "pyinstaller>=6.0.0",
]
```

To verify installed packages:

```powershell
uv run --extra ui python -c "import textual; print(textual.__version__)"
```

To build the executable (Phase 7):

```powershell
uv run --extra ui pyinstaller --onefile --console --collect-data textual --name aio-manager textual/aio_manager.py
# Output: dist/aio-manager.exe
```
